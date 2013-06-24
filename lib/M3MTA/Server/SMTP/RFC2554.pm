package M3MTA::Server::SMTP::RFC2554;

=head NAME
M3MTA::Server::SMTP::RFC2554 - SMTP AUTH
=cut

use Modern::Perl;
use Moose;

use MIME::Base64 qw/ decode_base64 encode_base64 /;

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

    # Register this RFC
    if(!$smtp->has_rfc('RFC1869')) {
        die "M3MTA::Server::SMTP::RFC2554 requires RFC1869";
    }
    $smtp->register_rfc('RFC2554', $self);

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

    if($session->user && $session->user->{success}) {
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
            # TODO 334 constant
            $session->respond(334);
        }
        when (/^LOGIN$/) {
            # TODO 334 constant
            $session->respond(334, "VXNlcm5hbWU6");
            $session->state('AUTHENTICATE-LOGIN');
        }

        default {
            # TODO 535 constant
            $session->respond(535, "Error: authentication failed: no mechanism available");
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
    $session->log("authtype: %s", $authtype);

    for($authtype) {
        when (/LOGIN/) {
            $session->log("Authenticating using LOGIN mechanism");
            if(!$session->user || !$session->user->{username}) {
                my $username;
                eval {
                    $username = decode_base64($buffer);
                    $username =~ s/\r?\n$//s;
                };
                if($@ || !$username) {
                    $session->respond(535, "Error: authentication failed: another step is needed in authentication");
                    $session->log("Auth error: $@");
                    $session->state('ACCEPT');
                    $session->user(undef);
                    return;
                }
                $session->user({});
                $session->user->{username} = $username;
                $session->respond(334, "UGFzc3dvcmQ6");
            } else {
                my $password;
                eval {
                    $password = decode_base64($buffer);
                };
                $password =~ s/\r?\n$//s;
                if($@ || !$password) {
                    $session->respond(535, "Error: authentication failed: another step is needed in authentication");
                    $session->log("Auth error: $@");
                    $session->state('ACCEPT');
                    $session->user(undef);
                    return;
                }
                $session->user->{password} = $password;
                $session->log("LOGIN: Username [" . $session->user->{username} . "], Password [$password]");

                my $user = $session->smtp->get_user($session->user->{username}, $password);
                if(!$user) {
                    $session->respond(535, "LOGIN authentication failed");
                    $session->user(undef);
                } else {
                    $session->respond(235, "authentication successful");
                    $session->user->{success} = 1;
                    $session->user->{user} = $user;
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
                $session->respond(535, "authentication failed: another step is needed in authentication");
                $session->user(undef);
                $session->state('ACCEPT');
                return;
            }
            my @parts = split /\0/, $decoded;
            if(scalar @parts != 3) {
                $session->respond(535, "authentication failed: another step is needed in authentication");
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
                $session->respond(535, "PLAIN authentication failed");
                $session->user(undef);
            } else {
                $session->respond(235, "authentication successful");
                $session->user({});
                $session->user->{username} = $username;
                $session->user->{password} = $password;
                $session->user->{user} = $authed;
                $session->user->{success} = 1;
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