package M3MTA::Storage::Mailbox::Folder;

use Modern::Perl;
use Moose;

has 'path' => ( is => 'rw', isa => 'Str', required => 1 );

has 'seen' => ( is => 'rw', isa => 'Int' );
has 'unseen' => ( is => 'rw', isa => 'Int' );
has 'recent' => ( is => 'rw', isa => 'Int' );
has 'nextuid' => ( is => 'rw', isa => 'Int' );

#------------------------------------------------------------------------------

sub exists {
	my ($self) = @_;

	return $self->seen + $self->unseen;
}

#------------------------------------------------------------------------------

sub flags {
	my ($self) = @_;
	# TODO
	return ["\\HasNoChildren"];
}

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->seen($json->{seen});
	$self->unseen($json->{unseen});
	$self->recent($json->{recent});
	$self->nextuid($json->{nextuid});

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		seen => $self->seen,
		unseen => $self->unseen,
		recent => $self->recent,
		nextuid => $self->nextuid,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;