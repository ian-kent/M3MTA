package M3MTA::MDA;

use Moose;
use Modern::Perl;

use M3MTA::Storage::Message;
use M3MTA::Client::SMTP;
use M3MTA::Transport::Path;
use M3MTA::Transport::Envelope;

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime::Tiny;
use MongoDB::MongoClient;

use Data::Dumper;
use Net::DNS;
use IO::Socket::INET;
use Email::Date::Format qw/email_date/;

use M3MTA::Log;
use M3MTA::Chaos;

use M3MTA::Server::Backend::MDA;
use M3MTA::Server::Backend::SMTP;
use M3MTA::Storage::Message::Attempt;

use M3MTA::Storage::Mailbox::Message::Content;

has 'config' => ( is => 'rw' );
has 'backend' => ( is => 'rw', isa => 'M3MTA::Server::Backend::MDA' );

# Debug
has 'debug'         => ( is => 'rw', default => sub { $ENV{M3MTA_DEBUG} // 1 } );

# Filters
has 'filters' => ( is => 'rw', default => sub { [] } );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

	# Create backend
    my $backend = $self->config->{backend}->{handler};
    if(!$backend) {
        M3MTA::Log->fatal('No backend found in server configuration');
        die;
    }
    
    eval "require $backend";
    if($@) {
        M3MTA::Log->fatal("Unable to load backend $backend: $@");
        die;
    }

    $self->backend($backend->new(server => $self, config => $self->config));
    M3MTA::Log->debug("Created backend $backend");

    for my $filter (@{$self->config->{filters}}) {
        M3MTA::Log->debug("Registering filter $filter");
        eval "require $filter";
        if($@) {
            M3MTA::Log->error("Unable to load filter $filter");
        } else {
            my $o = $filter->new(mda => $self);
            push $self->filters, $o;
            M3MTA::Log->debug("Filter successfully registered");
        }
    }
}

#------------------------------------------------------------------------------

sub notification {
    my ($self, $to, $subject, $content) = @_;

    my $msg_id = luniqid . "@" . $self->config->{hostname};
    my $msg_date = DateTime->now;
    my $mail_date = email_date;
    my $msg_from = $self->config->{postmaster} // "postmaster\@m3mta.mda";

    my $msg_data = <<EOF
Message-ID: $msg_id\r
Date: $mail_date\r
User-Agent: M3MTA/MDA\r
MIME-Version: 1.0\r
To: $to\r
From: $msg_from\r
Subject: $subject\r
Content-Type: text/plain; charset=UTF-8;\r
Content-Transfer-Encoding: 7bit\r
\r
$content\r
\r
M3MTA-MDA Postmaster
EOF
;
    $msg_data =~ s/\r?\n\./\r\n\.\./gm;

    my $msg = M3MTA::Storage::Message->new;
    $msg->created($msg_date);
    $msg->status('Pending');
    $msg->data($msg_data);
    $msg->helo('localhost');
    $msg->id($msg_id);
    $msg->from(M3MTA::Transport::Path->new->from_text($msg_from));
    $msg->to([M3MTA::Transport::Path->new->from_json($to)]);
    $msg->delivery_time($msg_date);
    return $msg;
}

#------------------------------------------------------------------------------

sub block {
	my ($self) = @_;

    my $inactivity_count = 0;

	while (1) {
        local $@ = undef;
        my $error = undef;

        M3MTA::Log->trace("Polling for message");

        # Poll for a new message
        my $message;
        eval {
            $message = $self->backend->poll;
        };

        if($@) {
            # No message, so its not good but it wont do any damage
            # We'll continue for the timeout increase to happen
            M3MTA::Log->error("Error occured polling for message: $@");
        }

        # Slowly increase the delay if nothing happens
        if(!$message) {
            $inactivity_count++;
            M3MTA::Log->trace("No message found, inactivity count is: $inactivity_count");

            # Every 10 undef results = 1 second extra
            my $sleep = 5 + (int($inactivity_count / 10));
            # But limit to 60 seconds
            $sleep = 60 if $sleep > 60;

            M3MTA::Log->trace("Sleeping for $sleep seconds");

            sleep $sleep;
            next;
        }

        # We've got a message so reset the inactivity timer
        M3MTA::Log->trace("Message found, resetting inactivity count");
        $inactivity_count = 0;

        # Process the message
        eval {
            M3MTA::Log->trace("Processing message");
            M3MTA::Chaos->monkey('process_message_failure');
            $self->process_message($message);
            M3MTA::Log->trace("Message processing complete");
        };
            
        if($@) {
            # The message wasn't delivered, and its still queued as 'delivering'
            M3MTA::Log->error("Error occured processing message: $@");
            $error = $@;

            my $requeued = eval {
                M3MTA::Log->debug("Attempting to requeue message");
                $self->backend->dequeue($message->_id->{value});
                M3MTA::Chaos->monkey('process_message_failure_requeue');
                my $r = $self->backend->requeue($message, "Message processing failed: $error");
                return $r;
            };

            if($requeued) {
                M3MTA::Log->debug("Message successfully requeued");
                next;
            }

            # Otherwise put the message in 'Held' state
            $message->status('Held');
            push $message->attempts, M3MTA::Storage::Message::Attempt->new(
                date => DateTime->now,
                error => "Error occured processing message: $@\nMessage held for postmaster inspection",
            );

            # Update the backend
            my $result = eval {
                M3MTA::Chaos->monkey('process_message_held_failure');
                return $self->backend->update($message);
            };

            if(!$result) {
                $error = $@;
                M3MTA::Log->error("Error occured updating queue with held message: $error");
                
                # Be helpful and store some extra info, even though we might
                # never get to deliver the message
                push $message->attempts, M3MTA::Storage::Message::Attempt->new(
                    date => DateTime->now,
                    error => "Failed to update message status to held: $error",
                );

                # TODO try and store this on disk (or failing that, in memory)
                # so we can come back to it later, we might just have a temporary problem
                # (and see below)
            }

            # TODO notify someone?
            # beware - sending emails here may result in a message explosion
            # as new messages added to the queue also fail

            next;
        }

        # The message was sent, try to dequeue it
        eval {
            M3MTA::Chaos->monkey('dequeue_failure');
            $self->backend->dequeue($message->_id);
            M3MTA::Log->debug("Dequeued message " . $message->id);
        };

        # Check if the message still has recipients
        if(scalar @{$message->to} > 0) {
            M3MTA::Log->debug("Message still has recipients, requeuing");
            $self->backend->requeue($message, "Message still has recipients");
            return;
        }

        if($@) {
            $error = $@;

            # Now we have a message which was delivered but got stuck in the queue
            M3MTA::Log->debug("Failed to dequeue message " . $message->id . ": $error");

            # Add some useful info
            push $message->attempts, M3MTA::Storage::Message::Attempt->new(
                date => DateTime->now,
                error => "Failed to dequeue message " . $message->id . ": $error",
            );

            # No point even trying to update the queue

            # TODO try and store this on disk (or failing that, in memory)
            # so we can come back to it later, we might just have a temporary problem
            # (and see below)

            # TODO notify someone?
            # beware - sending emails here may result in a message explosion
            # as new messages added to the queue also fail
        }
    }
}

#------------------------------------------------------------------------------

sub process_message {
    my ($self, $message) = @_;

    my $error = undef;

    my $rcount = scalar @{$message->to};
    M3MTA::Log->info("Processing message '" . $message->id . "' from '" . $message->from . "' to $rcount recipients");

    # Run filters
    my $data = $message->data;
    for my $filter (@{$self->filters}) {
        M3MTA::Log->debug("Calling filter $filter");

        # Call the filter
        my $result = $filter->test($data, $message);

        # Store the result (so later filters can see it)
        $message->filters->{ref($filter)}->{result} = $result;

        # Copy back the data
        $data = $result->{data};
    }

    if(!defined $data) {
        # undef data means the message is dropped
        M3MTA::Log->debug("Filter caused message to be dropped");
        return;
    }

    # Copy the final result back for delivery
    $message->data($data);

    # Turn the email into an object
    my $content = M3MTA::Storage::Mailbox::Message::Content->new->from_data($data);

    # Try and send to all recipients
    my @recipients = @{$message->to};
    for my $to (@recipients) {
        my $dest = $to;
        M3MTA::Log->debug("Recipient '$to'");

        if($to->postmaster) {
            # we've got a postmaster address, resolve it
            my $postmaster = $self->backend->get_postmaster($to->domain);
            M3MTA::Log->debug("Got postmaster address: $postmaster");
            $dest = $postmaster;
        }

        # Attempt to deliver locally
        M3MTA::Chaos->monkey('local_delivery_failure');
        my $result = $self->backend->local_delivery($dest, $content, \$dest);

        if($result == $M3MTA::Server::Backend::MDA::SUCCESSFUL) {
            # Local delivery was successful
            M3MTA::Log->debug("Local delivery was successful, removing recipient $to");
            $message->remove_recipient($to);

            # RFC3461 5.2.3(abc) - 'delivered' DSN if NOTIFY=SUCCESS
            if(!$message->from->null && $to->params->{NOTIFY} && $to->params->{NOTIFY} =~ /SUCCESS/) {
                $self->backend->notify($self->notification(
                    $message->from,
                    "Message delivered for " . $message->id . ": " . $content->headers->{Subject},
                    "Your message to $to has been successfully delivered."
                ));
            }

            next;
        }

        if($result == $M3MTA::Server::Backend::MDA::USER_NOT_FOUND) {
            # was a local delivery, but user didn't exist
            if(!$message->from->null) {
                M3MTA::Log->debug("Local delivery but no mailbox found, sending notification to " . $message->from);
                $self->backend->notify($self->notification(
                    $message->from,
                    "Message delivery failed for " . $message->id . ": " . $content->headers->{Subject},
                    "Your message to $to could not be delivered.\r\n\r\nMailbox not recognised."
                ));
            } else {
                M3MTA::Log->debug("Local delivery but no mailbox found, null return path, no notification sent");
            }

            $message->remove_recipient($to);
            next;
        }

        if($result == $M3MTA::Server::Backend::MDA::EXTERNAL_ALIAS) {
            M3MTA::Log->debug("Local delivery resulted in external alias");
            # Fall-through to remote delivery
        }

        # We wont bother checking for relay settings, SMTP delivery should have done that already
        # So, anything which doesn't get caught above, we'll relay here
        M3MTA::Log->debug("No domain or mailbox entry found, attempting remote delivery with SMTP");

        # Attempt to send via SMTP (using $dest, notifications use $to which isn't affected by aliasing)
        $error = undef;
        print Data::Dumper::Dumper($message->from);
        print Data::Dumper::Dumper($dest);
        my $envelope = M3MTA::Transport::Envelope->new(
            from => $message->from,
            to => [$dest],
            data => $content->to_data,
        );
        my $res = M3MTA::Client::SMTP->send($envelope, \$error);

        if($res->{code} == -1) {
            # all hosts timed out - requeueable
            M3MTA::Log->info("All hosts timed out, delivery failed, message re-queued");
        } elsif ($res->{code} == -2 || $res->{code} == -3) {
            # permanent failure
            # -2 (no mx/a record), -3 (mx/a record but no hosts after filter)
            M3MTA::Log->info("Remote delivery failed with permanent error, message dropped, notification sent to " . $message->{from});
            $message->remove_recipient($to);

            # RFC3461 5.2.2(c) - 'failed' DSN if NOTIFY=FAILED || !NOTIFY
            if(!$message->from->null && (!$to->params->{NOTIFY} || $to->params->{NOTIFY} =~ /FAILED/)) {
                $self->backend->notify($self->notification(
                    $message->from,
                    "Message delivery failed for " . $message->id . ": " . $content->headers->{Subject},
                    "Your message to $to could not be delivered.\r\n\r\nPermanent failure - no valid A/MX records found."
                ));
            }
        } elsif ($res->{code} == 1) {
            if(!$res->{extensions}->{DSN}) {
                # RFC3461 5.2.2(b) - 'relayed' DSN if NOTIFY=SUCCESS
                if(!$message->from->null && $to->params->{NOTIFY} && $to->params->{NOTIFY} =~ /SUCCESS/) {
                    $self->backend->notify($self->notification(
                        $message->from,
                        "Message delivered for " . $message->id . ": " . $content->headers->{Subject},
                        "Your message to $to has been successfully delivered."
                    ));
                } 
            }

            $message->remove_recipient($to);
            M3MTA::Log->info("Message relayed using SMTP");
        }
    }
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;