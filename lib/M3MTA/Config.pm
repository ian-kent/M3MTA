package M3MTA::Config;

use Modern::Perl;
use Moose;

use Data::Dumper;
use JSON;
use Hash::Merge;

use M3MTA::Log;

use MongoDB::MongoClient;

has 'type'	   => ( is => 'rw', isa => 'Str', default => sub { "file" } );
has 'filename' => ( is => 'rw', isa => 'Str' );

has 'config'   => ( is => 'rw', isa => 'HashRef' );

our $existing = undef;

sub BUILD {
	my ($self) = @_;
	$existing = $self;
}

sub existing {
	my ($package) = @_;
	return $existing;
}

sub load {
	my ($self) = @_;

	if($self->filename) {
		M3MTA::Log->debug("Loading configuration file: " . $self->filename);

		# First load the JSON file
		my $json_text = do {
		    my $r = open(my $json_fh, "<:encoding(UTF-8)", $self->filename);
		    if(!$r) {
		    	M3MTA::Log->fatal("Can't open file '" . $self->filename . "': $!");
		    	die;
		    }
		    local $/;
		    <$json_fh>
		};
		$self->config(JSON->new->decode($json_text));

		M3MTA::Log->debug("Got configuration (enable TRACE to see config)");
		M3MTA::Log->debug(Dumper $self->config);

		# Check if we've actually got a different config type
		if($self->config->{type}) {
			$self->type($self->config->{type});
			M3MTA::Log->debug("Configuration type set to: " . $self->type);
		}
	}

	if($self->type eq 'database') {
		M3MTA::Log->debug("Loading configuration from database");

		# Get the config from config :)
		my $db_config = $self->config->{database};

	    my $host = "mongodb://" 
	    		 . ($db_config->{hostname} // "localhost")
	    		 . ":" 
	    		 . ($db_config->{port} // 27017);    		 
	    my $client = MongoDB::MongoClient->new(host => $host);
	    M3MTA::Log->debug("Connected to host: " . $host);

	    my $db = $db_config->{database};
	    if(my $user = $db_config->{username}) {
	    	if(my $pass = $db_config->{password}) {
	    		$client->authenticate($db, $user, $pass);
	    		M3MTA::Log->debug("Authenticated with database [$db], username [$user]");
	    	}
		}
		
		M3MTA::Log->debug("Getting database $db");
	    my $database = $client->get_database($db);
	    M3MTA::Log->debug("Getting collection " . $db_config->{collection});
	    my $collection = $database->get_collection($db_config->{collection});
	    M3MTA::Log->debug("Looking for configuration with query (enable TRACE to see query)");
	    M3MTA::Log->trace(Dumper $db_config->{query});
	    my $config = $collection->find_one($db_config->{query});
	    M3MTA::Log->debug("Loaded configuration from database (enable TRACE to see config)");
	    M3MTA::Log->trace(Dumper $config);

	    my $merge = Hash::Merge->new('RIGHT_PRECEDENT');
	    my $new_config = $merge->merge($config, $self->config);
	    $self->config($new_config);
	}

	M3MTA::Log->debug("Configuration loaded (enable TRACE to see config)");
	M3MTA::Log->trace(Dumper $self->config);
	return $self->config;
}

__PACKAGE__->meta->make_immutable;