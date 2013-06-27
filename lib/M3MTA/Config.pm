package M3MTA::Config;

use Modern::Perl;
use Moose;

use Config::Any;
use Hash::Merge;

use MongoDB::MongoClient;

has 'type'	   => ( is => 'rw', isa => 'Str', default => sub { "file" } );
has 'filename' => ( is => 'rw', isa => 'Str' );

has 'config'   => ( is => 'rw', isa => 'HashRef' );

sub load {
	my ($self) = @_;

	if($self->filename) {
		# First load the JSON file
		$self->config(Config::Any->load_files(
			{ files => [$self->filename], use_ext => 1 }
		)->[0]->{$self->filename});

		# Check if we've actually got a different config type
		if($self->config->{type}) {
			$self->type($self->config->{type});
		}
	}

	if($self->type eq 'database') {
		# Get the config from config :)
		my $db_config = $self->config->{database};

	    my $host = "mongodb://" 
	    		 . ($db_config->{hostname} // "localhost")
	    		 . ":" 
	    		 . ($db_config->{port} // 27017);    		 
	    my $client = MongoDB::MongoClient->new(host => $host);

	    my $db = $db_config->{database};
	    if(my $user = $db_config->{username}) {
	    	if(my $pass = $db_config->{password}) {
	    		$client->authenticate($db, $user, $pass);
	    	}
		}
		
	    my $database = $client->get_database($db);
	    my $collection = $database->get_collection($db_config->{collection});
	    my $config = $collection->find_one($db_config->{query});

	    my $merge = Hash::Merge->new('RIGHT_PRECEDENT');
	    my $new_config = $merge->merge($config, $self->config);
	    $self->config($new_config);

	    use Data::Dumper;
	    print Dumper "New configuration is:\n" . (Dumper $new_config) . "\n\n";

	    return $self->config;
	}
}

__PACKAGE__->meta->make_immutable;