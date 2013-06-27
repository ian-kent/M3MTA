package M3MTA::MDA;

use Moose;
use Modern::Perl;

use M3MTA::Server::SMTP::Email;

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime::Tiny;
use MongoDB::MongoClient;

use Data::Dumper;
use Net::DNS;
use Config::Any;
use IO::Socket::INET;
use Email::Date::Format qw/email_date/;

has 'config' => ( is => 'rw' );
has 'backend' => ( is => 'rw', isa => 'M3MTA::Server::Backend::MDA' );

# Debug
has 'debug'         => ( is => 'rw', default => sub { $ENV{M3MTA_DEBUG} // 1 } );

# Filters
has 'filters' => ( is => 'rw', default => sub { [] } );

#------------------------------------------------------------------------------

sub log {
    my ($self, $message, @args) = @_;

    return 0 unless $self->debug;

    $message = sprintf("[%s] %s $message", ref($self), DateTime::Tiny->now, @args);
    print STDOUT "$message\n";

    return 1;
}

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

	# Create backend
    my $backend = $self->config->{backend}->{handler};
    if(!$backend) {
        die("No backend found in server configuration");
    }
    
    eval "require $backend" or die ("Unable to load backend $backend: $@");
    $self->backend($backend->new(server => $self, config => $self->config));
    $self->log("Created backend $backend");

    for my $filter (@{$self->config->{filters}}) {
        $self->log("Registering filter $filter");
        eval "require $filter";
        my $o = $filter->new;
        push $self->filters, $o;
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

    my $msg = {
        date => $msg_date,
        status => 'Pending',
        data => $msg_data,
        helo => "localhost",
        id => "$msg_id",
        from => $msg_from,
        to => [ $to ],
    };

    return $msg;
}

#------------------------------------------------------------------------------

sub block {
	my ($self) = @_;

    my $inactivity_count = 0;
	while (1) {       
        my $message = $self->backend->poll;

        if(!$message) {
            $inactivity_count++;
            # Every 10 undef results = 1 second extra
            my $sleep = 5 + (int($inactivity_count / 10));
            $sleep = 60 if $sleep > 60;
            sleep $sleep;
            next;
        }
        $inactivity_count = 0;

        print "Processing message '" . $message->{id} . "' from '" . $message->{from} . "'\n";

        # Run filters
        my $data = $message->{data};
        $message->{filters} = {};
        for my $filter (@{$self->filters}) {
            print " - Calling filter $filter\n";

            # Call the filter
            my $result = $filter->test($data, $message);

            # Store the result (so later filters can see it)
            $message->{filters}->{ref($filter)} = $result;

            # Copy back the data
            $data = $result->{data};
        }
        if(!defined $data) {
            # undef data means the message is dropped
            print " - Filter caused message to be dropped";
            next;
        }
        # Copy the final result back for delivery
        $message->{data} = $data;

        # Turn the email into an object
        my $email = M3MTA::Server::SMTP::Email->from_data($message->{data});

        for my $to (@{$message->{to}}) {
            my ($user, $domain) = split /@/, $to;
            print " - Recipient '$user'\@'$domain'\n";

            if(lc $user eq 'postmaster') {
                # we've got a postmaster address, resolve it
                my $postmaster = $self->backend->get_postmaster($domain);
                print " - Got postmaster address: $postmaster\n";
                ($user, $domain) = split /@/, $postmaster;
                print " - New recipient is '$user'\@'$domain'\n";
            }

            my $result = $self->backend->local_delivery($user, $domain, $email);

            next if $result > 0;

            if($result == -1) {
                # was a local delivery, but user didn't exist
                # TODO postmaster email?
                print " - Local delivery but no mailbox found\n";
                $self->backend->notify($self->notification(
                    $message->{from},
                    "Message delivery failed for " . $message->{id} . ": " . $email->{headers}->{Subject},
                    "Your message to $to could not be delivered.\r\n\r\nMailbox not recognised."
                ));
            }

            if($result == 0) {
                # We wont bother checking for relay settings, SMTP delivery should have done that already
                # So, anything which doesn't get caught above, we'll relay here
                print " - No domain or mailbox entry found, attempting remote delivery\n";
                my $error = '';

                # Attempt to send via SMTP
                my $res = $email->send_smtp($to, \$error);

                if($res == -1) {
                    # retryable error, so re-queue                  
                    $res = $self->backend->requeue($message, $error);

                    if($res == 1) {
                        print " - Remote delivery failed with retryable error, message re-queued, no notification sent\n";
                    } elsif ($res == 2) {
                        print " - Remote delivery failed with retryable error, message re-queued, notification sent\n";
                        $self->backend->notify($self->notification(
                            $message->{from},
                            "Message delivery delayed for " . $message->{id} . ": " . $email->{headers}->{Subject},
                            "Your message to $to has been delayed.\r\n\r\nUnable to contact remote mailservers: $error"
                        ));
                    } else {
                        print " - Remote delivery failed with retryable error, requeue also failed, message dropped\n";
                    }
                } elsif ($res == -2) {
                    # permanent failure
                    print " - Remote delivery failed with permanent error, message dropped\n";
                    $self->backend->notify($self->notification(
                        $message->{from},
                        "Message delivery failed for " . $message->{id} . ": " . $email->{headers}->{Subject},
                        "Your message to $to could not be delivered.\r\n\r\nPermanent delivery failure: $error"
                    ));
                }
            }
        }
    }
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;