package M3MTA::Server::SMTP::RFC1870;

=head NAME
M3MTA::Server::SMTP::RFC1870 - SIZE
=cut

use Modern::Perl;
use Moose;

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

	# Register this RFC
    if(!$smtp->has_rfc('RFC0821') && !$smtp->has_rfc('RFC5321')) {
        die "M3MTA::Server::SMTP::RFC1870 requires RFC0821 or RFC5321";
    }
    $smtp->register_rfc('RFC1870', $self);

	# Add a list of commands to EHLO output
    $smtp->register_helo(sub {
        $self->helo(@_);
    });

    # Replace RFC0821's MAIL command
    $smtp->register_command('MAIL', sub {
        my ($session, $data) = @_;
        $self->mail($session, $data);
    });
}

#------------------------------------------------------------------------------

sub helo {
    my ($self, $session) = @_;

    # TODO configurable option to disable max size broadcast
    # still requires the keyword, but without arguments
    my $size = $session->smtp->config->{maximum_size} // "0";
    return "SIZE " . $size;
}

#------------------------------------------------------------------------------

sub mail {
    my ($self, $session, $data) = @_;

    # TODO strip off SIZE=n
    if($data =~ /SIZE=\d+/) {
        my ($size) = $data =~ /SIZE=(\d+)/;
        $data =~ s/\s*SIZE=\d+//;

        $session->log("Using MAIL from RFC1870, size provided [$size], remaining data [$data]");

        my $max_size = $session->smtp->config->{maximum_size} // 0;
        unless ($max_size <= 0) {
            if($size > $max_size) {
                $session->respond($M3MTA::Server::SMTP::ReplyCodes{EXCEEDED_STORAGE_ALLOCATION}, "Message too big");
                $session->log("Rejected message as too big");
                return;
            }
        }
    }

    # TODO need to get base to handle chained rfc implementations
    if(my $rfc = $session->smtp->has_rfc('RFC1652')) {
        return $rfc->mail($session, $data);
    }
    if(my $rfc = $session->smtp->has_rfc('RFC5321')) {
        return $rfc->mail($session, $data);
    }
    return $session->smtp->has_rfc('RFC0821')->mail($session, $data);
}

#------------------------------------------------------------------------------

sub rcpt {
    my ($self, $session, $data) = @_;

    $session->log("Using RCPT from RFC1870 (SIZE)");

    if(!$session->email->from) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "send MAIL command first");
        return;
    }
    if($session->email->data) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "DATA command already received");
        return;
    }
    if(my ($recipient) = $data =~ /^To:\s*<(.+)>$/i) {
        print "Checking size for $recipient\n";

        # TODO find out from backend what current/max mailbox size is
        # better still... have an object to represent the mailbox

        # return EXCEEDED_STORAGE_ALLOCATION
    }
    
    return $session->smtp->has_rfc('RFC0821')->rcpt($session, $data);
}

#------------------------------------------------------------------------------

1;