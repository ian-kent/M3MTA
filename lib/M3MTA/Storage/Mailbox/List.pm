package M3MTA::Storage::Mailbox::List;

use Modern::Perl;
use Moose;
extends 'M3MTA::Storage::Mailbox';

has 'owner' => ( is => 'rw', isa => 'Str' );
has 'members' => ( is => 'rw', isa => 'ArrayRef' );

#------------------------------------------------------------------------------

after 'from_json' => sub {
	my ($self, $json) = @_;

	$self->owner($json->{owner});
	$self->members($json->{members});

	return $self;
};

#------------------------------------------------------------------------------

around 'to_json' => sub {
	my ($orig, $self) = @_;

	my $json = $self->$orig();

	return {
		%$json,
		owner => $self->owner,
		members => $self->members,
	};
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;