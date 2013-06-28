package M3MTA::Server::Backend::MongoDB;

use Modern::Perl;
use Moose;

use MongoDB::MongoClient;
use M3MTA::Server::Backend::MongoDB::Util;
use M3MTA::Log;

# Database
has 'client'    => ( is => 'rw' );
has 'database'  => ( is => 'rw' );
has 'util'      => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

    $self->util(M3MTA::Server::Backend::MongoDB::Util->new(backend => $self));
    $self->init_db;
}

#------------------------------------------------------------------------------

sub init_db {
    my ($self) = @_;

    my $host = "mongodb://" 
             . ($self->config->{backend}->{database}->{hostname} // "localhost")
             . ":" 
             . ($self->config->{backend}->{database}->{port} // 27017);   

    M3MTA::Log->debug("Connecting to host: " . $host);
    $self->client(MongoDB::MongoClient->new(host => $host));
    M3MTA::Log->debug("Connection successful");

    my $db = $self->config->{backend}->{database}->{database};
    if(my $user = $self->config->{backend}->{database}->{username}) {
        if(my $pass = $self->config->{backend}->{database}->{password}) {
            M3MTA::Log->debug("Authenticating against database [$db] with user [$user]");
            my $result = $self->client->authenticate($db, $user, $pass);
            if($result->{ok}) {
                M3MTA::Log->debug("Authentication successful");
            } else {
                M3MTA::Log->fatal("Authentication failed");
                die;
            }            
        } else {
            M3MTA::Log->warn("Username provided but password missing, authentication not attempted");
        }
    }
    
    M3MTA::Log->debug("Getting database: $db");
    $self->database($self->client->get_database($db));
    
    M3MTA::Log->debug("Database connection completed");
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;