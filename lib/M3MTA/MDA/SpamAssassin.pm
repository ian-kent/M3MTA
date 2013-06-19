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
	my ($self, $content, $email) = @_;

	my $mail = $self->spamassassin->parse($content);
	my $status = $self->spamassassin->check($mail);
	#if($status->is_spam) {
		$content = $status->rewrite_mail;
	#}

	$status->finish;
	$mail->finish;

	return {
		data => $content
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;