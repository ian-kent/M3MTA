package M3MTA::Storage::Mailbox;

use Modern::Perl;
use Moose;

has 'domain' => ( is => 'rw', isa => 'Str' );
has 'mailbox' => ( is => 'rw', isa => 'Str' );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->domain($json->{domain});
	$self->mailbox($json->{mailbox});

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		domain => $self->domain,
		mailbox => $self->mailbox,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;