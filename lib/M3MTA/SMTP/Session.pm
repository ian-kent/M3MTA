package M3MTA::SMTP::Session;

use Modern::Perl;
use Mouse;
use Data::Dumper;
use MIME::Base64 qw/ decode_base64 encode_base64 /;

use M3MTA::SMTP::Email;

#------------------------------------------------------------------------------

has 'smtp'   => ( is => 'rw' );
has 'stream' => ( is => 'rw' );
has 'ioloop' => ( is => 'rw' );
has 'id' 	 => ( is => 'rw' );

has 'user'	 => ( is => 'rw' );
has 'buffer' => ( is => 'rw' );
has 'email'  => ( is => 'rw' );
has 'state'	 => ( is => 'rw' );

#------------------------------------------------------------------------------

sub log {
	my $self = shift;
	return if !$self->smtp->debug;

	my $message = shift;
	$message = '[SESSION] ' . $message;

	$self->smtp->log($message, @_);
}

#------------------------------------------------------------------------------

sub respond {
    my ($self, @cmd) = @_;

    my $c = join ' ', @cmd;

    $self->stream->write("$c\n");
    $self->log("[SENT] %s", $c);

    return;
}

#------------------------------------------------------------------------------

sub accept {
    my ($self) = @_;

    $self->respond($M3MTA::SMTP::ReplyCodes{SERVICE_READY}, $self->smtp->config->{hostname}, $self->smtp->ident);

    $self->buffer('');
    $self->email(new M3MTA::SMTP::Email);
    $self->state('ACCEPT');

    $self->stream->on(error => sub {
    	my ($stream, $error) = @_;
        $self->log("Stream error: %s", $error);
    });
    $self->stream->on(close => sub {
        $self->log("Stream closed");
    });
    $self->stream->on(read => sub {
        my ($stream, $chunk) = @_;

        $self->buffer(($self->buffer ? $self->buffer : '') . $chunk);
        $self->receive if $self->buffer =~ /\r?\n$/m;
    });
}

#------------------------------------------------------------------------------

sub receive {
	my ($self) = @_;

	$self->log("[RECD] %s", $self->buffer);

    if($self->state =~ /^AUTHENTICATE-?/) {
        return $self->authenticate;
    }

    if($self->state eq 'DATA') {
        return $self->data;
    }
    
    my $buffer = $self->buffer;
    return unless $buffer =~ /\r\n$/gs;
    $self->buffer('');

    my ($cmd, $data) = $buffer =~ m/^(\w+)\s?(.*)\r\n$/s;
    $self->log("Got cmd[%s], data[%s]", $cmd, $data);

    if($cmd !~ /^(HELO|EHLO|QUIT)$/ && !$self->email->helo) {
        $self->respond($M3MTA::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "expecting HELO or EHLO");
        return;
    }

    for($cmd) {
        when ( /^(HELO|EHLO)$/ ){ $self-> helo ($data) }
        when ( /^NOOP$/		   ){ $self-> noop         }
        when ( /^QUIT$/		   ){ $self-> quit         }

        when ( /^AUTH$/		   ){ $self-> auth ($data) }
        when ( /^MAIL$/		   ){ $self-> mail ($data) }
        when ( /^RCPT$/		   ){ $self-> rcpt ($data) }
        when ( /^DATA$/		   ){ $self-> data ($data) }

        # TODO hooks and extensions

        default {
            $self->respond($M3MTA::SMTP::ReplyCodes{COMMAND_NOT_UNDERSTOOD}, "Command not understood.");
        }
    }
}

#------------------------------------------------------------------------------

sub helo {
	my ($self, $data) = @_;

	if(!$data || $data =~ /^\s*$/) {
        $self->respond($M3MTA::SMTP::ReplyCodes{SYNTAX_ERROR_IN_PARAMETERS}, "you didn't introduce yourself");
        return;
    }

    $self->email->helo($data);

    # Everything except last line has - between status and message
    $self->respond("250-Hello '$data'. I'm", $self->smtp->ident);
    $self->respond("250 AUTH PLAIN LOGIN");

    # TODO hooks and extensions
}

#------------------------------------------------------------------------------

sub noop {
	my ($self) = @_;

	$self->respond($M3MTA::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK}, "Ok.");
}

#------------------------------------------------------------------------------

sub quit {
	my ($self) = @_;

	$self->respond($M3MTA::SMTP::ReplyCodes{SERVICE_CLOSING_TRANSMISSION_CHANNEL}, "Bye.");

    $self->stream->on(drain => sub {
        $self->stream->close;
    });
}

#------------------------------------------------------------------------------

sub data {
	my ($self, $data) = @_;

	if($self->state ne 'DATA') {
		# Called from DATA command
		if(scalar @{$self->email->to} == 0) {
            $self->respond($M3MTA::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "send RCPT command first");
            return;
        }

        if($self->email->data) {
            $self->respond($M3MTA::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "DATA command already received");
            return;
        }

        $self->respond($M3MTA::SMTP::ReplyCodes{START_MAIL_INPUT}, "Send mail, end with \".\" on line by itself");
        $self->state('DATA');
        return;
	}

	# Called again after DATA command
	if($self->buffer =~ /.*\r\n\.\r\n$/s) {
        my $data = $self->buffer;        
        $data =~ s/\r\n\.\r\n$//s;

        $self->email->data($data);

        $self->respond($self->smtp->_queued($self->email));

        $self->state('FINISHED');
        $self->buffer('');
    }
}

#------------------------------------------------------------------------------

sub auth {
	my ($self, $data) = @_;

    if($self->user && $self->user->{success}) {
        $self->respond($M3MTA::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "Error: already authenticated");
        return;
    }

    if(!$data) {
        $self->respond($M3MTA::SMTP::ReplyCodes{SYNTAX_ERROR_IN_PARAMETERS}, "Syntax: AUTH mechanism");
        return;
    }

    for($data) {
        when (/^PLAIN\s?(.*)?$/) {
            $self->state('AUTHENTICATE-PLAIN');
            if($1) {
            	$self->log("Got authentication token with AUTH command: %s", $1);
            	$self->buffer($1);
            	$self->authenticate;
            	$self->buffer('');
            	return;
            }
            # TODO 334 constant
            $self->respond(334);
        }
        when (/^LOGIN$/) {
        	# TODO 334 constant
            $self->respond(334, "VXNlcm5hbWU6");
            $self->state('AUTHENTICATE-LOGIN');
        }

        default {
        	# TODO 535 constant
            $self->respond(535, "Error: authentication failed: no mechanism available");
        }
    }
}

#------------------------------------------------------------------------------

sub authenticate {
	my ($self) = @_;

	my $buffer = $self->buffer;
	$buffer =~ s/\r?\n$//s;
	$self->buffer('');

	my ($authtype) = $self->state =~ /^AUTHENTICATE-(\w+)/;
	$self->log("authtype: %s", $authtype);

	for($authtype) {
    	when (/LOGIN/) {
    		$self->log("Authenticating using LOGIN mechanism");
	        if(!$self->user || !$self->user->{username}) {
	            my $username;
	            eval {
	                $username = decode_base64($buffer);
	                $username =~ s/\r?\n$//s;
	            };
	            if($@ || !$username) {
	                $self->respond(535, "Error: authentication failed: another step is needed in authentication");
	                $self->log("Auth error: $@");
	                $self->state('ACCEPT');
	                $self->user(undef);
	                return;
	            }
	            $self->user({});
	            $self->user->{username} = $username;
	            $self->respond(334, "UGFzc3dvcmQ6");
	        } else {
	            my $password;
	            eval {
	                $password = decode_base64($buffer);
	            };
	            $password =~ s/\r?\n$//s;
	            if($@ || !$password) {
	                $self->respond(535, "Error: authentication failed: another step is needed in authentication");
	                $self->log("Auth error: $@");
	                $self->state('ACCEPT');
	                $self->user(undef);
	                return;
	            }
	            $self->user->{password} = $password;
	            $self->log("LOGIN: Username [" . $self->user->{username} . "], Password [$password]");

	            my $user = $self->smtp->_user_auth($self->user->{username}, $password);
	            if(!$user) {
	                $self->respond(535, "LOGIN authentication failed");
	                $self->user(undef);
	            } else {
	                $self->respond(235, "authentication successful");
	                $self->user->{success} = 1;
	                $self->user->{user} = $user;
	            }

	            $self->state('ACCEPT');
	        }
	    }
	    when (/PLAIN/) {
	    	$self->log("Authenticating using PLAIN mechanism");
	        my $decoded;
	        eval {
	            $decoded = decode_base64($buffer);
	        };
	        if($@ || !$decoded) {
	            $self->respond(535, "authentication failed: another step is needed in authentication");
	            $self->user(undef);
	            $self->state('ACCEPT');
	            return;
	        }
	        my @parts = split /\0/, $decoded;
	        if(scalar @parts != 3) {
	            $self->respond(535, "authentication failed: another step is needed in authentication");
	            $self->user(undef);
	            $self->state('ACCEPT');
	            return;
	        }
	        my $username = $parts[0];
	        my $identity = $parts[1];
	        my $password = $parts[2];

	        $self->log("PLAIN: Username [$username], Identity [$identity], Password [$password]");

	        if(!$username) {
	        	$self->log("Setting username to identity");
	        	$username = $identity;
	    	}

	        my $authed = $self->smtp->_user_auth($username, $password);
	        if(!$authed) {
	            $self->log("Authed: $authed");
	            $self->respond(535, "PLAIN authentication failed");
	            $self->user(undef);
	        } else {
	            $self->respond(235, "authentication successful");
	            $self->user({});
	            $self->user->{username} = $username;
	            $self->user->{password} = $password;
	            $self->user->{user} = $authed;
	            $self->user->{success} = 1;
	        }
	        $self->state('ACCEPT');
	    }
	    default {
	    	# TODO use correct error code
	    	$self->respond($M3MTA::SMTP::ReplyCodes{COMMAND_NOT_UNDERSTOOD}, "Invalid mechanism");
	    }
    }
    return;
}

#------------------------------------------------------------------------------

sub mail {
	my ($self, $data) = @_;

	if($self->email->from) {
        $self->respond($M3MTA::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "MAIL command already received");
        return;
    }
    if($data =~ /^From:\s*<(.+)>$/i) {
        print "Checking user against $1\n";
        my $r = eval {
            return $self->smtp->_user_send($self, $1);
        };
        print "Error: $@\n" if $@;

        if(!$r) {
            $self->respond(535, "Not permitted to send from this address");
            return;
        }
        $self->email->from($1);
        $self->respond(250, "$1 sender ok");
        #$self->respond(250, "2.1.0 Ok");
        return;
    }
    $self->respond($M3MTA::SMTP::ReplyCodes{SYNTAX_ERROR_IN_PARAMETERS}, "Invalid sender");
}

#------------------------------------------------------------------------------

sub rcpt {
	my ($self, $data) = @_;

	if(!$self->email->from) {
        $self->respond($M3MTA::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "send MAIL command first");
        return;
    }
    if($self->email->data) {
        $self->respond($M3MTA::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "DATA command already received");
        return;
    }

    if($data =~ /^To:\s*<(.+)>$/i) {
        print "Checking delivery for $1\n";
        my $r = eval {
            return $self->smtp->_mail_accept($self, $1);
        };
        print "Error: $@\n" if $@;
        print "RESULT IS: $r\n";
        if(!$r) {
            $self->respond(501, "Not permitted to send to this address");
            return;
        }
        
        if(!$self->email->to) {
            $self->email->to([]);
        }
        push @{$self->email->to}, $1;
        $self->respond(250, "$1 recipient ok");
        return;
    }
    $self->respond(501, "Invalid recipient");
}

#------------------------------------------------------------------------------

1;