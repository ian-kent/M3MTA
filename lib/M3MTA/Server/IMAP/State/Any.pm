package M3MTA::Server::IMAP::State::Any;

=head NAME
M3MTA::Server::IMAP::State::Any
=cut

use Modern::Perl;
use Moose;

use MIME::Base64 qw/ decode_base64 encode_base64 /;

#------------------------------------------------------------------------------

sub register {
	my ($self, $imap) = @_;
	
	$imap->register_rfc('RFC3501.Any', $self);
	$imap->register_state('Any', sub {
		$self->receive(@_);
	});
}

#------------------------------------------------------------------------------

sub receive {
	my ($self, $session, $id, $cmd, $data) = @_;
	$session->log("Received data in Any state");

	return 0 if $cmd !~ /(CAPABILITY|NOOP|LOGOUT)/i;

	$cmd = lc $cmd;
	return $self->$cmd($session, $id, $data);
}

#------------------------------------------------------------------------------

sub get_capability {
	my ($self) = @_;
	# TODO
	return "CAPABILITY IMAP4rev1 STARTTLS AUTH=LOGIN";
}

#------------------------------------------------------------------------------

sub capability {
	my ($self, $session, $id, $data) = @_;

	$session->respond('*', $self->get_capability);
	$session->respond($id, 250, 'CAPABILITY completed');

	return 1;
}

#------------------------------------------------------------------------------

sub noop {
	my ($self, $session, $id, $data) = @_;

	$session->respond($id, 250, "Ok.");

	return 1;
}

#------------------------------------------------------------------------------

sub logout {
	my ($self, $session, $id, $data) = @_;

	$session->respond('*', 'BYE', $session->imap->config->{hostname}, 'server terminating connection');
    $session->respond($id, 'OK LOGOUT completed');
    $session->stream->on(drain => sub {
        $session->stream->close;
    });

	return 1;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;