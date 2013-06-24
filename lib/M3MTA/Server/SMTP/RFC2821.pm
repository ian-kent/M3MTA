package M3MTA::Server::SMTP::RFC2821;

=head NAME
M3MTA::Server::SMTP::RFC2821 - Extended SMTP
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
	});

	# Add a receive hook to prevent commands before a HELO
	$smtp->register_hook('command', sub {
		my ($session, $cmd, $data, $result) = @_;

        $session->log("Checking command $cmd in RFC2821");

        my %cmds = (
            EHLO => 1,
            QUIT => 1,
            NOOP => 1,
            RSET => 1,
        );
        $cmds{HELO} = 1 if $smtp->has_rfc('RFC0821');

		# Don't let the command happen unless its HELO, EHLO, QUIT, NOOP or RSET
		if(!$cmds{$cmd} && !$session->email->helo) {
            $result->{response} = [$M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "expecting HELO or EHLO"];
            return 1;
	    }

	    # Let the command continue
        $result->{response} = undef; # clear any errors set by RFC0821
        return 1;
	});

	# Add the commands
	$smtp->register_command('EHLO', sub {
		my ($session, $data) = @_;
		$self->ehlo($session, $data, 1);
	});
}

#------------------------------------------------------------------------------

sub ehlo {
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

__PACKAGE__->meta->make_immutable;