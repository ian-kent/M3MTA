package M3MTA::Server::SMTP::RFC2554;

=head NAME
M3MTA::Server::SMTP::RFC2554 - SMTP AUTH
=cut

use Modern::Perl;
use Moose;

use M3MTA::Log;

use MIME::Base64 qw/ decode_base64 encode_base64 /;

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

    # Register this RFC
    if(!$smtp->has_rfc('RFC5321')) {
        die "M3MTA::Server::SMTP::RFC2554 requires RFC5321";
    }
    $smtp->register_rfc('RFC2554', $self);

    # Add some reply codes
    $smtp->register_replycode({
        AUTHENTICATION_SUCCESSFUL  => 235,

        SERVER_CHALLENGE           => 334,

        PASSWORD_TRANSITION_NEEDED => 432,

        TEMPORARY_FAILURE          => 454,

        UNKNOWN_AUTH_FAIL_TODO     => 535,

        AUTHENTICATION_REQUIRED    => 530,
        AUTHENTICATION_TOO_WEAK    => 534,
        ENCRYPTION_REQUIRED        => 538,
    });

	# Register the AUTH command
	$smtp->register_command(['AUTH'], sub {
        my ($session, $data) = @_;
		$self->auth($session, $data);
	});

    # Register a state hook to capture data
    $smtp->register_state(qr/^AUTHENTICATE-?$/, sub {
        my ($session) = @_;
        $self->authenticate($session);
    });

    # Add a list of commands to EHLO output
    $smtp->register_helo(sub {
        $self->helo(@_);
    });
}

#------------------------------------------------------------------------------

sub helo {
    my ($self) = @_;
    # TODO mechanism registration
    return "AUTH PLAIN LOGIN";
}

#------------------------------------------------------------------------------

sub auth {
	my ($self, $session, $data) = @_;

    if($session->user) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "Error: already authenticated");
        return;
    }

    if(!$data) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{SYNTAX_ERROR_IN_PARAMETERS}, "Syntax: AUTH mechanism");
        return;
    }

    for($data) {
        when (/^PLAIN\s?(.*)?$/) {
            $session->state('AUTHENTICATE-PLAIN');
            if($1) {
                $session->log("Got authentication token with AUTH command: %s", $1);
                $session->buffer($1);
                $self->authenticate($session);
                $session->buffer('');
                return;
            }
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{SERVER_CHALLENGE});
        }
        when (/^LOGIN$/) {
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{SERVER_CHALLENGE}, "VXNlcm5hbWU6");
            $session->state('AUTHENTICATE-LOGIN');
        }

        default {
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "Error: authentication failed: no mechanism available");
        }
    }
}

#------------------------------------------------------------------------------

sub authenticate {
    my ($self, $session) = @_;

    my $buffer = $session->buffer;
    $buffer =~ s/\r?\n$//s;
    $session->buffer('');

    my ($authtype) = $session->state =~ /^AUTHENTICATE-(\w+)/;
    M3MTA::Log->debug("authtype: $authtype");

    for($authtype) {
        when (/LOGIN/) {
            M3MTA::Log->debug("Authenticating using LOGIN mechanism");
            if(!$session->user || !$session->stash('username')) {
                my $username;
                eval {
                    $username = decode_base64($buffer);
                    $username =~ s/\r?\n$//s;
                };
                if($@ || !$username) {
                    $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "Error: authentication failed: another step is needed in authentication");
                    $session->log("Auth error: $@");
                    $session->state('ACCEPT');
                    $session->user(undef);
                    delete $session->stash->{username} if $session->stash->{username};
                    delete $session->stash->{password} if $session->stash->{password};
                    return;
                }
                $session->stash(username => $username);
                $session->respond($M3MTA::Server::SMTP::ReplyCodes{SERVER_CHALLENGE}, "UGFzc3dvcmQ6");
            } else {
                my $password;
                eval {
                    $password = decode_base64($buffer);
                };
                $password =~ s/\r?\n$//s;
                if($@ || !$password) {
                    $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "Error: authentication failed: another step is needed in authentication");
                    $session->log("Auth error: $@");
                    $session->state('ACCEPT');
                    $session->user(undef);
                    delete $session->stash->{username} if $session->stash->{username};
                    delete $session->stash->{password} if $session->stash->{password};
                    return;
                }
                $session->stash(password => $password);
                $session->log("LOGIN: Username [" . $session->stash('username') . "], Password [$password]");

                my $user = $session->smtp->get_user($session->stash('username'), $password);
                if(!$user) {
                    $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "LOGIN authentication failed");
                    $session->user(undef);
                    delete $session->stash->{username} if $session->stash->{username};
                    delete $session->stash->{password} if $session->stash->{password};
                } else {
                    $session->respond($M3MTA::Server::SMTP::ReplyCodes{AUTHENTICATION_SUCCESSFUL}, "authentication successful");
                    $session->user($user);
                }

                $session->state('ACCEPT');
            }
        }
        when (/PLAIN/) {
            $session->log("Authenticating using PLAIN mechanism");
            my $decoded;
            eval {
                $decoded = decode_base64($buffer);
            };
            if($@ || !$decoded) {
                $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "authentication failed: another step is needed in authentication");
                $session->user(undef);
                $session->state('ACCEPT');
                return;
            }
            my @parts = split /\0/, $decoded;
            if(scalar @parts != 3) {
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
                $session->log("Authed: $authed");
                $session->respond($M3MTA::Server::SMTP::ReplyCodes{UNKNOWN_AUTH_FAIL_TODO}, "PLAIN authentication failed");
                $session->user(undef);
            } else {
                $session->respond($M3MTA::Server::SMTP::ReplyCodes{AUTHENTICATION_SUCCESSFUL}, "authentication successful");
                $session->user($authed);
            }
            $session->state('ACCEPT');
        }
        default {
            # TODO use correct error code
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_NOT_UNDERSTOOD}, "Invalid mechanism");
        }
    }
    return;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;