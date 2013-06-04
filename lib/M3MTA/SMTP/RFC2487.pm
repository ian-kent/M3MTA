package M3MTA::SMTP::RFC2487;

use IO::Socket::SSL;
use Mouse;

sub register {
	my ($self, $smtp) = @_;

	# Register this RFC
	if(!$smtp->has_rfc('RFC2554')) {
        die "M3MTA::SMTP::RFC2487 requires RFC2554";
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
    })

}

sub helo {
    my ($self, $session) = @_;
    
    return undef if $session->{tls_enabled};

    return "STARTTLS";
}

sub starttls {
	my ($self, $session) = @_;

	print "Socket: " . (ref $session->stream->handle) . "\n";

	$session->respond($M3MTA::SMTP::ReplyCodes{SERVICE_READY}, "Go ahead.");
print STDERR "session_id = " . $session->id . "\n";
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
}

1;