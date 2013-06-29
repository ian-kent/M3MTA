package M3MTA::Server::Models::Mailbox::Size;

use Modern::Perl;
use Moose;

has 'current' => ( is => 'rw', isa => 'Int' );
has 'maximum' => ( is => 'rw', isa => 'Int' );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->current($json->{current});
	$self->maximum($json->{maximum});

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		current => $self->current,
		maximum => $self->maximum,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;