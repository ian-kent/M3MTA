package M3MTA::Server::IMAP::State::Authenticated;

=head NAME
M3MTA::Server::IMAP::State::Authenticated
=cut

use Mouse;
use Modern::Perl;
use MIME::Base64 qw/ decode_base64 encode_base64 /;

#------------------------------------------------------------------------------

sub register {
	my ($self, $imap) = @_;
	
	$imap->register_rfc('RFC3501.Authenticated', $self);
	$imap->register_state('Authenticated', sub {
		$self->receive(@_);
	});
}

#------------------------------------------------------------------------------

sub receive {
	my ($self, $session, $id, $cmd, $data) = @_;
	$session->log("Received data in Authenticated state");

	return 0 if $cmd !~ /(SELECT|EXAMINE|CREATE|DELETE|RENAME|SUBSCRIBE|UNSUBSCRIBE|LIST|LSUB|STATUS|APPEND)/i;

	$cmd = lc $cmd;
	return $self->$cmd($session, $id, $data);
}

#------------------------------------------------------------------------------

sub select {
	my ($self, $session, $id, $data) = @_;

	my ($sub) = $data =~ /"(.*)"/;
    if($session->auth->{user}->{store}->{children}->{$sub}) {
        my $exists = $session->auth->{user}->{store}->{children}->{$sub}->{seen} + $session->auth->{user}->{store}->{children}->{$sub}->{unseen};
        my $recent = $session->auth->{user}->{store}->{children}->{$sub}->{unseen};
        $session->respond('*', 'FLAGS ()');
        $session->respond('*', $exists . ' EXISTS');
        $session->respond('*', $recent . ' RECENT');
    }
    $session->respond($id, 'OK');
    $session->state('Selected');

	return 1;
}

#------------------------------------------------------------------------------

sub examine {
	my ($self, $session, $id, $data) = @_;
	return 0;
}

#------------------------------------------------------------------------------

sub create {
	my ($self, $session, $id, $data) = @_;
	return 0;
}

#------------------------------------------------------------------------------

sub delete {
	my ($self, $session, $id, $data) = @_;
	return 0;
}

#------------------------------------------------------------------------------

sub rename {
	my ($self, $session, $id, $data) = @_;
	return 0;
}

#------------------------------------------------------------------------------

sub subscribe {
	my ($self, $session, $id, $data) = @_;
	return 0;
}

#------------------------------------------------------------------------------

sub unsubscribe {
	my ($self, $session, $id, $data) = @_;
	return 0;
}

#------------------------------------------------------------------------------

sub list {
	my ($self, $session, $id, $data) = @_;

	my ($um, $sub) = $data =~ /"(.*)"\s"(.*)"/;
    if($session->auth->{user}->{store}->{children}->{$sub}) {
        $session->respond('*', 'LIST (\HasNoChildren) "." "' . $sub . '"');
    }
    $session->respond($id, 'OK');

    return 1;
}

#------------------------------------------------------------------------------

sub lsub {
	my ($self, $session, $id, $data) = @_;

    for my $sub (keys %{$session->auth->{user}->{store}->{children}}) {
        $session->respond('*', 'LSUB () "."', $sub);
    }
    $session->respond($id, 'OK');

	return 1;
}

#------------------------------------------------------------------------------

sub status {
	my ($self, $session, $id, $data) = @_;
	return 0;
}

#------------------------------------------------------------------------------

sub append {
	my ($self, $session, $id, $data) = @_;
	return 0;
}
#------------------------------------------------------------------------------

1;