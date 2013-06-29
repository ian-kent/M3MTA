package M3MTA::Server::Models::Envelope;

use Modern::Perl;
use Moose;

#------------------------------------------------------------------------------

has 'from' => ( is => 'rw', isa => 'Str' );
has 'to' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'data' => ( is => 'rw', isa => 'Str' );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->from($json->{from});
	$self->to($json->{to});
	$self->data($json->{data});
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		from => $self->from,
		to => $self->to,
		data => $self->data,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;