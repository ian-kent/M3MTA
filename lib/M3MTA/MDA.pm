package M3MTA::MDA;

use Moose;
use Modern::Perl;

use M3MTA::Util;

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime::Tiny;
use MongoDB::MongoClient;
use v5.14;

use Data::Dumper;
use Net::DNS;
use Config::Any;
use IO::Socket::INET;

use My::User;
use My::Email;

has 'config' => ( is => 'rw' );
has 'backend' => ( is => 'rw', isa => 'M3MTA::Server::Backend::MDA' );

# Debug
has 'debug'         => ( is => 'rw', default => sub { $ENV{M3MTA_DEBUG} // 1 } );

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
}

#------------------------------------------------------------------------------

sub block {
	my ($self) = @_;

	while (1) {
		print "In loop\n";
        
        my $messages = $self->backend->poll;

        for my $email (@$messages) {
            $self->backend->dequeue($email);

            print "Processing message '" . $email->{id} . "' from '" . $email->{from} . "'\n";

            # Turn the email into an object
            my $obj = M3MTA::Util::parse($email->{data});
            # Add received by header
            my $recd_by = "from " . $email->{helo} . " by " . $self->config->{hostname} . " (M3MTA) id " . $email->{id} . ";";
            if($obj->{headers}->{Received}) {
                $obj->{headers}->{Received} = [$obj->{headers}->{Received}] if ref $obj->{headers}->{Received} !~ /ARRAY/;
                push $obj->{headers}->{Received}, $recd_by;
            } else {
                $obj->{headers}->{Received} = $recd_by;
            }

            for my $to (@{$email->{to}}) {
                my ($user, $domain) = split /@/, $to;
                print " - Recipient '$user'\@'$domain'\n";

                my $result = $self->backend->local_delivery($user, $domain, $obj);

                next if $result > 0;

                if($result == -1) {
                    # was a local delivery, but user didn't exist
                    # TODO postmaster email?
                    print " - Local delivery but no mailbox found\n";
                }

                if($result == 0) {
                    # We wont bother checking for relay settings, SMTP delivery should have done that already
                    # So, anything which doesn't get caught above, we'll relay here
                    print " - No domain or mailbox entry found, attempting remote delivery\n";
                    my $res = M3MTA::Util::send_smtp($obj, $to);

                    if($res <= 0) {
                        # It failed, so re-queue
                        
                        $res = $self->backend->requeue($email);

                        if($res) {
                            print " - Remote delivery failed, message re-queued\n";
                        } else {
                            print " - Remote delivery failed, requeue also failed, message dropped\n";
                        }
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