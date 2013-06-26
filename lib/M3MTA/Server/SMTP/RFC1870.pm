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
    if(!$smtp->has_rfc('RFC1869')) {
        die "M3MTA::Server::SMTP::RFC1870 requires RFC1869";
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

    if(my $rfc = $session->smtp->has_rfc('RFC1652')) {
        return $rfc->mail($session, $data);
    }
    return $session->smtp->has_rfc('RFC0821')->mail($session, $data);
}

#------------------------------------------------------------------------------

1;