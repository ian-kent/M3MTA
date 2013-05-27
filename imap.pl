#!/usr/local/bin/perl

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime;
use MongoDB::MongoClient;
use v5.14;

use MongoNet::IMAP;
use My::User;
use My::Email;

my @domains = ('iankent.co.uk');
my @mailboxes = ('ian.kent@iankent.co.uk');
my %mailbox_map = map { $_ => 1 } @mailboxes;
my $client = MongoDB::MongoClient->new;
my $hostname = `hostname`;
chomp $hostname;

my @ports = (143); #, 993);

my $imap = new MongoNet::IMAP(
    user_auth => sub {
        my ($username, $password) = @_;
        print "User auth\n";

        my $result = eval {
            my $user = $client->get_database('mojosmtp')->get_collection('users')->find_one({username => $username, password => $password});
            return 0 if !$user;
            $user = $user->as('My::User');
            if ($user && ($user->username eq $username) && ($user->password eq $password)) {
                return 1;
            }
            return 0;
        };

        print "Error: $@\n" if $@;
        return $result;
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
