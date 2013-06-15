package M3MTA::Server::Backend::MongoDB;

use Modern::Perl;
use Moose;

use MongoDB::MongoClient;

# Database
has 'client'    => ( is => 'rw' );
has 'database'  => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

    # TODO authentication
    $self->client(MongoDB::MongoClient->new);
    $self->database($self->client->get_database($self->config->{database}->{database}));
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;