package M3MTA::Server::SMTP::Email;

use Data::Dumper;
use Modern::Perl;
use Moose;
use Net::DNS::Resolver;
use M3MTA::Log;

has 'headers' => ( is => 'rw', isa => 'HashRef', default => sub { {} } );
has 'body'    => ( is => 'rw', isa => 'Str' );
has 'size'	  => ( is => 'rw', isa => 'Int' );

has 'message' => ( is => 'rw', isa => 'M3MTA::Server::SMTP::Message' );

#------------------------------------------------------------------------------

sub from_message {
	my ($self, $message) = @_;

	# Call statically or as an object
	$self = ref $self ? $self : $self->new;

	# Store the original message object
	$message = $message // $self->message // undef;

	die("No message to parse") unless $message;

    # Parse the message data
    $self->from_data($message->data);

    # Return self (in case we're called statically)
    return $self;
}

#------------------------------------------------------------------------------

sub from_data {
	my ($self, $data) = @_;

	# Call statically or as an object
	$self = ref $self ? $self : $self->new;

	# Extract headers and body
    my ($headers, $body) = split /\r\n\r\n/m, $data, 2;

    # Parse the headers
    my @hdrs = split /\r\n/m, $headers;
    my %h = ();
    my $lasthdr = undef;
    for my $hdr (@hdrs) {
        if($lasthdr && $hdr =~ /^[\t\s]/) {
            # We've got a multiline header
            my $hx = $h{$lasthdr};
            if(ref($hx) eq 'ARRAY') {
                $hx->[-1] .= "\r\n$hdr";
            } else {
                $h{$lasthdr} .= "\r\n$hdr";
            }
            next;
        }

        my ($key, $value) = split /:\s/, $hdr, 2;
        $lasthdr = $key;

        if($h{$key}) {
            $h{$key} = [$h{$key}] if ref($h{$key}) !~ /ARRAY/;
            push $h{$key}, $value;
        } else {
            $h{$key} = $value;
        }
    }

    # Store everything
    $self->headers(\%h);
    $self->body($body);

    # Store the length
    $self->size(length $data);

    return $self;
}

#------------------------------------------------------------------------------

sub send_smtp {
	my ($self, $to, $error) = @_;
    
	M3MTA::Log->debug("Relaying message to: $to");
    my ($user, $domain) = $to =~ /(.*)@(.*)/;

    # DNS lookup
    my $dns = new Net::DNS::Resolver;
    my $mx = $dns->query( $domain, 'MX' );

    if(!$mx) {
        $$error = "No MX record found for domain $domain";
        M3MTA::Log->debug("Message relay failed, no MX record for domain $domain");
        return -2; # permanent failure
    }

	my %hosts;
    for my $result ($mx->answer) {
        my $host = '';
        $host = join '.', @{$result->{exchange}->{label}} if $result->{exchange}->{label};
        my $origin = $result->{exchange}->{origin};
        while($origin) {
            $host .= '.' . (join '.', @{$origin->{label}}) if $origin->{label};
            $origin = $origin->{origin};
        }

        $hosts{$host} = $result->{preference};
    }

    M3MTA::Log->debug("Found MX hosts (enable TRACE to see)");
    M3MTA::Log->trace(Dumper \%hosts);

    my @ordered;
    for my $key ( sort { $hosts{$a} cmp $hosts{$b} } keys %hosts ) {
        push @ordered, $key;
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
	                # TODO hostname
	                my $hostname = M3MTA::Config->existing->config->{hostname};
	                M3MTA::Log->trace("SENT: EHLO $hostname");
	                print $socket "EHLO $hostname\r\n";
	                $state = 'ehlo';
	            } elsif ($state eq 'ehlo') {
	                my ($name, $from) = $self->headers->{From} =~ /(.*)?<(.*)>/;
	                M3MTA::Log->trace("SENT: MAIL FROM:<$from>");
	                print $socket "MAIL FROM:<$from>\r\n";
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
	                for my $hdr (keys %{$self->headers}) {
	                    M3MTA::Log->trace("SENT: " . $hdr . ": " . $self->headers->{$hdr});
	                    print $socket $hdr . ": " . $self->headers->{$hdr} . "\r\n";
	                }
	                print $socket "\r\n";
	                my $msg = $self->body;
	                # rfc0821 4.5.2 transparency
	                $msg =~ s/\n\./\n\.\./s;
	                print $socket $msg;
	                M3MTA::Log->trace("SENT: " . $msg);
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