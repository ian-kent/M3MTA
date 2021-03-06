package M3MTA::Server::IMAP::State::Authenticated;

=head NAME
M3MTA::Server::IMAP::State::Authenticated
=cut

use Modern::Perl;
use Moose;

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
	my ($self, $session, $id, $data, $examine) = @_;

	my $read_write = 'READ-WRITE'; # READ-ONLY

	$examine //= 0;
	$read_write = 'READ-ONLY' if $examine;
	my $cmd = $examine ? 'EXAMINE' : 'SELECT';

	my ($path) = $data =~ /"(.*)"/;

	my $mailbox = $session->imap->get_mailbox($session->auth->mailbox, $session->auth->domain);
	my $folder = $mailbox->store->children->{$path};
	
	if($folder) {
        my $permflags = '\Deleted \Seen \*';
        my $storeflags = '\Unseen \Seen \Recent'; # think this is flags used by the current mailbox?
        my $validity = $mailbox->validity->{$path} // 1;

        $session->respond('*', $folder->exists . ' EXISTS');
        $session->respond('*', $folder->recent . ' RECENT');
        $session->respond('*', 'OK [UNSEEN ' . $folder->unseen . ']');
        $session->respond('*', "OK [UIDVALIDITY $validity]");
        $session->respond('*', "OK [UIDNEXT " . $folder->nextuid . "]");
        $session->respond('*', "FLAGS ($storeflags)");
        $session->respond('*', "OK [PERMANENTFLAGS ($permflags)");

		$session->respond($id, "OK [$read_write] $cmd completed");
        $session->selected($path);
    	$session->state('Selected');
	} else {
		$session->respond($id, "NO $cmd failed, no such mailbox");
    	$session->selected(undef);
    	$session->state('Authenticated');
	}

	return 1;
}

#------------------------------------------------------------------------------

sub examine {
	my ($self, $session, $id, $data) = @_;
	
	return $self->select($session, $id, $data, 1);
}

#------------------------------------------------------------------------------

sub create {
	my ($self, $session, $id, $data) = @_;

	my ($path) = $data =~ /^"(.*)"$/;

	my $result = $session->imap->create_folder($session, $path);

	if($result) {
		$session->respond($id, 'OK', 'CREATE successful');
	} else {
		$session->respond($id, 'BAD', 'CREATE failed; path already exists');
	}

	return 1;
}

#------------------------------------------------------------------------------

sub delete {
	my ($self, $session, $id, $data) = @_;

	my ($path) = $data =~ /^"(.*)"$/;

	my $result = $session->imap->delete_folder($session, $path);

	if($result) {
		$session->respond($id, 'OK', 'DELETE successful');
	} else {
		$session->respond($id, 'BAD', 'DELETE failed; path doesn\'t exist');
	}

	return 1;
}

#------------------------------------------------------------------------------

sub rename {
	my ($self, $session, $id, $data) = @_;

	my ($path, $to) = $data =~ /^"(.*)"\s"(.*)"$/;

	my $result = $session->imap->rename_folder($session, $path, $to);
	if($result) {
		$session->respond($id, 'OK', 'RENAME successful');
	} else {
		$session->respond($id, 'BAD', 'RENAME failed; path doesn\'t exist');
	}

	return 1;
}

#------------------------------------------------------------------------------

sub subscribe {
	my ($self, $session, $id, $data) = @_;

	my ($path) = $data =~ /^"(.*)"$/;

	$session->imap->subscribe_folder($session, $path);

	$session->respond($id, 'OK', 'SUBSCRIBE successful');

	return 1;
}

#------------------------------------------------------------------------------

sub unsubscribe {
	my ($self, $session, $id, $data) = @_;

	my ($path) = $data =~ /^"(.*)"$/;

	$session->imap->unsubscribe_folder($session, $path);

	$session->respond($id, 'OK', 'UNSUBSCRIBE successful');

	return 1;
}

#------------------------------------------------------------------------------

sub list {
	my ($self, $session, $id, $data) = @_;

	my ($ref, $mailbox) = $data =~ /"(.*)"\s"(.*)"/;

	$session->log("LIST Looking for mailboxes matching [%s] for reference name [%s]", $mailbox, $ref);

	$mailbox = '' if $mailbox eq '*';

	my $mbox = $session->imap->get_mailbox($session->auth->mailbox, $session->auth->domain);
	my $re = qr/$mailbox/;
	for my $path (keys %{$mbox->store->children}) {
		next if $path !~ $re;

		my $folder = $mbox->store->children->{$path};
		$session->respond(
			'*',
			'LIST (' . (join ' ', @{$folder->flags}) . ')',
			'"' . $session->imap->config->{field_separator} . '"',
			$folder->path,
		);
	}

    $session->respond($id, 'OK');

	return 1;
}

#------------------------------------------------------------------------------

sub lsub {
	my ($self, $session, $id, $data) = @_;

	# TODO should use subscribed/active list, not all mailboxes

	my ($ref, $mailbox) = $data =~ /"(.*)"\s"(.*)"/;

	$session->log("LSUB Looking for mailboxes matching [%s] for reference name [%s]", $mailbox, $ref);

	$mailbox = '' if $mailbox eq '*';

	my $mbox = $session->imap->get_mailbox($session->auth->mailbox, $session->auth->domain);
	for my $path (keys %{$mbox->store->children}) {
		next if !$mbox->subscriptions->{$path};

		my $folder = $mbox->store->children->{$path};
		$session->respond(
			'*',
			'LIST (' . (join ' ', @{$folder->flags}) . ')',
			'"' . $session->imap->config->{field_separator} . '"',
			$folder->path,
		);
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

	my ($mailbox, $flags, $len) = $data =~ /"(.*)"\s\((.*)\)\s\{(\d+)\}/;
	$session->log("Appending message with length [$len] to mailbox [$mailbox] with flags [$flags]");

	$session->respond('+ Ready for literal data');

	my $content = '';

	$session->receive_hook(sub {
		$session->log("Got message data for APPEND: [" . $session->buffer . "]");
		$content .= $session->buffer;
		$session->buffer('');

		my $newcontent = $content;
		$newcontent =~ s/\r/<CR>/g;
		$newcontent =~ s/\n/<LF>/g;

		if(length $content >= $len) {
			$session->log("All data for message received");
			$session->receive_hook(undef);

			$content =~ s/\r\n\r\n$//m;

			my $result = $session->imap->append_message($session, $mailbox, $flags, $content);
			if($result) {
				$session->respond($id, 'OK', 'APPEND completed');
			} else {
				$session->respond($id, 'BAD', 'APPEND failed - unable to store message');
			}
		}
	});

	return 1;
}
#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;