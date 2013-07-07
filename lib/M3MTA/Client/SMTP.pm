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
    my ($user, $domain) = $to =~ /(.*)@(.*)/;

    # DNS lookup
    my $dns = new Net::DNS::Resolver;
    my $mx = $dns->query( $domain, 'MX' );

    if(!$mx) {
    	M3MTA::Log->debug("No MX record found, looking up A record");

    	my $a = $dns->query( $domain, 'A' );
    	if(!$a) {
	        $$error = "No MX or A record found for domain $domain";
	        M3MTA::Log->debug("Message relay failed, no MX or A record for domain $domain");
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
    	$$error = "No destination hosts found for domain $domain";
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
	        while (my $data = <$socket>) {
	            my ($cmd, $wait, $arg) = $data =~ /(\d+)(-|\s)(.*)/;
	            $wait = '' if $wait eq ' ';

	            M3MTA::Log->trace("RECD: data[$data], cmd[$cmd], wait[$wait], arg[$arg]");

	            if($wait) {
	                M3MTA::Log->trace("Waiting for next line");
	            } elsif ($state eq 'connect') {
	                M3MTA::Log->trace("SENT: EHLO $hostname");
	                print $socket "EHLO $hostname\r\n";
	                $state = 'ehlo';
	            } elsif ($state eq 'ehlo') {
	                M3MTA::Log->trace("SENT: MAIL FROM:<" . $envelope->from . ">");
	                print $socket "MAIL FROM:<" . $envelope->from . ">\r\n";
	                $state = 'mail';
	            } elsif ($state eq 'mail') {
	                M3MTA::Log->trace("SENT: RCPT TO:<$to>");
	                print $socket "RCPT TO:<$to>\r\n";
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
    	M3MTA::Log->debug("No MX hosts responded for domain $domain: " . (join ', ', @ordered));
        $$error = "No MX hosts responded for domain $domain: " . (join ', ', @ordered);
        return -1; # retryable
    }

    M3MTA::Log->debug("Message successfully relayed to $to");
	return 1;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;