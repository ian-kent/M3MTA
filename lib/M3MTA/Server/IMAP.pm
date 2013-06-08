package M3MTA::Server::IMAP;

=head NAME
M3MTA::Server::SMTP - Mojo::IOLoop based SMTP server
=cut

use MIME::Base64 qw/ decode_base64 encode_base64 /;
use MongoDB::MongoClient;
use M3MTA::Server::IMAP::Session;
use Mouse;
extends 'M3MTA::Server::Base';

use M3MTA::Server::IMAP::State::NotAuthenticated;
use M3MTA::Server::IMAP::State::Authenticated;
use M3MTA::Server::IMAP::State::Selected;
use M3MTA::Server::IMAP::State::Any;

#------------------------------------------------------------------------------

# Database
has 'client'    => ( is => 'rw' );
has 'database'  => ( is => 'rw' );

# Collections
has 'mailboxes' => ( is => 'rw' );
has 'store'     => ( is => 'rw' );

# Callbacks
has 'user_auth' => ( is => 'rw' );

# RFC implementations
has 'states'   => ( is => 'rw', default => sub { {} } );
has 'default_state' => ( is => 'rw', default => sub { 'NotAuthenticated' } );

#------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

    # Setup database
    $self->client(MongoDB::MongoClient->new);
    $self->database($self->client->get_database($self->config->{database}->{database}));

    # Get collections
    $self->mailboxes($self->database->get_collection($self->config->{database}->{mailboxes}->{collection}));
    $self->store($self->database->get_collection($self->config->{database}->{store}->{collection}));

    # Initialise states
    M3MTA::Server::IMAP::State::NotAuthenticated->new->register($self);
    M3MTA::Server::IMAP::State::Authenticated->new->register($self);
    M3MTA::Server::IMAP::State::Selected->new->register($self);
    M3MTA::Server::IMAP::State::Any->new->register($self);
}
#------------------------------------------------------------------------------

# Handles new connections from M3MTA::Server::Base
sub accept {
    my ($self, $server, $loop, $stream, $id) = @_;

    $self->log("Session accepted with id %s", $id);

    my $session = new M3MTA::Server::IMAP::Session(
        imap => $self, 
        stream => $stream,
        loop => $loop,
        id => $id,
        server => $loop->{acceptors}{$server},
        state => $self->default_state,
    );

    $session->begin;

    return;
}

#------------------------------------------------------------------------------

sub get_state {
    my ($self, $state) = @_;
    return $self->states->{$state};
}

#------------------------------------------------------------------------------

sub register_state {
    my ($self, $state, $callback) = @_;
    $self->log("Registering callback for state '%s'", $state);
    $self->states->{$state} = $callback;
}

#------------------------------------------------------------------------------

sub _user_auth {
    my ($self, $username, $password) = @_;
    print "User auth for username [$username] with password [$password]\n";

    my $user = $self->mailboxes->find_one({username => $username, password => $password});
    print "Error: $@\n" if $@;

    return $user;
}

#------------------------------------------------------------------------------

1;
