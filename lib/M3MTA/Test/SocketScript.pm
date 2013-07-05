package M3MTA::Test::SocketScript;

use Test::More;

# HOW TO SCRIPT A TEST
#
# Regex capture: [key:"regex"], e.g.
#     [host:"[^\\s]+"]
# captures anything matching [^\s]+ into a variable named 'host'
#
# Variable substitution: [=key], e.g.
#	  [=host]
# inserts the value captured in the earlier 'host' regex

sub get_socket {
	my ($class, $host, $port) = @_;

	my $socket = IO::Socket::INET->new(
		PeerAddr => $host,
		PeerPort => $port,
		Proto	 => 'tcp',
	) or die("Can't connect: $@");

	return $socket;
}

sub batch {
	my ($class, $socket_callback, @tests) = @_;

	for my $test (@tests) {
		my ($name) = $test =~ /^\s*([^\r\n]*)/;
		$test =~ s/^\s*[^\r\n]*\s*[\r\n]?//;
		subtest $name => sub {
			M3MTA::Test::SocketScript->run($socket_callback->(), $test);
		};
	}
}

sub run {
	my ($class, $socket, $test) = @_;

	my @lines = split /\n/, $test;
	my %vars = ();
	my $lastsent = undef;
	for my $line (@lines) {
		print "Line: $line\n" if $DEBUG;
		my ($a, $b) = $line =~ /\s*([SR]): (.*)/;

		for my $var (keys %vars) {
			print "Checking for var [=$var]\n" if $DEBUG;
			my $re = qr/\[=$var\]/;
			my $value = $vars{$var};
			$b =~ s/$re/$value/g;
		}

		$b =~ s/\\r/\r/g;
		$b =~ s/\\n/\n/g;

		print "Expected data: $b\n" if $DEBUG;

		if($a eq 'S') {
			print "Sending data: $b\n" if $DEBUG;
			print $socket "$b\r\n";
			$lastsent = $b;
		} elsif ($a eq 'R') {
			print "Reading data...\n" if $DEBUG;
			my $data = <$socket>;
			while(my ($var, $re) = $b =~ /\[(\w+):"(.*)"\]/) {
				print "Var: $var\n" if $DEBUG;
				$b =~ s/\[(\w+):"(.*)"\]/($re)/;
				my $c = qr/$b/;
				my ($value) = $data =~ $c;
				$vars{$var} = $value;
				print "Got value: $value\n" if $DEBUG;
			}
			print "Reading data: $data\n" if $DEBUG;
			my $re = qr/$b/;
			if($data =~ $re) {
				ok(1, 'Data matches expected: ' . $b);
			} else {
				ok(0, "Data [$data] didn't match expected [$b], in response to [$lastsent]");
			}
			
		}
	}
	ok(1, 'Test finished');
}

1;