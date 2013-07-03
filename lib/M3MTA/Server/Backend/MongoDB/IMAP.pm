package M3MTA::Server::Backend::MongoDB::IMAP;

use Modern::Perl;
use Moose;
extends 'M3MTA::Server::Backend::IMAP', 'M3MTA::Server::Backend::MongoDB';

use Data::Dumper;
use M3MTA::Log;

use M3MTA::Storage::Mailbox::Message;

use MIME::Base64 qw/ decode_base64 encode_base64 /;

# Collections
has 'mailboxes' => ( is => 'rw' );
has 'store' => ( is => 'rw' );

#------------------------------------------------------------------------------

after 'init_db' => sub {
    my ($self) = @_;

    # user mailboxes/aliases
    my $coll_mbox = $self->config->{backend}->{database}->{mailboxes}->{collection};
    M3MTA::Log->debug("Getting collection: " . $coll_mbox);
    $self->mailboxes($self->database->get_collection($coll_mbox));

    # message store (i.e. GridFS behind real mailboxes)
    my $coll_store = $self->config->{backend}->{database}->{store}->{collection};
    M3MTA::Log->debug("Getting collection: " . $coll_store);
    $self->store($self->database->get_collection($coll_store));

    M3MTA::Log->debug("Database initialisation completed");
};

#------------------------------------------------------------------------------

override 'get_user' => sub {
    my ($self, $username, $password) = @_;
    
    M3MTA::Log->debug("User auth for username [$username] with password [$password]");

    return $self->util->get_user($username, $password);
};

#------------------------------------------------------------------------------

override 'get_mailbox' => sub {
    my ($self, $mailbox, $domain) = @_;
    
    M3MTA::Log->debug("Getting mailbox for $mailbox\@$domain");

    return $self->util->get_mailbox($mailbox, $domain);
};

#------------------------------------------------------------------------------

override 'append_message' => sub {
    my ($self, $session, $path, $flags, $content) = @_;

    M3MTA::Log->debug("Storing message to path [$path]");

    # Make the message for the store
    my $email = M3MTA::Storage::Mailbox::Message::Content->new->from_data($content);    
    M3MTA::Log->trace(Dumper $email);

    my @flgs = split /\s/, $flags;
    push @flgs, '\\Recent';

    M3MTA::Log->debug("Setting flags: " . (join ', ', @flgs));

    my $mailbox = $self->util->get_mailbox(
        $session->auth->mailbox,
        $session->auth->domain,
    );

    use Data::Dumper;
    M3MTA::Log->debug("Loaded mailbox");
    M3MTA::Log->trace(Dumper $mailbox);

    return $self->util->add_to_mailbox(
        $session->auth->mailbox,
        $session->auth->domain,
        $mailbox,
        $email,
        $path,
        \@flgs
    );
};

#------------------------------------------------------------------------------

override 'fetch_messages' => sub {
	my ($self, $session, $query) = @_;

    # Note - we just use a JSON query here, its probably
    # the easiest way to describe an IMAP query anyway
	my @messages = $self->store->find($query)->all;
    M3MTA::Log->trace(Dumper \@messages);

    my @msgs = map { 
        M3MTA::Storage::Mailbox::Message->new->from_json($_);
    } @messages;

	return \@msgs;
};

#------------------------------------------------------------------------------

override 'create_folder' => sub {
	my ($self, $session, $path) = @_;

	# Get mailbox
	my $mboxid = {
		mailbox => $session->auth->mailbox,
		domain => $session->auth->domain,
	};
	my $mbox = $self->mailboxes->find_one($mboxid);

	# Make sure path doesn't exist
	if($mbox->{store}->{children}->{$path}) {		
		return 0;
	}

	# Create new folder
	$self->mailboxes->update($mboxid, {
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

#------------------------------------------------------------------------------

override 'delete_folder' => sub {
    my ($self, $session, $path) = @_;

    # make sure path exists
	my $mboxid = {
		mailbox => $session->auth->mailbox,
		domain => $session->auth->domain,
	};
	my $mbox = $self->mailboxes->find_one($mboxid);

	if(!$mbox->{store}->{children}->{$path}) {
		return 0;
	}

	$self->mailboxes->update($mboxid, {
		'$unset' => {
			"store.children.$path" => 1
		}
	});

	# TODO remove items from store

	return 1;
};

#------------------------------------------------------------------------------

override 'rename_folder' => sub {
	my ($self, $session, $path, $to) = @_;

	# make sure path exists
	my $mboxid = {mailbox => $session->auth->mailbox, domain => $session->auth->domain};
	my $mbox = $self->mailboxes->find_one($mboxid);

	if(!$mbox->{store}->{children}->{$path}) {
		return 0;
	}

	$self->mailboxes->update($mboxid, {
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

#------------------------------------------------------------------------------

override 'subscribe_folder' => sub {
	my ($self, $session, $path) = @_;

	my $mboxid = {
		mailbox => $session->auth->mailbox,
		domain => $session->auth->domain,
	};

	$self->mailboxes->update($mboxid, {
		'$set' => {
			"subscribe.$path" => 1
		}
	});

	return 1;
};

#------------------------------------------------------------------------------

override 'unsubcribe_folder' => sub {
	my ($self, $session, $path) = @_;

	my $mboxid = {
		mailbox => $session->auth->mailbox,
		domain => $session->auth->domain,
	};

	$self->mailboxes->update($mboxid, {
		'$set' => {
			"subscribe.$path" => 0
		}
	});

	return 1;
};

#------------------------------------------------------------------------------

override 'uid_copy' => sub {
    my ($self, $session, $from, $to, $dest) = @_;

    my $query = {
        "mailbox.domain" => $session->auth->domain,
        "mailbox.mailbox" => $session->auth->mailbox,
        "path" => $session->selected,
    };

    if(!defined $to) {
        $query->{uid} = int($from);
    } else {
        $query->{uid}->{'$gte'} = int($from);
        if ($to && $to ne '*') {
            $query->{uid}->{'$lte'} = int($to);
        } else {
            # TODO * actually means always include the last message
            # with the higest UID, even if $from is higher than that
            # so will need to adjust the $gte parameter
            delete $query->{uid}->{'$lte'};
        }
    }  
    $session->log(Dumper $query);
    my $msgs = $self->fetch_messages($session, $query);
    $session->log("Got " . (scalar @$msgs) . " messages");

    my $query2 = {
        "domain" => $session->auth->domain,
        "mailbox" => $session->auth->mailbox,
    };
    print Dumper $query2;
    my $mbox = $self->mailboxes->find_one($query2);

    print Dumper $mbox;

    my $src = $mbox->{store}->{children}->{$session->selected};
    my $mailbox = $mbox->{store}->{children}->{$dest};
    print Dumper $src;
    print Dumper $mailbox;

    for my $msg (@$msgs) {
        # Destination folder doesn't exist #TODO proper error
        return 0 if !$mailbox;

        # Update message UID
        $msg->{uid} = $mailbox->{nextuid};

        # Remove the _id
        delete $msg->{_id};

        # Increment mailbox values
        $mailbox->{nextuid} += 1;
        $mailbox->{seen} += 1;

        # Change the path
        $msg->{path} = $dest;

        # And add it to the store
        $self->store->insert($msg);
    }

    # Update the main mailbox
    $self->mailboxes->update($query2, $mbox);

    return 1;
};

#------------------------------------------------------------------------------

override 'uid_store' => sub {
	my ($self, $session, $from, $to, $params) = @_;

	my $query = {
        "mailbox.domain" => $session->auth->domain,
        "mailbox.mailbox" => $session->auth->mailbox,
        path => $session->selected,
        uid => int($from),
    };
    my $query2 = {
        "domain" => $session->auth->domain,
        "mailbox" => $session->auth->mailbox,
    };
    print Dumper $query;
    my $msg = $self->store->find_one($query);
    my $mbox = $self->mailboxes->find_one($query2);

    print Dumper $msg;
    print Dumper $mbox;

    if(!$msg) {
    	
    	return 0;
    }

    my $dirty = 0;
    my $dirty2 = 0;

    print Dumper $params;

    # TODO perhaps this bit should be on IMAP side, 
    # and leave just db update to backend
    # i.e., have a set/update_flags instead of uid_store
    if($params->{'+FLAGS'}) {
    	my @flags = $msg->{flags} ? @{$msg->{flags}} : ();
        $session->log("Message already has flags: [%s]", (join ', ', @flags));
        my %flag_map = map { $_ => 1 } @flags;

        # Remove the Unseen flag, must have seen the message to get here
        if($flag_map{'\\Unseen'}) {
            $session->log("Removing flag \\Unseen");
            delete $flag_map{'\\Unseen'};
            $mbox->{store}->{children}->{$session->selected}->{unseen}--;
            $dirty2 = 1;
        }

        # Remove the Recent flag - should probably move this to first UID FETCH
        if($flag_map{'\\Recent'}) {
            $session->log("Removing flag \\Recent");
            delete $flag_map{'\\Recent'};
            $mbox->{store}->{children}->{$session->selected}->{recent}--;
            $dirty2 = 1;
        }

        # Add in any flags provided
    	for my $flag (keys %{$params->{'+FLAGS'}}) {
			if(!$flag_map{$flag}) {
				$flag_map{$flag} = 1;
				$dirty = 1;
				
                if($flag_map{'\\Seen'}) {
                    $session->log("Adding flag \\Seen");
                    $mbox->{store}->{children}->{$session->selected}->{seen}++;
                    $dirty2 = 1;
                }
			}
    	}

    	$msg->{flags} = [keys %flag_map];
    	print Dumper $msg->{flags};
    }

    if($dirty) {
    	$session->log("Updating message in store");
    	$self->store->update($query, $msg);
	}
	if($dirty2) {
		$session->log("Updating mailbox");
		$self->mailboxes->update($query2, $mbox);
	}

	return 1;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;