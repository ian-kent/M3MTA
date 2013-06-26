package M3MTA::Server::SMTP::RFC1652;

=head NAME
M3MTA::Server::SMTP::RFC1652 - 8BITMIME
=cut

use Modern::Perl;
use Moose;

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

	# Register this RFC
    if(!$smtp->has_rfc('RFC0821')) {
        die "M3MTA::Server::SMTP::RFC2487 requires RFC0821";
    }
    $smtp->register_rfc('RFC1652', $self);

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

    return "8BITMIME";
}

#------------------------------------------------------------------------------

sub mail {
    my ($self, $session, $data) = @_;

    # pass through to RFC0821
    # TODO strip off BODY=8BITMIME/7BIT
    $session->log("Using MAIL from RFC1652");

    return $session->smtp->has_rfc('RFC0821')->mail($session, $data);
}

#------------------------------------------------------------------------------

1;