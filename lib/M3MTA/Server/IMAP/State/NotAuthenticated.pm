package M3MTA::Server::IMAP::State::NotAuthenticated;

=head NAME
M3MTA::Server::IMAP::State::NotAuthenticated
=cut

use Mouse;
use Modern::Perl;
use MIME::Base64 qw/ decode_base64 encode_base64 /;

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
    	my $handle = $self->{handles}->{$session->stream->handle};
        my $tls_enabled = $handle ? 1 : 0;
        if($tls_enabled) {
            # It is, so dont send a welcome message and get rid of the old stream
            $settings->{send_welcome} = 0;
            $session->{tls_enabled} = 1;

            # Now we have a working TLS stream we don't need the handle
            delete $self->{handles}->{$handle};

            # FIXME the old stream doesn't get closed, it eventually times out
            #my $stream = $rfc->{handles}->{$self->stream->handle}->{session}->stream;
            #my $handle = $stream->steal_handle;
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
    my $user = $session->imap->_user_auth($username, $password);
    if($user) {
        $session->auth({});
        $session->auth->{success} = 1;
        $session->auth->{username} = $username;
        $session->auth->{password} = $password;
        $session->auth->{user} = $user;
        $session->respond($id, 'OK', '[CAPABILITY IMAP4REV1] User authenticated');
        $session->state('Authenticated');
    } else {
        $session->auth({});
        $session->respond($id, 'BAD', '[CAPABILITY IMAP4REV1] User authentication failed');
    }

    return 1;
}

#------------------------------------------------------------------------------

sub starttls {
	my ($self, $session, $id, $data) = @_;

	$session->respond($id, 'OK Begin TLS negotiation now');

	$session->stream->on(drain => sub {
		my $handle = $session->stream->handle;
		$handle = $session->server->start_tls($handle, {
			SSL_cert_file => $Mojo::IOLoop::Server::CERT,
			SSL_cipher_list => '!aNULL:!eNULL:!EXPORT:!DSS:!DES:!SSLv2:!LOW:RC4-SHA:RC4-MD5:ALL',
			SSL_honor_cipher_order => 1,
			SSL_key_file => $Mojo::IOLoop::Server::KEY,
			SSL_startHandshake => 0,
			SSL_verify_mode => 0x00,
			SSL_server => 1,
		});
		$self->{handles}->{$handle} = $handle;
		$session->log("Socket upgraded to SSL: %s", (ref $session->stream->handle));
	});

	return 1;
}

#------------------------------------------------------------------------------

1;