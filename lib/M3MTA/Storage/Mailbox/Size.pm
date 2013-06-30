package M3MTA::Storage::Mailbox::Size;

use Modern::Perl;
use Moose;

has 'current' => ( is => 'rw', isa => 'Int' );
has 'maximum' => ( is => 'rw', isa => 'Int' );

#------------------------------------------------------------------------------

sub ok {
	my ($self, $size) = @_;
	return 1 if $size + $self->current < $self->maximum;
	return 0;
}

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