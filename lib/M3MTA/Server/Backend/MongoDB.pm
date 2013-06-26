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
    my $host = "mongodb://" 
    		 . ($self->config->{database}->{hostname} // "localhost")
    		 . ":" 
    		 . ($self->config->{database}->{port} // 27017);    		 
    $self->client(MongoDB::MongoClient->new(host => $host));

    my $db = $self->config->{database}->{database};
    if(my $user = $self->config->{database}->{username}) {
    	if(my $pass = $self->config->{database}->{password}) {
    		$self->client->authenticate($db, $user, $pass);
    	}
	}
	
    $self->database($self->client->get_database($db));
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;