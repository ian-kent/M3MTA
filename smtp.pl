#!/usr/local/bin/perl

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime;
use MongoDB::MongoClient;
use v5.14;

use Data::Dumper;
use Config::Any;

use MongoNet::SMTP;
use My::User;
use My::Email;

# Load configuration
my $config = Config::Any->load_files({ files => ['config.json'], use_ext => 1 })->[0]->{'config.json'}->{smtp};
my $hostname = $config->{hostname};
my @ports = @{$config->{ports}};

# Get connection to database
my $client = MongoDB::MongoClient->new;
my $db = $client->get_database('mojosmtp');
my $queue = $db->get_collection('queue');

my $smtp = new MongoNet::SMTP(
    hostname => $hostname,
    user_send => sub {
        my ($auth, $from) = @_;

        my ($user, $domain) = split /@/, $from;
        print "Checking if user is permitted to send from '$user'\@'$domain'\n";
        print Dumper $auth;

        # Get the mailbox
        my $mailbox = $db->get_collection('mailboxes')->find_one({ mailbox => $user, domain => $domain });
        print Dumper $mailbox;

        if($mailbox && (!$auth || !$auth->{success} || $auth->{username} ne $mailbox->{username})) {
            # Its a local mailbox, and either the user isn't logged in, or isn't logged in as the right user
            return 0;
        }

        # The 'from' address isn't local, or the user is correctly authenticated
        return 1;
    },
    user_auth => sub {
        my ($username, $password) = @_;

        print "Trying to load mailbox for '$username' with password '$password'\n";
        my $mailbox = $db->get_collection('mailboxes')->find_one({ username => $username, password => $password });
        print Dumper $mailbox;

        return $mailbox;
    },
    mail_accept => sub {
        my ($auth, $to) = @_;

        my ($user, $domain) = split /@/, $to;
        print "Checking if server will accept messages addressed to '$user'\@'$domain'\n";
        print ("- User:\n", Dumper $auth) if $auth;

        # Check if the server is acting as an open relay
        if( $config->{relay}->{anon} ) {
            print "- Server is acting as open relay\n";
            return 1;
        }

        # Check if server allows all authenticated users to relay
        if( $auth && $config->{relay}->{auth} ) {
            print "- User is authenticated and all authenticated users can relay\n";
            return 1;
        }

        # Check if this user can open relay
        if( $auth && $auth->{user}->{relay} ) {
            print "- User has remote relay rights\n";
            return 1;
        }

        # Check for local delivery mailboxes (may be an alias, but thats dealt with after queueing)
        my $mailbox = $db->get_collection('mailboxes')->find_one({ mailbox => $user, domain => $domain });
        if( $mailbox ) {
            print "- Mailbox exists locally:\n";
            print Dumper $mailbox;
            return 1;
        }

        # Check if we have a catch-all mailbox (also may be an alias)
        my $catch = $db->get_collection('mailboxes')->find_one({ mailbox => '*', domain => $domain });
        if( $catch ) {
            print "- Recipient caught by domain catch-all\n";
            return 1;
        }

        # Finally check if we have a relay domain
        my $domain = $db->get_collection('domains')->find_one({ domain => $domain, delivery => 'relay' });
        if( $domain ) {
            print "- Domain exists as 'relay'\n";
            return 1;
        }

        # None of the above
        print "x Mail not accepted for delivery\n";
        return 0;
    },
    queued => sub {
        my ($data) = @_;

        my $email = new My::Email(col => $queue);
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
            print "Queue message failed for '$id'\n";
        } else {
            @res = ("250", "$id message accepted for delivery");
            print "Message queued for '$id'\n";
        }
        print Dumper $email;
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
