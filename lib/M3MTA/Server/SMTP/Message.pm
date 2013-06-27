package M3MTA::Server::SMTP::Message;

=head NAME
M3MTA::Server::SMTP::Message - SMTP Message
=cut

use Modern::Perl;
use Moose;

#------------------------------------------------------------------------------

has 'helo' 	=> ( is => 'rw' );
has 'id'	=> ( is => 'rw' );
has 'date'	=> ( is => 'rw' );
has 'to' 	=> ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'data' 	=> ( is => 'rw' );
has 'from'	=> ( is => 'rw' );

#------------------------------------------------------------------------------

sub to_hash {
	my ($self) = @_;

	my %obj = map { $_ => $self->{$_} } ('id', 'date', 'helo', 'to', 'data', 'from');

	return \%obj;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;