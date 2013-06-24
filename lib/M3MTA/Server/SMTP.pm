package M3MTA::Server::SMTP;

=head NAME
M3MTA::Server::SMTP - Mojo::IOLoop based SMTP server
=cut

use Modern::Perl;
use Moose;
extends 'M3MTA::Server::Base';

use M3MTA::Server::SMTP::Session;
use M3MTA::Server::SMTP::RFC0821;
use M3MTA::Server::SMTP::RFC1869;
use M3MTA::Server::SMTP::RFC2821;
use M3MTA::Server::SMTP::RFC2554;
use M3MTA::Server::SMTP::RFC2487;

#------------------------------------------------------------------------------

our %ReplyCodes = ();
has 'helo' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

    # Initialise RFCs
    M3MTA::Server::SMTP::RFC0821->new->register($self); # Basic SMTP
    M3MTA::Server::SMTP::RFC1869->new->register($self); # Extension format
    M3MTA::Server::SMTP::RFC2487->new->register($self); # STARTTLS
    M3MTA::Server::SMTP::RFC2554->new->register($self); # AUTH
    M3MTA::Server::SMTP::RFC2821->new->register($self); # Extended SMTP    
}

#------------------------------------------------------------------------------

# Handles new connections from M3MTA::Server::Base
sub accept {
    my ($self, $server, $loop, $stream, $id) = @_;

    $self->log("Session accepted with id %s", $id);

    M3MTA::Server::SMTP::Session->new(
        smtp => $self, 
        stream => $stream,
        loop => $loop,
        id => $id,
        server => $loop->{acceptors}{$server},
    )->begin;

    return;
}

#------------------------------------------------------------------------------

# Registers an SMTP replycode
sub register_replycode {
    my ($self, $name, $code) = @_;

    if(ref($name) =~ /HASH/) {
        for my $n (keys %$name) {
            $M3MTA::Server::SMTP::ReplyCodes{$n} = $name->{$n};
        }
    } else {
        $M3MTA::Server::SMTP::ReplyCodes{$name} = $code;
    }
}

#------------------------------------------------------------------------------

# Registers an SMTP HELO response
sub register_helo {
    my ($self, $callback) = @_;
    
    $self->helo([]) if !$self->helo;    
    push $self->helo, $callback;
}

#------------------------------------------------------------------------------

sub get_user {
    my ($self, $username, $password) = @_;

    return $self->backend->get_user($username, $password);
}

#------------------------------------------------------------------------------    

sub can_user_send {
    my ($self, $session, $from) = @_;

    return $self->backend->can_user_send($session, $from);
}

#------------------------------------------------------------------------------

sub can_accept_mail {
    my ($self, $session, $to) = @_;

    return $self->backend->can_accept_mail($session, $to);
}

#------------------------------------------------------------------------------

sub queue_message {
    my ($self, $email) = @_;

    return $self->backend->queue_message($email);
}


#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;