package M3MTA::Server::SMTP::RFC2821;

=head NAME
M3MTA::Server::SMTP::RFC2821 - Basic SMTP
=cut

use Modern::Perl;
use Moose;

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

	# Register this RFC
	$smtp->register_rfc('RFC2821', $self);

	# Add some reply codes
	$smtp->register_replycode({
	    SERVICE_READY                               => 220,
	    SERVICE_CLOSING_TRANSMISSION_CHANNEL        => 221,

	    REQUESTED_MAIL_ACTION_OK                    => 250,

	    START_MAIL_INPUT                            => 354,

	    COMMAND_NOT_UNDERSTOOD                      => 500,
	    SYNTAX_ERROR_IN_PARAMETERS                  => 501,
	    BAD_SEQUENCE_OF_COMMANDS                    => 503,	

	    REQUESTED_ACTION_NOT_TAKEN					=> 550,	
	});

	# Add a receive hook to prevent commands before a HELO
	$smtp->register_hook('command', sub {
		my ($session, $cmd, $data) = @_;

		# Don't let the command happen unless its HELO, EHLO, QUIT or NOOP
		if($cmd !~ /^(HELO|EHLO|QUIT|NOOP)$/ && !$session->email->helo) {
	        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "expecting HELO or EHLO");
	        return 0;
	    }

	    # Let the command continue
	    return 1;
	});

	# Add the commands
	$smtp->register_command(['HELO','EHLO'], sub {
		my ($session, $data) = @_;
		$self->helo($session, $data);
	});

	$smtp->register_command('NOOP', sub {
		my ($session, $data) = @_;
		$self->noop($session, $data);
	});

	$smtp->register_command('QUIT', sub {
		my ($session, $data) = @_;
		$self->quit($session, $data);
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

	$smtp->register_command('MAIL', sub {
		my ($session, $data) = @_;
		$self->mail($session, $data);
	});

	$smtp->register_command('RCPT', sub {
		my ($session, $data) = @_;
		$self->rcpt($session, $data);
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

    # Everything except last line has - between status and message

    my @helos = ();
    for (my $i = 0; $i < scalar @{$session->smtp->helo}; $i++) {
    	my $helo = &{$session->smtp->helo->[$i]}($session);
    	push @helos, $helo if $helo;
    }

    $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK}.((scalar @helos == 0) ? ' ' : '-')."Hello '$data'. I'm", $session->smtp->ident);
    for (my $i = 0; $i < scalar @helos; $i++) {
    	my $helo = $helos[$i];
    	if($i == (scalar @helos) - 1) {
    		$session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK}, $helo);
    	} else {
    		$session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_MAIL_ACTION_OK} . "-" . $helo);
    	}
    }
}

#------------------------------------------------------------------------------

sub noop {
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

sub mail {
	my ($self, $session, $data) = @_;

	if($session->email->from) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "MAIL command already received");
        return;
    }
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

    if($data =~ /^To:\s*<(.+)>$/i) {
        print "Checking delivery for $1\n";
        my $r = eval {
            return $session->smtp->can_accept_mail($session, $1);
        };
        print "Error: $@\n" if $@;
        print "RESULT IS: $r\n";
        if(!$r) {
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{REQUESTED_ACTION_NOT_TAKEN}, "Not permitted to send to this address");
            return;
        }
        
        if(!$session->email->to) {
            $session->email->to([]);
        }
        push @{$session->email->to}, $1;
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

        $session->email->data($data);

        $session->respond($session->smtp->queue_message($session->email));

        $session->state('FINISHED');
        $session->buffer('');
    }
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;