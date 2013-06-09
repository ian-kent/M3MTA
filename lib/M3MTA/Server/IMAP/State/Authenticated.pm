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
	my ($self, $session, $id, $data, $examine) = @_;

	my $read_write = 'READ-WRITE'; # READ-ONLY

	$examine //= 0;
	$read_write = 'READ-ONLY' if $examine;
	my $cmd = $examine ? 'EXAMINE' : 'SELECT';

	my ($sub) = $data =~ /"(.*)"/;
    if($session->auth->{user}->{store}->{children}->{$sub}) {
        my $exists = $session->auth->{user}->{store}->{children}->{$sub}->{seen} + $session->auth->{user}->{store}->{children}->{$sub}->{unseen};
        my $recent = $session->auth->{user}->{store}->{children}->{$sub}->{unseen};
        my $permflags = '\Deleted \Seen \*';
        my $storeflags = '\Unseen'; # think this is flags used by the current mailbox?
        my $uidnext = $session->auth->{user}->{store}->{children}->{$sub}->{nextuid};
        my $unseen = $session->auth->{user}->{store}->{children}->{$sub}->{first_unseen} // $uidnext;
        my $validity = $session->auth->{user}->{validity}->{$sub} // 1;

        $session->respond('*', $exists . ' EXISTS');
        $session->respond('*', $recent . ' RECENT');
        $session->respond('*', "OK [UNSEEN $unseen]");
        $session->respond('*', "OK [UIDVALIDITY $validity]");
        $session->respond('*', "OK [UIDNEXT $uidnext]");
        $session->respond('*', "FLAGS ($storeflags)");
        $session->respond('*', "OK [PERMANENTFLAGS ($permflags)");               

        $session->respond($id, "OK [$read_write] $cmd completed");

        $session->selected($sub);
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

	# make sure path doesn't exist
	my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
	my $mbox = $session->imap->mailboxes->find_one($mboxid);
	if($mbox->{store}->{children}->{$path}) {
		$session->respond($id, 'BAD', 'CREATE failed; path already exists');
		return 1;
	}

	$session->imap->mailboxes->update($mboxid, {
		'$set' => {
			"store.children.$path" => {
				"seen" => 0,
				"unseen" => 0,
				"recent" => 0,
				"nextuid" => 1
			}
		},
		'$inc' => {
			"validity.$path" => 1,
		}
	});

	$session->respond($id, 'OK', 'CREATE successful');

	return 1;
}

#------------------------------------------------------------------------------

sub delete {
	my ($self, $session, $id, $data) = @_;

	my ($path) = $data =~ /^"(.*)"$/;

	# make sure path exists
	my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
	my $mbox = $session->imap->mailboxes->find_one($mboxid);
	if(!$mbox->{store}->{children}->{$path}) {
		$session->respond($id, 'BAD', 'DELETE failed; path doesn\'t exist');
		return 1;
	}

	$session->imap->mailboxes->update($mboxid, {
		'$unset' => {
			"store.children.$path" => 1
		}
	});

	# TODO remove items from store

	$session->respond($id, 'OK', 'DELETE successful');

	return 1;
}

#------------------------------------------------------------------------------

sub rename {
	my ($self, $session, $id, $data) = @_;

	my ($path, $to) = $data =~ /^"(.*)"\s"(.*)"$/;

	# make sure path exists
	my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
	my $mbox = $session->imap->mailboxes->find_one($mboxid);
	if(!$mbox->{store}->{children}->{$path}) {
		$session->respond($id, 'BAD', 'RENAME failed; path doesn\'t exist');
		return 1;
	}

	$session->imap->mailboxes->update($mboxid, {
		'$set' => {
			"store.children.$to" => $mbox->{store}->{children}->{$path},
			"validity.$to" => $mbox->{validity}->{$path}
		},
		'$unset' => {
			"store.children.$path" => 1,
			#"validity.$path" => 1 # Don't change - we want to leave validity alone, rename is same as delete
		}
	});

	# TODO change paths in store

	$session->respond($id, 'OK', 'RENAME successful');

	return 1;
}

#------------------------------------------------------------------------------

sub subscribe {
	my ($self, $session, $id, $data) = @_;

	my ($path) = $data =~ /^"(.*)"$/;

	my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
	$session->imap->mailboxes->update($mboxid, {
		'$set' => {
			"subscribe.$path" => 1
		}
	});

	$session->respond($id, 'OK', 'SUBSCRIBE successful');

	return 1;
}

#------------------------------------------------------------------------------

sub unsubscribe {
	my ($self, $session, $id, $data) = @_;

	my ($path) = $data =~ /^"(.*)"$/;

	my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
	$session->imap->mailboxes->update($mboxid, {
		'$set' => {
			"subscribe.$path" => 0
		}
	});

	$session->respond($id, 'OK', 'UNSUBSCRIBE successful');

	return 1;
}

#------------------------------------------------------------------------------

sub _get_store_node {
	my ($self, $session, $ref) = @_;

	# TODO change node based on reference name

	my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
	my $mbox = $session->imap->mailboxes->find_one($mboxid);

	return $mbox->{store};
}

#------------------------------------------------------------------------------

sub list {
	my ($self, $session, $id, $data) = @_;

	my ($ref, $mailbox) = $data =~ /"(.*)"\s"(.*)"/;

	$session->log("LIST Looking for mailboxes matching [%s] for reference name [%s]", $mailbox, $ref);

	my $store_node = $self->_get_store_node($session, $ref);

	$mailbox = '' if $mailbox eq '*';
	my $re = qr/($mailbox)/;

	# TODO should be recursive?
    for my $sub (keys %{$store_node->{children}}) {
    	my $flags = '\\HasNoChildren';
    	if(!$mailbox || $sub =~ $re) {
        	$session->respond('*', 'LIST (' . $flags . ') "' . $session->imap->config->{field_separator} . '"', $sub);
        }
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

	my $store_node = $self->_get_store_node($session, $ref);

	my $re;
	if ($mailbox eq '*') {
		$mailbox = undef;
		$re = qr/($mailbox)/;
	}

	my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
	my $mbox = $session->imap->mailboxes->find_one($mboxid);

	# TODO should be recursive?
    for my $sub (keys %{$store_node->{children}}) {
    	my $flags = '\\HasNoChildren';

    	next if !$mbox->{subscriptions}->{$sub};
    	if(!$mailbox || $sub =~ $re) {
        	$session->respond('*', 'LSUB (' . $flags . ') "' . $session->imap->config->{field_separator} . '"', $sub);
        }
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

		if($content =~ /\r\n\r\n$/) {
			$session->log("All data for message received");
			$session->receive_hook(undef);

			$content =~ s/\r\n\r\n$//m;

			my $result = $session->imap->_store_message($session, $mailbox, $flags, $content);
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

1;