#!/usr/bin/env perl

use Modern::Perl;
use Test::More;
use IO::Socket::INET;
use M3MTA::Test::SocketScript;
use Mojo::IOLoop;

my $DEBUG = 0;
my $testrun = time . '-' . int(rand(100000));

note "Test run: $testrun";

# for now we'll assume M3MTA is already running
sub get_socket { 
	return M3MTA::Test::SocketScript->get_socket('localhost', 'smtp(25)');
}

# Construct a demo message
my $message = <<EOF
To: <postmaster\@[=host]>\\r\\n
Message-Id: test\@[=host]\\r\\n
Subject: Automated test message (run $testrun)\\r\\n
From: Automated Test <automated\@m3.mta>\\r\\n
Date: Tue 01 Jan 2013 00:00:00 +0000\\r\\n
\\r\\n
Message generated by automated test suite.\\r\\n
\\r\\n
.\\r\\n
EOF
;
# Replace actual newlines so we don't break the test 'script'
$message =~ s/\n//msg;

my $test = <<EOF
		Successful message delivery
		R: 220 [host:"[^\\s]+"] M3MTA
		S: HELO localhost
		R: 250 Hello 'localhost'. I'm M3MTA
		S: MAIL FROM:<>
		R: 250 sender ok
		S: RCPT TO:<postmaster@[=host]>
		R: 250 postmaster@[=host] recipient ok
		S: DATA
		R: 354 Send mail, end with "." on line by itself
		S: $message
		R: 250 [id:"[^\@]+@[=host]"] message accepted for delivery
		S: QUIT
		R: 221 Bye.
EOF
;

for(my $i = 0; $i <= 100; $i++) {
	my $num = $i;
	my $client = Mojo::IOLoop->client(
		address => 'localhost',
		port => 25,
		sub {
			my ($loop, $error, $stream) = @_;

			if($error) {
				ok(0, "Connection failed: $error");
				return;
			}

			ok(1, "Beginning message $num");

			my @cmds = (
				"HELO localhost\r\n",
				"MAIL FROM:<>\r\n",
				"RCPT TO:<postmaster>\r\n",
				"DATA\r\n",
				"Some data\r\n.\r\n",
				"QUIT\r\n",
			);

			$stream->on(read => sub {
				my ($self, $id, $chunk) = @_;
				$stream->write(shift @cmds);
				if(scalar @cmds == 0) {
					$stream->close;
				}
			});

			$stream->on(close => sub {
				ok(1, "Completed message $num");
			});
		}
	);
}
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

done_testing();