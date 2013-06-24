package M3MTA::Server::SMTP::RFC1869;

=head NAME
M3MTA::Server::SMTP::RFC1869 - SMTP extension format
=cut

use Modern::Perl;
use Moose;

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

	# Register this RFC
    $smtp->register_rfc('RFC1869', $self);
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;