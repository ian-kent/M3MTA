package M3MTA::Server::Models::Mailbox::Store;

use Modern::Perl;
use Moose;

use M3MTA::Server::Models::Mailbox::Folder;

has 'children' => ( is => 'rw', isa => 'HashRef[M3MTA::Server::Models::Mailbox::Folder]', default => sub { {} } );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	for my $child (keys %{$json->{children}}) {
		$self->children->{$child} = M3MTA::Server::Models::Mailbox::Folder->new->from_json($json->{children}->{$child});
	}

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	my $h = {};
	for my $child (keys %{$self->children}) {
		$h->{$child} = $self->children->{$child}->to_json;
	}

	return {
		children => $h,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;