package M3MTA::MDA;

use Moose;
use Modern::Perl;

use Mojo::IOLoop;
use Data::Uniqid qw/ luniqid /;
use DateTime;
use MongoDB::MongoClient;
use v5.14;

use Data::Dumper;
use Net::DNS;
use Config::Any;
use IO::Socket::INET;

use My::User;
use My::Email;

has 'config' => ( is => 'rw' );

has 'client' => ( is => 'rw' );
has 'db' => ( is => 'rw' );
has 'queue' => ( is => 'rw' );
has 'mailboxes' => ( is => 'rw' );
has 'domains' => ( is => 'rw' );
has 'store' => ( is => 'rw' );

sub BUILD {
	my ($self) = @_;

	print "Getting database stuff\n";

	$self->client(MongoDB::MongoClient->new);
	$self->db($self->client->get_database('m3mta'));

	$self->queue($self->db->get_collection('queue')); # incoming queue from smtp daemon
	$self->mailboxes($self->db->get_collection('mailboxes')); # user mailboxes/aliases
	$self->domains($self->db->get_collection('domains')); # domains this system recognises
	$self->store($self->db->get_collection('store')); # message store (i.e. GridFS behind real mailboxes)
}

sub block {
	my ($self) = @_;

	while (1) {
		print "In loop\n";
        # Look for queued emails
        my $queued = $self->queue->find;

        while(my $email = $queued->next) {
            print "Processing message '" . $email->{id} . "' from '" . $email->{from} . "'\n";

            # Turn the email into an object
            my $obj = $self->parse($email->{data});
            # Add received by header
            my $recd_by = "from " . $email->{helo} . " by " . $self->config->{hostname} . " (M3MTA) id " . $email->{id} . ";";
            if($obj->{headers}->{Received}) {
                $obj->{headers}->{Received} = [$obj->{headers}->{Received}] if ref $obj->{headers}->{Received} !~ /ARRAY/;
                push $obj->{headers}->{Received}, $recd_by;
            } else {
                $obj->{headers}->{Received} = $recd_by;
            }

            for my $to (@{$email->{to}}) {
                my ($user, $domain) = split /@/, $to;
                print " - Recipient '$user'\@'$domain'\n";

                # Check if we have a real mailbox entry
                my $mailbox = $self->mailboxes->find_one({ mailbox => $user, domain => $domain });
                # ... or a catch-all
                $mailbox ||= $self->mailboxes->find_one({ mailbox => '*', domain => $domain });
                if($mailbox) {
                    print " - Local mailbox found, attempting GridFS delivery\n";

                    my $path = $mailbox->{delivery}->{path} // 'INBOX';

                    # Make the message for the store
                    my $msg = {
                        uid => $mailbox->{store}->{children}->{$path}->{nextuid},
                        message => $obj,
                        mailbox => { domain => $domain, user => $user },
                        path => $path,
                        flags => ['\\Unseen', '\\Recent'],
                    };

                    # Update mailbox next UID
                    $self->mailboxes->update({mailbox => $user, domain => $domain}, {
                        '$inc' => {
                            "store.children.$path.nextuid" => 1,
                            "store.children.$path.unseen" => 1,
                            "store.children.$path.recent" => 1 
                        } 
                    } );

                    # Save it to the database
                    my $oid = $self->store->insert($msg);
                    print " | message stored with ObjectID [$oid], UID [" . $msg->{uid} . "] for User [$user], Domain [$domain]\n";

                    $self->queue->remove($email);

                    next;
                }

                # Check if we have a domain entry for local delivery (means user doesn't exist)
                my $domain2 = $self->domains->find_one({ domain => $domain });
                if($domain2 && $domain2->{delivery} eq 'local') {
                    print " - Domain entry found for local delivery but no user or catch-all exists\n";
                    # TODO postmaster etc?
                    $self->queue->remove($email);
                    next;
                }

                # We wont bother checking for relay settings, SMTP delivery should have done that already
                # So, anything which doesn't get caught above, we'll relay here
                print " - No domain or mailbox entry found, attempting remote delivery\n";
                $self->send_smtp($obj, $to);
                $self->queue->remove($email);
            }
        }

        #last;
        sleep 5;
    }
}

sub parse {
    my ($self, $data) = @_;

    my $size = 0;

    # Extract headers and body
    my ($headers, $body) = split /\r\n\r\n/m, $data, 2;

    # Collapse multiline headers
    $headers =~ s/\r\n([\s\t])/$1/gm;

    my @hdrs = split /\r\n/m, $headers;
    my %h = ();
    for my $hdr (@hdrs) {
        #print "Processing header $hdr\n";
        my ($key, $value) = split /:\s/, $hdr, 2;
        #print "  - got key[$key] value[$value]\n";
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

sub send_smtp {
    my ($self, $message, $to) = @_;

    use Data::Dumper;

    print "RELAY: Relaying message to [$to]:\n";
    print Dumper $message->{headers};

    my ($user, $domain) = $to =~ /(.*)@(.*)/;

    # DNS lookup
    my $dns = new Net::DNS::Resolver;
    my $mx = $dns->query( $domain, 'MX' );

    my %hosts;

    for my $result ($mx->answer) {
        print Dumper $result;

        my $host = '';
        $host = join '.', @{$result->{exchange}->{label}} if $result->{exchange}->{label};
        my $origin = $result->{exchange}->{origin};
        while($origin) {
            $host .= '.' . (join '.', @{$origin->{label}}) if $origin->{label};
            $origin = $origin->{origin};
        }

        $hosts{$host} = $result->{preference};
    }

    print Dumper \%hosts;
    my @ordered;
    for my $key ( sort { $hosts{$a} cmp $hosts{$b} } keys %hosts ) {
        push @ordered, $key;
    }

    print Dumper \@ordered;

    my $success = 0;
    for my $host (@ordered) {
        print "Attempting delivery to host [$host]\n";

        my $socket = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => 25,
            Proto => 'tcp'
        ) or print "Error creating socket: $@\n";
        my $state = 'connect';
        while (my $data = <$socket>) {
            my ($cmd, $wait, $arg) = $data =~ /(\d+)(-|\s)(.*)/;
            $wait = '' if $wait eq ' ';

            print "RECD: data[$data], cmd[$cmd], wait[$wait], arg[$arg]\n";
            if($wait) {
                print "Waiting for next line\n";
            } elsif ($state eq 'connect') {
                # TODO hostname
                print "SENT: EHLO gateway.dc4\n";
                print $socket "EHLO gateway.dc4\r\n";
                $state = 'ehlo';
            } elsif ($state eq 'ehlo') {
                my ($name, $from) = $message->{headers}->{From} =~ /(.*)?<(.*)>/;
                #my $from = $message->{headers}->{From};
                print "SENT: MAIL FROM:<$from>\n";
                print $socket "MAIL FROM:<$from>\r\n";
                $state = 'mail';
            } elsif ($state eq 'mail') {
                print "SENT: RCPT TO:<$to>\n";
                print $socket "RCPT TO:<$to>\r\n";
                $state = 'rcpt';
            } elsif ($state eq 'rcpt') {
                print "SENT: DATA\n";
                print $socket "DATA\r\n";
                $state = 'data';
            } elsif ($state eq 'data') {
                for my $hdr (keys %{$message->{headers}}) {
                    print "SENT: " . $hdr . ": " . $message->{headers}->{$hdr} . "\n";
                    print $socket $hdr . ": " . $message->{headers}->{$hdr} . "\r\n";
                }
                print $socket "\r\n";
                print $socket $message->{body};
                print "SENT: " . $message->{body} . "\n";
                print $socket "\r\n.\r\n";
                $state = 'done';
            } elsif ($state eq 'done') {
                $success = 1;
                print "Successfully sent message, maybe!\n";
                $socket->close;
            }
        }

        last if $success;
    }

    if(!$success) {
        # It failed, so re-queue
        # TODO requeue for a later time
        $self->queue->insert($message);
        return 0;
    }

    return 1;
}

1;