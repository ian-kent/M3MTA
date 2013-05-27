#!/usr/local/bin/perl

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime;
use MongoDB::MongoClient;
use v5.14;

use MongoNet::SMTP;
use My::User;
use My::Email;

my @domains = ('iankent.co.uk');
my @mailboxes = ('ian.kent@iankent.co.uk');
my %mailbox_map = map { $_ => 1 } @mailboxes;
my $client = MongoDB::MongoClient->new;
my $hostname = `hostname`;
chomp $hostname;

my @ports = (25); #, 587);

my $smtp = new MongoNet::SMTP(
    hostname => $hostname,
    user_send => sub {
        my ($auth, $from) = @_;
        print "User send\n";
        if($mailbox_map{$from}) {
            if(!$auth || !$auth->{success}) {
                return 0;
            }
            my $user = $client->get_database('mojosmtp')->get_collection('users')->find_one({username => $auth->{username}})->as('My::User');
            return 0 if $user->email ne $from;
        }

        return 1;
    },
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
    queued => sub {
        my ($data) = @_;

        use Data::Dumper;
        print "Queued message\n";
        print Dumper $data;

        my $email = new My::Email(client => $client);
        my $id = luniqid . "@" . $hostname;
        $email->id($id);
        $email->created(DateTime->now);
        $email->to($data->{to});
        $email->from($data->{from});
        $email->data($data->{data});
        $email->helo($data->{helo});
        eval {
            $email->save;
        };

        my @res;
        if($@) {
            @res = ("451", "$id message store failed, please retry later");
        } else {
            @res = ("250", "$id message accepted for delivery");
        }
        return wantarray ? @res : join ' ', @res;
    },
);

for my $port (@ports) {
    print "Creating server on port $port\n";

    my $server = Mojo::IOLoop->server({port => $port}, sub {
	    my ($loop, $stream, $id) = @_;
		$smtp->accept($loop, $stream, $id);
    } );
}

Mojo::IOLoop->start or die "Failed to start servers\n";
