package M3MTA::Server::IMAP;

=head NAME
M3MTA::Server::SMTP - Mojo::IOLoop based SMTP server
=cut

use MIME::Base64 qw/ decode_base64 encode_base64 /;
use MongoDB::MongoClient;
use M3MTA::Server::IMAP::Session;
use Mouse;
extends 'M3MTA::Server::Base';

#------------------------------------------------------------------------------

# Database
has 'client'    => ( is => 'rw' );
has 'database'  => ( is => 'rw' );

# Collections
has 'mailboxes' => ( is => 'rw' );
has 'store'     => ( is => 'rw' );

# Callbacks
has 'user_auth' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

    # Setup database
    $self->client(MongoDB::MongoClient->new);
    $self->database($self->client->get_database($self->config->{database}->{database}));

    # Get collections
    $self->mailboxes($self->database->get_collection($self->config->{database}->{mailboxes}->{collection}));
    $self->store($self->database->get_collection($self->config->{database}->{store}->{collection}));

    # Initialise RFCs
    #M3MTA::Server::SMTP::RFC2821->new->register($self); # Basic SMTP
    #M3MTA::Server::SMTP::RFC2554->new->register($self); # AUTH
    #M3MTA::Server::SMTP::RFC2487->new->register($self); # STARTTLS
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
    );

    $session->begin;

    return;
}



#------------------------------------------------------------------------------

1;
