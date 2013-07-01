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

use M3MTA::Server::Backend::MDA;
use M3MTA::Server::Backend::SMTP;

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
    $msg->from($msg_from);
    $msg->to([$to]);
    $msg->delivery_time($msg_date);
    return $msg;
}

#------------------------------------------------------------------------------

sub block {
	my ($self) = @_;

    my $inactivity_count = 0;

	while (1) {    
        # Poll for a new message  
        eval {
            M3MTA::Log->trace("Polling for message");
            my $message = $self->backend->poll;

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
                return;
            }

            # Reset the inactivity timer
            M3MTA::Log->trace("Message found, resetting inactivity count");
            $inactivity_count = 0;

            # Process the message
            eval {
                M3MTA::Log->trace("Processing message");
                $self->process_message($message);
                M3MTA::Log->trace("Message processing complete");
                $self->backend->dequeue($message->_id);
                M3MTA::Log->debug("Dequeued message " . $message->id);
            };
            
            if($@) {
                M3MTA::Log->error("Error occured processing message: $@");
            }
        };

        if($@) {
            M3MTA::Log->error("Error occured polling for message: $@");
        }
    }
}

#------------------------------------------------------------------------------

sub process_message {
    my ($self, $message) = @_;

    M3MTA::Log->info("Processing message '" . $message->id . "' from '" . $message->from . "'");

    # Run filters
    my $data = $message->data;
    $message->filters({});
    for my $filter (@{$self->filters}) {
        M3MTA::Log->debug("Calling filter $filter");

        # Call the filter
        my $result = $filter->test($data, $message);

        # Store the result (so later filters can see it)
        $message->filters->{ref($filter)} = $result;

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
    for my $to (@{$message->to}) {
        my ($user, $domain) = split /@/, $to;
        M3MTA::Log->debug("Recipient '$user'\@'$domain'");

        if(lc $user eq 'postmaster') {
            # we've got a postmaster address, resolve it
            my $postmaster = $self->backend->get_postmaster($domain);
            M3MTA::Log->debug("Got postmaster address: $postmaster");
            ($user, $domain) = split /@/, $postmaster;
            M3MTA::Log->debug("New recipient is '$user'\@'$domain'");
        }

        # Attempt to deliver locally
        my $dest = undef;
        my $result = $self->backend->local_delivery($user, $domain, $content, \$dest);

        next if $result > 0;

        if($result == -3) {
            M3MTA::Log->debug("Local delivery resulted in external alias");
            $to = $dest;
            $result = 0; # Attempt external delivery below
        }

        if($result == -1) {
            # was a local delivery, but user didn't exist
            # TODO postmaster email?
            M3MTA::Log->debug("Local delivery but no mailbox found, sending notification to " . $message->from);
            $self->backend->notify($self->notification(
                $message->from,
                "Message delivery failed for " . $message->id . ": " . $content->headers->{Subject},
                "Your message to $to could not be delivered.\r\n\r\nMailbox not recognised."
            ));
        }

        if($result == 0) {
            # We wont bother checking for relay settings, SMTP delivery should have done that already
            # So, anything which doesn't get caught above, we'll relay here
            M3MTA::Log->debug("No domain or mailbox entry found, attempting remote delivery with SMTP");

            # Attempt to send via SMTP
            my $error = '';
            my $envelope = M3MTA::Transport::Envelope->new(
                from => M3MTA::Transport::Path->new->from_json($message->from),
                to => [M3MTA::Transport::Path->new->from_json($to)], # TODO refactor to nicely support multiple to addresses to same host
                data => $content->to_data,
            );
            my $res = M3MTA::Client::SMTP->send($envelope, \$error);

            if($res == -1) {
                # retryable error, so re-queue    
                # but change the to address first, we've got an error
                # so we need to split this user off from the rest
                my $orig_to = $message->to;
                $message->to([$to]);
                $res = $self->backend->requeue($message, $error);
                $message->to($orig_to);

                if($res == 1) {
                    M3MTA::Log->info("Remote delivery failed with retryable error, message re-queued, no notification sent");
                } elsif ($res == 2) {
                    M3MTA::Log->info("Remote delivery failed with retryable error, message re-queued, notification sent to " . $message->{from});
                    $self->backend->notify($self->notification(
                        $message->from,
                        "Message delivery delayed for " . $message->id . ": " . $content->headers->{Subject},
                        "Your message to $to has been delayed.\r\n\r\nUnable to contact remote mailservers: $error"
                    ));
                } else {
                    # TODO notification?
                    M3MTA::Log->info("Remote delivery failed with retryable error, requeue also failed, message dropped, notification sent to " . $message->{from});
                    $self->backend->notify($self->notification(
                        $message->from,
                        "Message delivery failed for " . $message->id . ": " . $content->headers->{Subject},
                        "Your message to $to could not be delivered - too many retries.\r\n\r\nTemporary delivery failure: $error"
                    ));
                }
            } elsif ($res == -2 || $res == -3) {
                # permanent failure
                # -2 (no mx/a record), -3 (mx/a record but no hosts after filter)
                M3MTA::Log->info("Remote delivery failed with permanent error, message dropped, notification sent to " . $message->{from});
                $self->backend->notify($self->notification(
                    $message->from,
                    "Message delivery failed for " . $message->id . ": " . $content->headers->{Subject},
                    "Your message to $to could not be delivered.\r\n\r\nPermanent delivery failure: $error"
                ));
            } elsif ($res == 1) {
                M3MTA::Log->info("Message relayed using SMTP");
            }
        }
    }
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;