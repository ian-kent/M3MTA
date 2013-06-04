package M3MTA::SMTP::RFC2487;

use IO::Socket::SSL;
use Mouse;
use Scalar::Util qw/weaken/;

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
    });

    $smtp->register_hook('accept', sub {
    	my ($session, $settings) = @_;

    	# Find out if its a TLS stream
        my $tls_enabled = $self->{handles}->{$session->stream->handle} ? 1 : 0;
        if($tls_enabled) {
            # It is, so dont send a welcome message and get rid of the old stream
            $settings->{send_welcome} = 0;

            # Hook into stream close to clean up
            my $handle = $session->stream->handle;
            weaken $handle;
            $session->stream->on(close => sub {
            	$session->log("TLS stream closed");
	            delete $self->{handles}->{$handle};
            });

            # FIXME the old stream doesn't get closed, it eventually times out
            #my $stream = $rfc->{handles}->{$self->stream->handle}->{session}->stream;
            #my $handle = $stream->steal_handle;
        }
        $session->log("TLS enabled: %s", $tls_enabled);

    	return 1;
    });

}

sub helo {
    my ($self, $session) = @_;
    
    return undef if $session->{tls_enabled};

    return "STARTTLS";
}

sub starttls {
	my ($self, $session) = @_;

	$session->respond($M3MTA::SMTP::ReplyCodes{SERVICE_READY}, "Go ahead.");

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
		$self->{handles}->{$handle} = {
			session => $session,
			handle => $handle
		};
		$session->log("Socket upgraded to SSL: %s", (ref $session->stream->handle));
	});
}

1;