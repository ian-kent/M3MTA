package M3MTA::Storage::Message;

=head NAME
M3MTA::Storage::Message - SMTP Message
=cut

use Modern::Perl;
use Moose;

has 'created' => ( is => 'rw' );
has 'to' 	=> ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'from'	=> ( is => 'rw' );
has 'data' 	=> ( is => 'rw' );
has 'id'	=> ( is => 'rw' );
has 'helo' 	=> ( is => 'rw' );
has 'delivery_time' => ( is => 'rw' );
has 'requeued' => ( is => 'rw', default => sub { 0 } );
has 'attempts' => ( is => 'rw', default => sub { [] } );
has 'status' => ( is => 'rw' );
has 'filters' => ( is => 'rw' ); # TODO objects

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->created($json->{created});
	$self->to($json->{to});
	$self->from($json->{from});
	$self->data($json->{data});
	$self->id($json->{id});
	$self->helo($json->{helo});
	$self->delivery_time($json->{delivery_time});
	$self->requeued($json->{requeued});
	$self->status($json->{status});
	$self->filters($json->{filters});

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	my $attempts = [];
	for my $attempt (@{$self->attempts}) {
		push $attempts, $attempt->to_json;
	}

	return {
		created => $self->created,
		to => $self->to,
		from => $self->from,
		data => $self->data,
		id => $self->id,
		helo => $self->helo,
		delivery_time => $self->delivery_time,
		requeued => $self->requeued,
		attempts => $attempts,
		status => $self->status,
		filters => $self->filters,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;