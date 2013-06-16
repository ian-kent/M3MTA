package M3MTA::Server::SMTP::RFC2487;

=head NAME
M3MTA::Server::SMTP::RFC2487 - STARTTLS
=cut

use Modern::Perl;
use Moose;

use MojoX::IOLoop::Server::StartTLS;

use IO::Socket::SSL;
use Scalar::Util qw/weaken/;

has 'handles' => ( is => 'rw', default => sub { {} } );

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

	# Register this RFC
	if(!$smtp->has_rfc('RFC2554')) {
        die "M3MTA::Server::SMTP::RFC2487 requires RFC2554";
    }
    $smtp->register_rfc('RFC2487', $self);

	# add commands/callbacks to list
    $smtp->register_command(['STARTTLS'], sub {
        my ($session, $data) = @_;
		$self->starttls($session, $data);
	});

	# Add a list of commands to EHLO output
    $smtp->register_helo(sub {
        $self->helo(@_);
    });

    $smtp->register_hook('accept', sub {
    	my ($session, $settings) = @_;

    	# Find out if its a TLS stream
    	my $handle = $self->handles->{$session->stream->handle};
        my $tls_enabled = $handle ? 1 : 0;
        if($tls_enabled) {
            # It is, so dont send a welcome message and get rid of the old stream
            $settings->{send_welcome} = 0;
            $session->{tls_enabled} = 1;

            # Now we have a working TLS stream we don't need the handle
            delete $self->handles->{$handle};

            # FIXME Still something wrong, couple of errors from Mojo::Reactor::Poll
            #my $old_handle = $self->{handles}->{$session->stream->handle};
            #delete $session->ioloop->{io}->{$old_handle};
            #$session->stream->reactor->remove($old_handle);
            #$old_handle->close;
        }
        $session->log("TLS enabled: %s", $tls_enabled);

    	return 1;
    });

}

#------------------------------------------------------------------------------

sub helo {
    my ($self, $session) = @_;
    
    return undef if $session->{tls_enabled};

    return "STARTTLS";
}

#------------------------------------------------------------------------------

sub starttls {
	my ($self, $session) = @_;

	$session->respond($M3MTA::Server::SMTP::ReplyCodes{SERVICE_READY}, "Go ahead.");

    MojoX::IOLoop::Server::StartTLS::start_tls(
        $session->server,
        $session->stream,
        undef,
        sub {
            my ($handle) = @_;
            $session->log("Socket upgraded to SSL: %s", (ref $handle));
            $self->handles->{$handle} = $handle;
        }
    )
}

#------------------------------------------------------------------------------

1;