package M3MTA::Transport::Envelope;

use Modern::Perl;
use Moose;

#------------------------------------------------------------------------------

has 'from' => ( is => 'rw', isa => 'M3MTA::Transport::Path' );
has 'to' => ( is => 'rw', isa => 'ArrayRef[M3MTA::Transport::Path]', default => sub { [] } );
has 'data' => ( is => 'rw', isa => 'Str' );
has 'helo' => ( is => 'rw', isa => 'Str' );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->from($json->{from});
	$self->to($json->{to});
	$self->data($json->{data});
	$self->helo($json->{helo});
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	my @to;
	for my $t (@{$self->to}) {
		push @to, $t->to_json;
	}
	return {
		from => $self->from->to_json,
		to => \@to,
		data => $self->data,
		helo => $self->helo,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;