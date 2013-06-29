package M3MTA::Server::Models::Mailbox::Delivery;

use Modern::Perl;
use Moose;

has 'path' => ( is => 'rw', isa => 'Str' );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->path($json->{path});

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		path => $self->path,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;