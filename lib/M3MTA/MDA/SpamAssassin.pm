package M3MTA::MDA::SpamAssassin;

use Moose;
use Modern::Perl;
use Mail::SpamAssassin;

has 'spamassassin' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

	$self->spamassassin($M3MTA::bin::mda::spamassassin);
}

sub test {
	my ($self, $message) = @_;

	my $mail = $self->spamassassin->parse($message);
	my $status = $self->spamassassin->check($mail);
	if($status->is_spam) {
		$message = $status->rewrite_mail;
	}

	$status->finish;
	$mail->finish;

	return $message;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;