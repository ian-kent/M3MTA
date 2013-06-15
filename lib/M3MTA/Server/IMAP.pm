package M3MTA::Server::IMAP;

=head NAME
M3MTA::Server::SMTP - Mojo::IOLoop based SMTP server
=cut

use Moose;
extends 'M3MTA::Server::Base';

use M3MTA::Server::IMAP::Session;
use M3MTA::Server::IMAP::State::NotAuthenticated;
use M3MTA::Server::IMAP::State::Authenticated;
use M3MTA::Server::IMAP::State::Selected;
use M3MTA::Server::IMAP::State::Any;

#------------------------------------------------------------------------------

has 'states'   => ( is => 'rw', default => sub { {} } );
has 'default_state' => ( is => 'rw', default => sub { 'NotAuthenticated' } );

#------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

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

    M3MTA::Server::IMAP::Session->new(
        imap => $self, 
        stream => $stream,
        loop => $loop,
        id => $id,
        server => $loop->{acceptors}{$server},
        state => $self->default_state,
    )->begin;

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

sub get_user {
    my ($self, $username, $password) = @_;
    
    return $self->backend->get_user($username, $password);
}

#------------------------------------------------------------------------------

sub append_message {
    my ($self, $session, $mailbox, $flags, $content) = @_;

    return $self->backend->append_message($session, $mailbox, $flags, $content);
}

sub fetch_messages {
    my ($self, $session, $query) = @_;

    return $self->backend->fetch_messages($session, $query);
}

sub create_folder {
    my ($self, $session, $path) = @_;

    return $self->backend->create_folder($session, $path);
}

sub delete_folder {
    my ($self, $session, $path) = @_;

    return $self->backend->delete_folder($session, $path);
}

sub rename_folder {
    my ($self, $session, $path, $to) = @_;

    return $self->backend->rename_folder($session, $path, $to);
}

sub select_folder {
    my ($self, $session, $path, $mode) = @_;

    return $self->backend->select_folder($session, $path, $mode);
}

sub subcribe_folder {
    my ($self, $session, $path) = @_;

    return $self->backend->subscribe_folder($session, $path);
}

sub unsubcribe_folder {
    my ($self, $session, $path) = @_;

    return $self->backend->unsubscribe_folder($session, $path);
}

sub fetch_folders {
    my ($self, $session, $ref, $filter, $subscribed) = @_;

    return $self->backend->fetch_folders($session, $ref, $filter, $subscribed);
}

sub uid_store {
    my ($self, $session, $from, $to, $params) = @_;

    return $self->backend->uid_store($session, $from, $to, $params);
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;