#!/usr/local/bin/perl

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime;
use MongoDB::MongoClient;
use v5.14;

use Data::Dumper;
use Config::Any;

use M3MTA::SMTP;
use My::User;
use My::Email;

# Load configuration
my $config = Config::Any->load_files({ files => ['config.json'], use_ext => 1 })->[0]->{'config.json'};

# Get connection to database
my $client = MongoDB::MongoClient->new;
my $db = $client->get_database('mojosmtp');
my $queue = $db->get_collection('queue'); # incoming queue from smtp daemon
my $mailboxes = $db->get_collection('mailboxes'); # user mailboxes/aliases
my $domains = $db->get_collection('domains'); # domains this system recognises
my $store = $db->get_collection('store'); # message store (i.e. GridFS behind real mailboxes)

while (1) {
    # Look for queued emails
    my $queued = $queue->find;

    while(my $email = $queued->next) {
        print "Processing message '" . $email->{id} . "' from '" . $email->{from} . "'\n";

        for my $to (@{$email->{to}}) {
            my ($user, $domain) = split /@/, $to;
            print " - Recipient '$user'\@'$domain'\n";

            # Check if we have a real mailbox entry
            my $mailbox = $mailboxes->find_one({ mailbox => $user, domain => $domain });
            # ... or a catch-all
            $mailbox ||= $mailboxes->find_one({ mailbox => '*', domain => $domain });
            if($mailbox) {
                print " - Local mailbox found, attempting GridFS delivery\n";

                # Turn the email into an object
                my $obj = parse($email->{data});

                # Make the message for the store
                my $msg = {
                    uid => $mailbox->{delivery}->{uid},
                    message => $obj,
                    mailbox => { domain => $domain, user => $user },
                    path => 'INBOX',
                    flags => ['Unseen'],
                };

                # Update mailbox next UID
                $mailboxes->update({mailbox => $user, domain => $domain}, {
                    '$inc' => {
                        'delivery.uid' => 1,
                        'store.unseen' => 1,
                        'store.children.INBOX.unseen' => 1 
                    } 
                } );

                # Add received by header
                my $recd_by = "from " . $email->{helo} . " by " . $config->{hostname} . " (SomeMail)\nid " . $email->{id} . ";";
                $msg->{message}->{size} += (length($recd_by) + 2);
                if($obj->{headers}->{Received}) {
                    $obj->{headers}->{Received} = [$obj->{headers}->{Received}] if ref $obj->{headers}->{Received} !~ /ARRAY/;
                    push $obj->{headers}->{Received}, $recd_by;
                } else {
                    $obj->{headers}->{Received} = $recd_by;
                }

                # Save it to the database
                my $oid = $store->insert($msg);
                print " | message stored with ObjectID [$oid], UID [" . $msg->{uid} . "] for User [$user], Domain [$domain]\n";

                $queue->remove($email);

                next;
            }

            # Check if we have a domain entry for local delivery (means user doesn't exist)
            my $domain = $domains->find_one({ domain => $domain });
            if($domain && $domain->{delivery} eq 'local') {
                print " - Domain entry found for local delivery but no user or catch-all exists\n";
                next;
            }

            print " - No domain or mailbox entry found, attempting remote delivery\n";
        }
    }

    #last;
    sleep 5;
}

sub parse {
    my ($data) = @_;

    my $size = 0;

    my ($headers, $body) = split /\r\n\r\n/m, $data, 2;

    my @hdrs = split /\r\n/m, $headers;
    my %h = ();
    for my $hdr (@hdrs) {
        my ($key, $value) = split /:\s/, $hdr, 2;
        if($h{$key}) {
            $h{$key} = [$h{$key}] if ref $h{$key} !~ /ARRAY/;
            push $h{$key}, $value;
        } else {
            $h{$key} = $value;
        }
    }

    return {
        headers => \%h,
        body => $body,
        size => length($data) + (scalar @hdrs) + 2, # weird hack, length seems to count \r\n as 1?
    };
}