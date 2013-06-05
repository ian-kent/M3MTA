package M3MTA::Server::SMTP::Email;

=head NAME
M3MTA::Server::SMTP::RFC2487 - STARTTLS
=cut

use Mouse;

#------------------------------------------------------------------------------

has 'helo' 	=> ( is => 'rw' );
has 'id'	=> ( is => 'rw' );
has 'date'	=> ( is => 'rw' );
has 'to' 	=> ( is => 'rw' );
has 'data' 	=> ( is => 'rw' );
has 'from'	=> ( is => 'rw' );

#------------------------------------------------------------------------------

sub to_hash {
	my ($self) = @_;

	my %obj = map { $_ => $self->{$_} } ('id', 'date', 'helo', 'to', 'data', 'from');

	return \%obj;
}

#------------------------------------------------------------------------------

1;