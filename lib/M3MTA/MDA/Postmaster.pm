package M3MTA::MDA::Postmaster;

use Moose;
use Modern::Perl;
use Data::Dumper;
use M3MTA::Log;

has 'mda' => ( is => 'rw', required => 1 );

#------------------------------------------------------------------------------

sub test {
	my ($self, $content, $email) = @_;

	M3MTA::Log->debug("Testing message content with Postmaster");

	if("$email->from" ne $self->mda->config->{filter_config}->{"M3MTA::MDA::Postmaster"}->{superuser}) {
		M3MTA::Log->debug("Sender is not a superuser");
		return {
			data => $content
		};
	}

	M3MTA::Log->debug("Sender '" . $email->from . "' is a superuser");

	my @recipients = ();
	for my $to (@{$email->to}) {
		if($to !~ /^m3\@mta:\/\//) {
			push @recipients, $to;
			next;
		}

		M3MTA::Log->debug("Message addressed to $to, treating as Postmaster request");

		my ($subject) = $content =~ /\nSubject:\s*([^\r\n]*)/m;
		M3MTA::Log->debug("Subject is: $subject");

		my $data = '';

		if(my ($daemon, $log, $lines) = $subject =~ /^LOG: (smtp|imap|mda) (err|out)\s?(\d+)?$/) {
			$lines //= 100;
			my $file = "/var/log/m3mta/$daemon.log.$log";
			$data .= "Last $lines lines of $file:\n";
			if($lines > 10000) {
				$lines = 10000;
				$data .= "(Lines limited to $lines)\n";
			}
			$data .= "\n";
			$data .= `tail -n$lines $file`;
		}

		if(!$data) {
			$data = <<EOF
M3MTA Postmaster MDA filter:

Send e-mails to m3\@mta://
Set subject line to:

	LOG: (smtp|imap|mda) (err|out) [lines]
		e.g. LOG: smtp err 1000
EOF
;
		}

		my $message = $self->mda->notification($email->from, "M3MTA Postmaster response", $data);
		$self->mda->backend->notify($message);
		M3MTA::Log->debug("Response queued");
	}

	if(scalar @recipients == 0) {
		M3MTA::Log->debug("Postmaster was the only recipient, dropping message");
		return {
			data => undef,
		};
	}
	$email->to(\@recipients);

	return {
		data => $content
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;