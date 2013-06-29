package M3MTA::Server::Models::Message::Attempt;

use Modern::Perl;
use Moose;

has 'date' => ( is => 'rw' );
has 'error' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->date($json->{date});
	$self->error($json->{error});

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		date => $self->date,
		error => $self->error,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;