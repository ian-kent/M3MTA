package M3MTA::Storage::Domain;

use Modern::Perl;
use Moose;

has 'domain' => ( is => 'rw', isa => 'Str' );
has 'delivery' => ( is => 'rw', isa => 'Str' );
has 'postmaster' => ( is => 'rw', isa => 'Str' );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->domain($json->{domain});
	$self->delivery($json->{delivery});
	$self->postmaster($json->{postmaster});

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		domain => $self->domain,
		delivery => $self->delivery,
		postmaster => $self->postmaster,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;