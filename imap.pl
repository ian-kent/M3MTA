#!/usr/local/bin/perl

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime;
use MongoDB::MongoClient;
use v5.14;

use Data::Dumper;
use Config::Any;

use M3MTA::IMAP;
use My::User;
use My::Email;

# Load configuration
my $config = Config::Any->load_files({ files => ['config.json'], use_ext => 1 })->[0]->{'config.json'}->{imap};
my @ports = @{$config->{ports}};

# Get connection to database
my $client = MongoDB::MongoClient->new;
my $db = $client->get_database('mojosmtp');
my $mailboxes = $db->get_collection('mailboxes');

my $imap = new M3MTA::IMAP(
    db => $db,
    user_auth => sub {
        my ($username, $password) = @_;
        print "User auth for username [$username] with password [$password]\n";

        my $user = $mailboxes->find_one({username => $username, password => $password});
        print "Error: $@\n" if $@;

        return $user;
    },
);

for my $port (@ports) {
    print "Creating server on port $port\n";

    my $server = Mojo::IOLoop->server({port => $port}, sub {
	    my ($loop, $stream, $id) = @_;
		$imap->accept($loop, $stream, $id);
    } );
}

Mojo::IOLoop->start or die "Failed to start servers\n";
