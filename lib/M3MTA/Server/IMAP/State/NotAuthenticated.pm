package M3MTA::Server::IMAP::State::NotAuthenticated;

=head NAME
M3MTA::Server::IMAP::State::NotAuthenticated
=cut

use Modern::Perl;
use Moose;

use MojoX::IOLoop::Server::StartTLS;

use MIME::Base64 qw/ decode_base64 encode_base64 /;

has 'handles' => ( is => 'rw', default => sub { {} } );

#------------------------------------------------------------------------------

sub register {
	my ($self, $imap) = @_;
	
	$imap->register_rfc('RFC3501.NotAuthenticated', $self);
	$imap->register_state('NotAuthenticated', sub {
		$self->receive(@_);
	});

	$imap->register_hook('accept', sub {
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
        }
        $session->log("TLS enabled: %s", $tls_enabled);

    	return 1;
    });
}

#------------------------------------------------------------------------------

sub receive {
	my ($self, $session, $id, $cmd, $data) = @_;
	$session->log("Received data in NotAuthenticated state");

	return 0 if $cmd !~ /(AUTHENTICATE|STARTTLS|LOGIN)/i;

	$cmd = lc $cmd;
	return $self->$cmd($session, $id, $data);
}

#------------------------------------------------------------------------------

sub authenticate {
	my ($self, $session, $id, $data) = @_;

	# TODO implement authentication mechanisms
	$session->authtype(undef);
	$session->respond($id, 'NO', 'Unsupported authentication type');

	return 1;
}

#------------------------------------------------------------------------------

sub login {
	my ($self, $session, $id, $data) = @_;

	my ($username, $password) = $data =~ /"(.*)"\s"(.*)"/; # TODO quotes not always provided
    my $user = $session->imap->get_user($username, $password);
    if($user) {
        $session->auth($user);
        $session->respond($id, 'OK', '[CAPABILITY IMAP4REV1] User authenticated');
        $session->state('Authenticated');
    } else {
        $session->auth(undef);
        $session->respond($id, 'BAD', '[CAPABILITY IMAP4REV1] User authentication failed');
    }

    return 1;
}

#------------------------------------------------------------------------------

sub starttls {
	my ($self, $session, $id, $data) = @_;

	$session->respond($id, 'OK Begin TLS negotiation now');

	MojoX::IOLoop::Server::StartTLS::start_tls(
        $session->server,
        $session->stream,
        undef,
        sub {
            my ($handle) = @_;
            $session->log("Socket upgraded to SSL: %s", (ref $handle));
            $self->handles->{$handle} = $handle;
        }
    );

	return 1;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;