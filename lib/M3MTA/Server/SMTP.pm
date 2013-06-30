package M3MTA::Server::SMTP;

=head NAME
M3MTA::Server::SMTP - Mojo::IOLoop based SMTP server
=cut

use Modern::Perl;
use Moose;
extends 'M3MTA::Server::Base';

use M3MTA::Server::SMTP::Session;

use M3MTA::Server::SMTP::RFC5321; # Basic/Extended SMTP
use M3MTA::Server::SMTP::RFC1870; # SIZE extension
use M3MTA::Server::SMTP::RFC2487; # STARTTLS extension
use M3MTA::Server::SMTP::RFC2920; # PIPELINING extension
use M3MTA::Server::SMTP::RFC4954; # AUTH extension

# TODO
# - VRFY
# - ETRN
# - EXPN
# - DSN
# - 8BITMIME
# - ENHANCEDSTATUSCODES

#------------------------------------------------------------------------------

our %ReplyCodes = ();
has 'helo' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );

#------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

    # Initialise RFCs
    M3MTA::Server::SMTP::RFC5321->new->register($self); # Basic/Extended SMTP
    M3MTA::Server::SMTP::RFC1870->new->register($self); # SIZE extension
    M3MTA::Server::SMTP::RFC2487->new->register($self); # STARTTLS extension
    M3MTA::Server::SMTP::RFC2920->new->register($self); # PIPELINING extension
    M3MTA::Server::SMTP::RFC4954->new->register($self); # AUTH extension
}

#------------------------------------------------------------------------------

# Handles new connections from M3MTA::Server::Base
sub accept {
    my ($self, $server, $loop, $stream, $id) = @_;

    M3MTA::Log->debug("Session accepted with id %s", $id);

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
            M3MTA::Log->debug("Registered replycode %s => %s", $n, $name->{$n});
            $M3MTA::Server::SMTP::ReplyCodes{$n} = $name->{$n};
        }
    } else {
        M3MTA::Log->debug("Registered replycode %s => %s", $name, $code);
        $M3MTA::Server::SMTP::ReplyCodes{$name} = $code;
    }
}

#------------------------------------------------------------------------------

# Registers an SMTP HELO response
sub register_helo {
    my ($self, $callback) = @_;
    
    M3MTA::Log->debug("Registered callback for helo");

    push $self->helo, $callback;
}

#------------------------------------------------------------------------------

sub get_user {
    my ($self, $username, $password) = @_;

    return $self->backend->get_user($username, $password);
}

#------------------------------------------------------------------------------

sub get_mailbox {
    my ($self, $mailbox, $domain) = @_;

    return $self->backend->get_mailbox($mailbox, $domain);
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