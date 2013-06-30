package M3MTA::Server::SMTP::RFC4954::PLAIN;

# RFC4616 SASL PLAIN

use Modern::Perl;
use Moose;

use MIME::Base64 qw/ decode_base64 encode_base64 /;

has 'rfc' => ( is => 'rw', isa => 'M3MTA::Server::SMTP::RFC4954' );

#------------------------------------------------------------------------------

sub helo {
	my ($self, $session) = @_;

	if(!$session->{tls_enabled}) {
		# TODO make configurable
		return undef;
	}

	return "PLAIN";
}

#------------------------------------------------------------------------------

sub initial_response {
	my ($self, $session, $args) = @_;

	if(!$args) {
		$session->log("PLAIN received no args in initial response, returning 334");
		$session->respond($M3MTA::Server::SMTP::ReplyCodes{SERVER_CHALLENGE});
		return;
	}

	return $self->data($session, $args);
}

#------------------------------------------------------------------------------

sub data {
	my ($self, $session, $data) = @_;

	$session->log("Authenticating using PLAIN mechanism");

	# Decode base64 data
    my $decoded;
    eval {
    	$session->log("Decoding [$data]");
        $decoded = decode_base64($data);
    };

    # If there's an error, or we didn't decode anything
    if($@ || !$decoded) {
    	$session->log("Error decoding base64 string: $@");
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "authentication failed: another step is needed in authentication");
        $session->user(undef);
        $session->state('ACCEPT');
        return;
    }

    # Split at the null byte
    my @parts = split /\0/, $decoded;
    if(scalar @parts != 3) {
    	$session->log("Invalid PLAIN token");
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "authentication failed: another step is needed in authentication");
        $session->user(undef);
        $session->state('ACCEPT');
        return;
    }

    my $username = $parts[0];
    my $identity = $parts[1];
    my $password = $parts[2];

    $session->log("PLAIN: Username [$username], Identity [$identity], Password [$password]");

    if(!$username) {
        $session->log("Setting username to identity");
        $username = $identity;
    }

    my $authed = $session->smtp->get_user($username, $password);

    if(!$authed) {
        $session->log("Authentication failed");
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "PLAIN authentication failed");
        $session->user(undef);
    } else {
    	$session->log("Authentication successful");
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{AUTHENTICATION_SUCCESSFUL}, "authentication successful");
        $session->user($authed);
    }

    $session->state('ACCEPT');
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;