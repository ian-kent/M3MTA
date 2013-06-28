package M3MTA::MDA::SpamAssassin;

use Moose;
use Modern::Perl;
use Mail::SpamAssassin;
use Data::Dumper;
use M3MTA::Log;

has 'mda' => ( is => 'rw', required => 1 );
has 'spamassassin' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

	M3MTA::Log->debug("Creating instance of SpamAssassin");
	$self->spamassassin(Mail::SpamAssassin->new);
}

sub test {
	my ($self, $content, $email) = @_;

	if(!$content) {
		M3MTA::Log->debug("SpamAssassin test not performed, message has no content");
		return {
			data => undef
		};
	}

	M3MTA::Log->debug("Testing message content with SpamAssassin (enable TRACE to see content)");
	M3MTA::Log->trace($content);

	my $mail = $self->spamassassin->parse($content);
	my $status = $self->spamassassin->check($mail);

	M3MTA::Log->debug("Rewriting message content");
	$content = $status->rewrite_mail;

	if($status->is_spam) {
		M3MTA::Log->debug("Message is spam")
	}

	$status->finish;
	$mail->finish;

	M3MTA::Log->debug("SpamAssassin test complete (enable TRACE to see result)");
	M3MTA::Log->trace(Dumper $status);

	return {
		data => $content
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;