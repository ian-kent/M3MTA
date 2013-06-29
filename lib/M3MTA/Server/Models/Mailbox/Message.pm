package M3MTA::Server::Models::Mailbox::Message;

=head NAME
M3MTA::Server::Models::Mailbox::Message - Message for mailbox
=cut

use Modern::Perl;
use Moose;

use M3MTA::Server::Models::Mailbox::Message::Content;

has 'uid' => ( is => 'rw', isa => 'Int' );
has 'content' => (
	is => 'rw',
	isa => 'M3MTA::Server::Models::Mailbox::Message::Content',
	default => sub { M3MTA::Server::Models::Mailbox::Message::Content->new },
);
has 'mailbox' => (
	is => 'rw',
	isa => 'M3MTA::Server::Models::Mailbox',
);
has 'path' => ( is => 'rw', isa => 'Str' );
has 'flags' => ( is => 'rw', isa => 'ArrayRef[Str]', default => sub { [] } );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->uid($json->{uid});
	$self->content(M3MTA::Server::Models::Mailbox::Message::Content->new->from_json($json->{content}));
	$self->mailbox(M3MTA::Server::Models::Mailbox->new->from_json($json->{mailbox}));
	$self->path($json->{path});
	$self->flags($json->{flags});

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		uid => $self->uid,
		content => $self->content->to_json,
		mailbox => $self->mailbox->to_json,
		path => $self->path,
		flags => $self->flags,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;