package M3MTA::Server::SMTP::RFC0821;

=head NAME
M3MTA::Server::SMTP::RFC0821 - Basic SMTP
=cut

use Modern::Perl;
use Moose;

use Data::Uniqid qw/ luniqid /;
use Date::Format;

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

	# Register this RFC
    $smtp->register_rfc('RFC0821', $self);

	# Add some reply codes
	$smtp->register_replycode({
	    SERVICE_READY                               => 220,
	    SERVICE_CLOSING_TRANSMISSION_CHANNEL        => 221,

	    REQUESTED_MAIL_ACTION_OK                    => 250,
	    ARGUMENT_NOT_CHECKED                        => 252,

	    START_MAIL_INPUT                            => 354,

		COMMAND_NOT_UNDERSTOOD                      => 500,
		SYNTAX_ERROR_IN_PARAMETERS                  => 501,
		COMMAND_NOT_IMPLEMENTED                     => 502,
	    BAD_SEQUENCE_OF_COMMANDS                    => 503,	

	    REQUESTED_ACTION_NOT_TAKEN					=> 550,	
	});

	# Add a receive hook to prevent commands before a HELO
	$smtp->register_hook('command', sub {
		my ($session, $cmd, $data, $result) = @_;

        $session->log("Checking command $cmd in RFC0821");

		# Don't let the command happen unless its HELO, EHLO, QUIT, NOOP or RSET
		if($cmd !~ /^(HELO)$/ && !$session->email->helo) {
            $result->{response} = [$M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "expecting HELO"];
            return 1;
	    }

	    # Let the command continue
        return 1;
	});

	# Add the commands
    $smtp->register_command('HELO', sub {
        my ($session, $data) = @_;
        $self->helo($session, $data, 0);
    });

    $smtp->register_command('SEND', sub {
        my ($session, $data) = @_;
        $self->send($session, $data, 0);
    });

    $smtp->register_command('SOML', sub {
        my ($session, $data) = @_;
        $self->soml($session, $data, 0);
    });

    $smtp->register_command('SAML', sub {
        my ($session, $data) = @_;
        $self->saml($session, $data, 0);
    });

    $smtp->register_command('TURN', sub {
        my ($session, $data) = @_;
        $self->turn($session, $data, 0);
    });

	$smtp->register_command('MAIL', sub {
		my ($session, $data) = @_;
		$self->mail($session, $data);
	});

	$smtp->register_command('RCPT', sub {
		my ($session, $data) = @_;
		$self->rcpt($session, $data);
	});

	$smtp->register_command('DATA', sub {
		my ($session, $data) = @_;
		$self->data($session, $data);
	});

	# Register a state hook to capture data
	$smtp->register_state(qr/^DATA$/, sub {
		my ($session) = @_;
		$self->data($session);
	});

	$smtp->register_command('RSET', sub {
        my ($session, $data) = @_;
        $self->rset($session, $data);
    });

    if(!exists $smtp->config->{commands}->{vrfy} || $smtp->config->{commands}->{vrfy}) {
        $smtp->register_command('VRFY', sub {
            my ($session, $data) = @_;
            $self->vrfy($session, $data);
        });
        $smtp->register_helo(sub {
            return "VRFY";
        });
    }

    if(!exists $smtp->config->{commands}->{expn} || $smtp->config->{commands}->{expn}) {
        $smtp->register_command('EXPN', sub {
            my ($session, $data) = @_;
            $self->expn($session, $data);
        });
        $smtp->register_helo(sub {
            return "EXPN";
        });
    }

	$smtp->register_command('NOOP', sub {
		my ($session, $data) = @_;
		$self->noop($session, $data);
	});

	$smtp->register_command('QUIT', sub {
		my ($session, $data) = @_;
		$self->quit($session, $data);
	});

	$smtp->register_command('HELP', sub {
		my ($session, $data) = @_;
		$self->help($session, $data);
	});
}

#------------------------------------------------------------------------------

sub helo {
	my ($self, $session, $data) = @_;

	if(!$data || $data =~ /^\s*$/) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{SYNTAX_ERROR_IN_PARAMETERS}, "you didn't introduce yourself");
        return;
    }

    $session->email->helo($data);

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK} . " Hello '$data'. I'm", $session->smtp->ident);
}

#------------------------------------------------------------------------------

sub mail {
	my ($self, $session, $data) = @_;

	if($session->email->from) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "MAIL command already received");
        return;
    }

    # Clear the buffers
    $session->email->from('');
    $session->email->to([]);
    $session->email->data('');

    if($data =~ /^From:\s*<(.+)>$/i) {
        $session->log("Checking user against '%s'", $1);
        my $r = eval {
            return $session->smtp->can_user_send($session, $1);
        };
        $session->log("Error: %s", $@) if $@;

        if(!$r) {
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_ACTION_NOT_TAKEN}, "Not permitted to send from this address");
            return;
        }
        $session->email->from($1);
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK}, "$1 sender ok");
        return;
    }
    $session->respond($M3MTA::Server::SMTP::ReplyCodes{SYNTAX_ERROR_IN_PARAMETERS}, "Invalid sender");
}

#------------------------------------------------------------------------------

sub rcpt {
	my ($self, $session, $data) = @_;

	if(!$session->email->from) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "send MAIL command first");
        return;
    }
    if($session->email->data) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "DATA command already received");
        return;
    }

    if(my ($recipient) = $data =~ /^To:\s*<(.+)>$/i) {
        print "Checking delivery for $recipient\n";
        my $r = eval {
            return $session->smtp->can_accept_mail($session, $recipient);
        };
        print "Error: $@\n" if $@;
        print "RESULT IS: $r\n";
        if(!$r) {
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_ACTION_NOT_TAKEN}, "Not permitted to send to this address");
            return;
        }
        
        if($r == 2) {
            # local delivery domain but no user
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_ACTION_NOT_TAKEN}, "Invalid recipient");
            return;
        }

        if(!$session->email->to) {
            $session->email->to([]);
        }
        push @{$session->email->to}, $recipient;
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK}, "$1 recipient ok");
        return;
    }
    $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_ACTION_NOT_TAKEN}, "Invalid recipient");
}

#------------------------------------------------------------------------------

sub data {
	my ($self, $session, $data) = @_;

	if($session->state ne 'DATA') {
		# Called from DATA command
		if(scalar @{$session->email->to} == 0) {
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "send RCPT command first");
            return;
        }

        if($session->email->data) {
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "DATA command already received");
            return;
        }

        $session->respond($M3MTA::Server::SMTP::ReplyCodes{START_MAIL_INPUT}, "Send mail, end with \".\" on line by itself");
        $session->state('DATA');
        return;
	}

	# Called again after DATA command
	if($session->buffer =~ /.*\r\n\.\r\n$/s) {
        my $data = $session->buffer;        
        $data =~ s/\r\n\.\r\n$//s;

        # Get or create the message id
        if(my ($msg_id) = $data =~ /message-id: <(.*)>/mi) {
        	$session->email->id($msg_id);
        } else {
        	# Generate a new one
        	my $id = luniqid . "@" . $session->smtp->config->{hostname};
        	$session->email->id($id);
        	$data = "Message-ID: $id\r\n$data";
        }
 
        # Add the return path
        my $newdata .= "Return-Path: <" . $session->email->from . ">\r\n";

        # Add the received header
        my $now = time2str("%d %b %y %H:%M:%S %Z", time);
        $newdata .= "Received: from " . $session->email->helo . " by " . $session->smtp->config->{hostname} . " (" . $session->smtp->ident . ")\r\n";
        # TODO add in the 'for whoever' bit?
        #$newdata .= "          id " . $session->email->id . " for " . $session->email->to . "; " . $now . "\r\n";
        $newdata .= "          id " . $session->email->id . " ; " . $now . "\r\n";

        # Prepend to the original data
        $data = $newdata . $data;

        $session->email->data($data);

        $session->respond($session->smtp->queue_message($session->email));

        $session->state('FINISHED');
        $session->buffer('');
    }
}

#------------------------------------------------------------------------------

sub noop {
	my ($self, $session, $data) = @_;

	$session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK}, "Ok.");
}

#------------------------------------------------------------------------------

sub help {
	my ($self, $session, $data) = @_;

	$session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK}, "Ok.");
}

#------------------------------------------------------------------------------

sub quit {
	my ($self, $session, $data) = @_;

	$session->respond($M3MTA::Server::SMTP::ReplyCodes{SERVICE_CLOSING_TRANSMISSION_CHANNEL}, "Bye.");

    $session->stream->on(drain => sub {
        $session->stream->close;
    });
}

#------------------------------------------------------------------------------

sub rset {
    my ($self, $session, $data) = @_;

    $session->buffer('');
    $session->email(new M3MTA::Server::SMTP::Message);
    $session->state('ACCEPT');

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK}, "Ok.");
}

#------------------------------------------------------------------------------

sub vrfy {
    my ($self, $session, $data) = @_;

    # TODO implement properly, with config to switch on (default off)

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{ARGUMENT_NOT_CHECKED}, "Argument not checked.");
}

#------------------------------------------------------------------------------

sub expn {
    my ($self, $session, $data) = @_;

    # TODO implement properly, with config to switch on (default off)

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{ARGUMENT_NOT_CHECKED}, "Argument not checked.");
}

#------------------------------------------------------------------------------

sub send {
	my ($self, $session, $data) = @_;

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_NOT_IMPLEMENTED} . " Command not implemented");
}

#------------------------------------------------------------------------------

sub soml {
	my ($self, $session, $data) = @_;

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_NOT_IMPLEMENTED} . " Command not implemented");
}

#------------------------------------------------------------------------------

sub saml {
	my ($self, $session, $data) = @_;

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_NOT_IMPLEMENTED} . " Command not implemented");
}

#------------------------------------------------------------------------------

sub turn {
	my ($self, $session, $data) = @_;

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_NOT_IMPLEMENTED} . " Command not implemented");
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;