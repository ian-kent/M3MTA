package M3MTA::Util;

sub parse {
    my ($data) = @_;

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
            $h{$key} = [$h{$key}] if ref($h{$key}) !~ /ARRAY/;
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
    my ($message, $to) = @_;

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
        return -1;
    }

    return 1;
}

1;