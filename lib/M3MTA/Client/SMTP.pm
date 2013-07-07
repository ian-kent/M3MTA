package M3MTA::Client::SMTP;

use Modern::Perl;
use Moose;

use Data::Dumper;
use Net::DNS::Resolver;
use M3MTA::Log;

#------------------------------------------------------------------------------

sub send {
	my ($self, $envelope, $error) = @_;

    # TODO deal with anything in params on to/from address
    
    # TODO support multiple recipients
	my $to = $envelope->to->[0];

	M3MTA::Log->debug("Relaying message to: $to");

    # DNS lookup
    my $dns = new Net::DNS::Resolver;
    my $mx = $dns->query( $to->domain, 'MX' );

    if(!$mx) {
    	M3MTA::Log->debug("No MX record found, looking up A record");

    	my $a = $dns->query( $to->domain, 'A' );
    	if(!$a) {
	        $$error = "No MX or A record found for domain " . $to->domain;
	        M3MTA::Log->debug("Message relay failed, no MX or A record for domain " . $to->domain);
	        return -2; # permanent failure, no hostname
    	}

    	M3MTA::Log->debug("Using A record in place of missing MX record");
    	$mx = $a;
    }

    my $hostname = M3MTA::Config->existing->config->{hostname};

	my %hosts;
    for my $result ($mx->answer) {
        my $host = '';
        $host = join '.', @{$result->{exchange}->{label}} if $result->{exchange}->{label};
        my $origin = $result->{exchange}->{origin};
        while($origin) {
            $host .= '.' . (join '.', @{$origin->{label}}) if $origin->{label};
            $origin = $origin->{origin};
        }

		# Make sure the domain isn't this host
		# TODO can probably do a better job of this!
    	next if lc $host eq lc $hostname;

        $hosts{$host} = $result->{preference};
    }

    M3MTA::Log->debug("Found MX hosts (enable TRACE to see list)");
    M3MTA::Log->trace(Dumper \%hosts);

    my @ordered;
    for my $key ( sort { $hosts{$a} cmp $hosts{$b} } keys %hosts ) {
        push @ordered, $key;
    }

    if(scalar @ordered == 0) {
    	$$error = "No destination hosts found for domain " . $to->domain;
        M3MTA::Log->debug("Message relay failed, no valid destination hosts found");
        return -3; # permanent failure, no hostname after filter
    }

    my $success = 0;
    for my $host (@ordered) {
        M3MTA::Log->debug("Attempting delivery to host [$host]");

        my $socket = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => 25,
            Proto => 'tcp'
        ) or M3MTA::Log->error("Error creating socket: $@");

        if($socket) {
	        my $state = 'connect';
            my $dsn = 0;
            my $size = 0;
            my $auth = 0;
	        while (my $data = <$socket>) {
	            my ($cmd, $wait, $arg) = $data =~ /(\d+)(-|\s)(.*)/;
	            $wait = '' if $wait eq ' ';

	            M3MTA::Log->trace("RECD: data[$data], cmd[$cmd], wait[$wait], arg[$arg]");

                # In helo mode (after EHLO), see if we have a 220 line
                $dsn = 1 if $state eq 'helo' && $arg =~ /DSN/;
                $size = 1 if $state eq 'helo' && $arg =~ /SIZE/;
                $auth = 1 if $state eq 'helo' && $arg =~ /AUTH/;
                if($state eq 'helo' && !$wait && $cmd =~ /250/) {
                    $state = 'ehlo';
                }

                # If we have, either the state has changed (and we sent MAIL)
                # or state is still 'helo' and we send a HELO instead

	            if($wait) {
	                M3MTA::Log->trace("Waiting for next line");
	            } elsif ($state eq 'connect') {
                    M3MTA::Log->trace("SENT: EHLO $hostname");
                    print $socket "EHLO $hostname\r\n";
                    $state = 'helo';
                } elsif ($state eq 'helo') {
	                M3MTA::Log->trace("SENT: HELO $hostname");
	                print $socket "HELO $hostname\r\n";
	                $state = 'ehlo';
	            } elsif ($state eq 'ehlo') {
                    my $f = $envelope->from;
                    $f = "<$f>";
                    if($size) {
                        if($envelope->from->params->{SIZE}) {
                            $f .= " SIZE=" . $envelope->from->params->{SIZE};
                        }
                    }
                    if($auth) {
                        if($envelope->from->params->{AUTH}) {
                            $f .= " AUTH=" . $envelope->from->params->{AUTH};
                        }
                    }
                    if($dsn) {
                        if($envelope->from->params->{ENVID}) {
                            $f .= " ENVID=" . $envelope->from->params->{ENVID};
                        }
                        if($envelope->from->params->{RET}) {
                            $f .= " RET=" . $envelope->from->params->{RET};
                        }
                    }
                    M3MTA::Log->trace("DSN is: [$dsn]");
	                M3MTA::Log->trace("SENT: MAIL FROM:" . $f);
	                print $socket "MAIL FROM:" . $f . "\r\n";
	                $state = 'mail';
	            } elsif ($state eq 'mail') {
                    my $t = "<$to>";
                    if($dsn) {
                        if($to->params->{NOTIFY}) {
                            $t .= " NOTIFY=" . $to->params->{NOTIFY};
                        }
                        if($to->params->{ORCPT}) {
                            $t .= " ORCPT=" . $to->params->{ORCPT};
                        }
                    }
	                M3MTA::Log->trace("SENT: RCPT TO:$t");
	                print $socket "RCPT TO:$t\r\n";
	                $state = 'rcpt';
	            } elsif ($state eq 'rcpt') {
	                M3MTA::Log->trace("SENT: DATA");
	                print $socket "DATA\r\n";
	                $state = 'data';
	            } elsif ($state eq 'data') {
	            	my $data = $envelope->data;
	            	# rfc0821 4.5.2 transparency
	            	$data =~ s/\n\./\n\.\./s;	                
	                print $socket $data;
	                M3MTA::Log->trace("[SENT] " . $data);
	                print $socket "\r\n.\r\n";
	                $state = 'done';
	            } elsif ($state eq 'done') {
	                $success = 1;
	                M3MTA::Log->debug("Successfully sent message via SMTP");
	                $socket->close;
	            }
	        }
	    }

        last if $success;
    }

    if(!$success) {
    	M3MTA::Log->debug("No MX hosts responded for domain " . $to->domain . ": " . (join ', ', @ordered));
        $$error = "No MX hosts responded for domain " . $to->domain . ": " . (join ', ', @ordered);
        return -1; # retryable
    }

    M3MTA::Log->debug("Message successfully relayed to $to");
	return 1;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;