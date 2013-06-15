package M3MTA::Server::Backend::MongoDB::IMAP;

use Modern::Perl;
use Moose;
extends 'M3MTA::Server::Backend::IMAP', 'M3MTA::Server::Backend::MongoDB';

use MIME::Base64 qw/ decode_base64 encode_base64 /;

# Collections
has 'mailboxes' => ( is => 'rw' );
has 'store' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

    # Get collections
    $self->mailboxes(
    	$self->database->get_collection(
    		$self->config->{database}->{mailboxes}->{collection}
    	)
    );
    $self->store(
    	$self->database->get_collection(
    		$self->config->{database}->{store}->{collection}
    	)
    );
}

#------------------------------------------------------------------------------

override 'get_user' => sub {
    my ($self, $username, $password) = @_;
    print "User auth for username [$username] with password [$password]\n";

    my $user = $self->mailboxes->find_one({username => $username, password => $password});
    print "Error: $@\n" if $@;

    return $user;
};

#------------------------------------------------------------------------------

override 'append_message' => sub {
    my ($self, $session, $mailbox, $flags, $content) = @_;

    # TODO
    $self->log("Storing message to mailbox [$mailbox] with flags [$flags]");

    # Make the message for the store
    my $mbox = $session->auth->{user}->{store}->{$mailbox};

    my $obj = parse($content);

    my @flgs = split /\s/, $flags;
    push @flgs, '\\Recent';

    my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
    my $mb = $session->imap->mailboxes->find_one($mboxid);
    use Data::Dumper;
    $self->log("Loaded mb:\n%s", (Dumper $mb));

    my $msg = {
        uid => $mb->{store}->{children}->{$mailbox}->{nextuid},
        message => $obj,
        mailbox => { domain => $session->auth->{user}->{domain}, user => $session->auth->{user}->{mailbox} },
        path => $mailbox,
        flags => \@flgs,
    };

    # Update mailbox next UID
    $self->mailboxes->update({mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}}, {
        '$inc' => {
            "store.children.$mailbox.nextuid" => 1,
            "store.children.$mailbox.recent" => 1,
            "store.children.$mailbox.unseen" => 1,
            "store.children.$mailbox.exists" => 1,
        } 
    } );

    # Save it to the database
    my $oid = $self->store->insert($msg);
    $self->log("Message stored with ObjectID [$oid], UID [" . $msg->{uid} . "]\n");

    return 1;
};

#------------------------------------------------------------------------------

override 'fetch_messages' => sub {
	my ($self, $session, $query) = @_;

	my @messages = $self->store->find($query)->all;

	# TODO turn into objects

	return \@messages;
};

#------------------------------------------------------------------------------

override 'create_folder' => sub {
	my ($self, $session, $path) = @_;

	# Get mailbox
	my $mboxid = {
		mailbox => $session->auth->{user}->{mailbox},
		domain => $session->auth->{user}->{domain}
	};	
	my $mbox = $session->imap->mailboxes->find_one($mboxid);

	# Make sure path doesn't exist
	if($mbox->{store}->{children}->{$path}) {		
		return 0;
	}

	# Create new folder
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

	return 1;
};

override 'delete_folder' => sub {
    my ($self, $session, $path) = @_;

    # make sure path exists
	my $mboxid = {
		mailbox => $session->auth->{user}->{mailbox},
		domain => $session->auth->{user}->{domain}
	};
	my $mbox = $session->imap->mailboxes->find_one($mboxid);

	if(!$mbox->{store}->{children}->{$path}) {
		return 0;
	}

	$session->imap->mailboxes->update($mboxid, {
		'$unset' => {
			"store.children.$path" => 1
		}
	});

	# TODO remove items from store

	return 1;
};

override 'rename_folder' => sub {
	my ($self, $session, $path, $to) = @_;

	# make sure path exists
	my $mboxid = {mailbox => $session->auth->{user}->{mailbox}, domain => $session->auth->{user}->{domain}};
	my $mbox = $session->imap->mailboxes->find_one($mboxid);
	if(!$mbox->{store}->{children}->{$path}) {
		return 0;
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

	return 1;
};

override 'select_folder' => sub {
	my ($self, $session, $path, $mode) = @_;

	if($session->auth->{user}->{store}->{children}->{$path}) {
        my $exists = $session->auth->{user}->{store}->{children}->{$path}->{seen} + $session->auth->{user}->{store}->{children}->{$path}->{unseen};
        my $recent = $session->auth->{user}->{store}->{children}->{$path}->{unseen};
        my $permflags = '\Deleted \Seen \*';
        my $storeflags = '\Unseen'; # think this is flags used by the current mailbox?
        my $uidnext = $session->auth->{user}->{store}->{children}->{$path}->{nextuid};
        my $unseen = $session->auth->{user}->{store}->{children}->{$path}->{first_unseen} // $uidnext;
        my $validity = $session->auth->{user}->{validity}->{$path} // 1;

        my @data;

        # TODO data structure, and move markup back to IMAP state
        push @data, $exists . ' EXISTS';
        push @data, $recent . ' RECENT';
        push @data, "OK [UNSEEN $unseen]";
        push @data, "OK [UIDVALIDITY $validity]";
        push @data, "OK [UIDNEXT $uidnext]";
        push @data, "FLAGS ($storeflags)";
        push @data, "OK [PERMANENTFLAGS ($permflags)";

       	return \@data;
    } else {
    	return 0;
    }
};

override 'subcribe_folder' => sub {
	my ($self, $session, $path) = @_;

	my $mboxid = {
		mailbox => $session->auth->{user}->{mailbox},
		domain => $session->auth->{user}->{domain}
	};

	$session->imap->mailboxes->update($mboxid, {
		'$set' => {
			"subscribe.$path" => 1
		}
	});

	return 1;
};

override 'unsubcribe_folder' => sub {
	my ($self, $session, $path) = @_;

	my $mboxid = {
		mailbox => $session->auth->{user}->{mailbox},
		domain => $session->auth->{user}->{domain}
	};

	$session->imap->mailboxes->update($mboxid, {
		'$set' => {
			"subscribe.$path" => 0
		}
	});

	return 1;
};

override 'fetch_folders' => sub {
	my ($self, $session, $ref, $filter, $subscribed) = @_;

	my $mboxid = {
		mailbox => $session->auth->{user}->{mailbox},
		domain => $session->auth->{user}->{domain}
	};
	my $mbox = $session->imap->mailboxes->find_one($mboxid);
	my $store_node = $mbox->{store};

	my @folders;
	my $re = qr/$filter/;

	for my $sub (keys %{$store_node->{children}}) {
    	if(!$filter || $sub =~ $re) {
    		next if $subscribed && !$mbox->{subscriptions}->{$sub};

    		my $flags = '\\HasNoChildren';
    		push @folders, {
    			path => $sub,
    			flags => $flags,
    		};
        }
    }

    return \@folders;
};

override 'uid_store' => sub {
	my ($self, $session, $from, $to, $params) = @_;

	my $query = {
        mailbox => {
            domain => $session->auth->{user}->{domain},
            user => $session->auth->{user}->{mailbox},
        },
        path => $session->selected,
        uid => int($from),
    };
    my $query2 = {
        mailbox => {
            domain => $session->auth->{user}->{domain},
            user => $session->auth->{user}->{mailbox},
        },
    };
    print Dumper $query;
    my $msg = $session->imap->store->find_one($query);
    my $mbox = $session->imap->mailboxes->find_one($query2);

    if(!$msg) {
    	
    	return 0;
    }

    my $dirty = 0;
    my $dirty2 = 0;

    # TODO perhaps this bit should be on IMAP side, 
    # and leave just db update to backend
    # i.e., have a set/update_flags instead of uid_store
    if($params->{'+Flags'}) {
    	my @flags = $msg->{flags} ? @{$msg->{flags}} : ();
        $session->log("Message already has flags: [%s]", (join ', ', @flags));
        my %flag_map = map { $_ => 1 } @flags;

    	for my $flag (keys %{$params->{'+Flags'}}) {
			if(!$flag_map{$flag}) {
				$flag_map{$flag} = 1;
				$dirty = 1;
				if($flag_map{'\\Unseen'}) {
					delete $flag_map{'\\Unseen'};
					$mbox->{store}->{$session->selected}->{unseen}--;
					$dirty2 = 1;
				}
				if($flag_map{'\\Recent'}) {
					delete $flag_map{'\\Recent'};
					$mbox->{store}->{$session->selected}->{recent}--;
					$dirty2 = 1;
				}
			}
    	}

    	$msg->{flags} = [keys %flag_map];
    	print Dumper $msg->{flags};
    }

    if($dirty) {
    	$session->log("Updating message in store");
    	$session->imap->store->update($query, $msg);
	}
	if($dirty2) {
		$session->log("Updating mailbox");
		$session->imap->mailboxes->update($query2, $mbox);
	}

	return 1;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;