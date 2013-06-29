package M3MTA::Server::Models::Mailbox::Local;

use Modern::Perl;
use Moose;
extends 'M3MTA::Server::Models::Mailbox';

use M3MTA::Server::Models::Mailbox::Size;
use M3MTA::Server::Models::Mailbox::Delivery;
use M3MTA::Server::Models::Mailbox::Store;

has 'username' => ( is => 'rw', isa => 'Str'  );
has 'password' => ( is => 'rw', isa => 'Str'  );
has 'relay'	   => ( is => 'rw', isa => 'Bool' );
has 'size'	   => (
	is => 'rw',
	isa => 'M3MTA::Server::Models::Mailbox::Size',
	default => sub { M3MTA::Server::Models::Mailbox::Size->new },
);
has 'delivery' => (
	is => 'rw',
	isa => 'M3MTA::Server::Models::Mailbox::Delivery',
	default => sub { M3MTA::Server::Models::Mailbox::Delivery->new },
);
has 'validity' => ( is => 'rw', isa => 'HashRef', default => sub { {} } );
has 'subscriptions' => ( is => 'rw', isa => 'HashRef', default => sub { {} } );
has 'store' => (
	is => 'rw',
	isa => 'M3MTA::Server::Models::Mailbox::Store',
	default => sub { M3MTA::Server::Models::Mailbox::Store->new },
);

#------------------------------------------------------------------------------

after 'from_json' => sub {
	my ($self, $json) = @_;

	$self->username($json->{username});
	$self->password($json->{password});
	$self->relay($json->{relay});
	$self->size(M3MTA::Server::Models::Mailbox::Size->new->from_json($json->{size}));
	$self->delivery(M3MTA::Server::Models::Mailbox::Delivery->new->from_json($json->{delivery}));
	$self->validity($json->{validity});
	$self->subscriptions($json->{subscriptions});
	$self->store(M3MTA::Server::Models::Mailbox::Store->new->from_json($json->{store}));

	return $self;
};

#------------------------------------------------------------------------------

around 'to_json' => sub {
	my ($orig, $self) = @_;

	my $json = $self->$orig();

	return {
		%$json,
		username => $self->username,
		password => $self->password,
		relay => $self->relay,
		size => $self->size->to_json,
		delivery => $self->delivery->to_json,
		validity => $self->validity,
		subscriptions => $self->subscriptions,
		store => $self->store->to_json,
	};
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;