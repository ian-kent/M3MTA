package M3MTA::Storage::Message;

=head NAME
M3MTA::Storage::Message - SMTP Message
=cut

use Modern::Perl;
use Moose;

has '_id' => ( is => 'rw' );

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
has 'filters' => ( is => 'rw', default => sub { {} } ); # TODO objects

#------------------------------------------------------------------------------

sub add_recipient {
	my ($self, $to) = @_;

	return push $self->to, M3MTA::Transport::Path->new->from_text($to);
}

#------------------------------------------------------------------------------

sub remove_recipient {
	my ($self, $to) = @_;

	my @recipients = grep { $_ if "$_" ne "$to" } @{$self->to};
	return $self->to(\@recipients);
}

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->_id($json->{_id});
	$self->created($json->{created});
	for my $to (@{$json->{to}}) {
		push $self->to, M3MTA::Transport::Path->new->from_json($to);
	}
	$self->from(M3MTA::Transport::Path->new->from_json($json->{from}));
	$self->data($json->{data});
	$self->id($json->{id});
	$self->helo($json->{helo});
	$self->delivery_time($json->{delivery_time});
	$self->requeued($json->{requeued});
	$self->status($json->{status});
	$self->filters($json->{filters} // {});
	if($json->{attempts}) {
		for my $a (@{$json->{attempts}}) {
			push $self->attempts, M3MTA::Storage::Message::Attempt->new->from_json($a);
		}
	}

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	my $attempts = [];
	for my $attempt (@{$self->attempts}) {
		push $attempts, $attempt->to_json;
	}

	my $to = [];
	for my $r (@{$self->to}) {
		push $to, $r->to_json;
	}

	return {
		created => $self->created,
		to => $to,
		from => $self->from->to_json,
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