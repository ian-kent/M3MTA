package M3MTA::MDA::SpamAssassin;

use Moose;
use Modern::Perl;
use Mail::SpamAssassin;

has 'spamassassin' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

	$self->spamassassin(Mail::SpamAssassin->new);
}

sub test {
	my ($self, $message) = @_;

	my $mail = $self->spamassassin->parse($message);
	my $status = $self->spamassassin->check($mail);
	
	#if($status->is_spam) {
		# adds headers even if it isnt spam
		$message = $status->rewrite_mail;
	#}

	$status->finish;
	$mail->finish;

	return $message;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;