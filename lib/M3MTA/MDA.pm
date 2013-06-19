package M3MTA::MDA;

use Moose;
use Modern::Perl;

use M3MTA::Util;

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime::Tiny;
use MongoDB::MongoClient;

use Data::Dumper;
use Net::DNS;
use Config::Any;
use IO::Socket::INET;
use Email::Date::Format qw/email_date/;

use M3MTA::MDA::SpamAssassin;

has 'config' => ( is => 'rw' );
has 'backend' => ( is => 'rw', isa => 'M3MTA::Server::Backend::MDA' );

# Debug
has 'debug'         => ( is => 'rw', default => sub { $ENV{M3MTA_DEBUG} // 1 } );

# Filters
has 'filters' => ( is => 'rw', default => sub { [] } );
#has 'spamassassin'  => ( is => 'rw' );

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
    my $backend = $self->config->{backend};
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

	while (1) {       
        my $messages = $self->backend->poll;

        for my $email (@$messages) {
            $self->backend->dequeue($email);

            print "Processing message '" . $email->{id} . "' from '" . $email->{from} . "'\n";

            # Run filters
            my $data = $email->{data};
            $email->{filters} = {};
            for my $filter (@{$self->filters}) {
                print " - Calling filter $filter\n";

                # Call the filter
                my $result = $filter->test($data, $email);

                # Store the result (so later filters can see it)
                $email->{filters}->{ref($filter)} = $result;

                # Copy back the data
                $data = $result->{data};
            }
            if(!defined $data) {
                # undef data means the message is dropped
                print " - Filter caused message to be dropped";
                next;
            }
            # Copy the final result back for delivery
            $email->{data} = $data;

            # Turn the email into an object
            my $obj = M3MTA::Util::parse($email->{data});
            # Add received by header
            my $recd_by = "from " . $email->{helo} . " by " . $self->config->{hostname} . " (M3MTA) id " . $email->{id} . ";";
            if($obj->{headers}->{Received}) {
                $obj->{headers}->{Received} = [$obj->{headers}->{Received}] if ref($obj->{headers}->{Received}) !~ /ARRAY/;
                push $obj->{headers}->{Received}, $recd_by;
            } else {
                $obj->{headers}->{Received} = $recd_by;
            }

            for my $to (@{$email->{to}}) {
                my ($user, $domain) = split /@/, $to;
                print " - Recipient '$user'\@'$domain'\n";

                if(lc $user eq 'postmaster') {
                    # we've got a postmaster address, resolve it
                    my $postmaster = $self->backend->get_postmaster($domain);
                    print " - Got postmaster address: $postmaster\n";
                    ($user, $domain) = split /@/, $postmaster;
                    print " - New recipient is '$user'\@'$domain'\n";
                }

                my $result = $self->backend->local_delivery($user, $domain, $obj);

                next if $result > 0;

                if($result == -1) {
                    # was a local delivery, but user didn't exist
                    # TODO postmaster email?
                    print " - Local delivery but no mailbox found\n";
                    $self->backend->notify($self->notification(
                        $email->{from},
                        "Message delivery failed for " . $email->{id} . ": " . $obj->{headers}->{Subject},
                        "Your message to $to could not be delivered.\r\n\r\nMailbox not recognised."
                    ));
                }

                if($result == 0) {
                    # We wont bother checking for relay settings, SMTP delivery should have done that already
                    # So, anything which doesn't get caught above, we'll relay here
                    print " - No domain or mailbox entry found, attempting remote delivery\n";
                    my $error = '';
                    my $res = M3MTA::Util::send_smtp($obj, $to, \$error);

                    if($res == -1) {
                        # retryable error, so re-queue                  
                        $res = $self->backend->requeue($email, $error);

                        if($res == 1) {
                            print " - Remote delivery failed with retryable error, message re-queued, no notification sent\n";
                        } elsif ($res == 2) {
                            print " - Remote delivery failed with retryable error, message re-queued, notification sent\n";
                            $self->backend->notify($self->notification(
                                $email->{from},
                                "Message delivery delayed for " . $email->{id} . ": " . $obj->{headers}->{Subject},
                                "Your message to $to has been delayed.\r\n\r\nUnable to contact remote mailservers: $error"
                            ));
                        } else {
                            print " - Remote delivery failed with retryable error, requeue also failed, message dropped\n";
                        }
                    } elsif ($res == -2) {
                        # permanent failure
                        print " - Remote delivery failed with permanent error, message dropped\n";
                        $self->backend->notify($self->notification(
                            $email->{from},
                            "Message delivery failed for " . $email->{id} . ": " . $obj->{headers}->{Subject},
                            "Your message to $to could not be delivered.\r\n\r\nPermanent delivery failure: $error"
                        ));
                    }
                }
            }
        }

        #last;
        sleep 5;
    }
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;