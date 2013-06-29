package M3MTA::Server::Models::Mailbox::Alias;

use Modern::Perl;
use Moose;
extends 'M3MTA::Server::Models::Mailbox';

has 'destination' => ( is => 'rw', isa => 'Str' );

#------------------------------------------------------------------------------

after 'from_json' => sub {
	my ($self, $json) = @_;

	$self->destination($json->{destination});

	return $self;
};

#------------------------------------------------------------------------------

around 'to_json' => sub {
	my ($orig, $self) = @_;

	my $json = $self->$orig();

	return {
		%$json,
		destination => $self->destination,
	};
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;