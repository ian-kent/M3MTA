package M3MTA::Server::Backend::MongoDB::MDA;

use Moose;
extends 'M3MTA::Server::Backend::MDA', 'M3MTA::Server::Backend::MongoDB';

use Data::Dumper;
use DateTime;
use DateTime::Duration;
use M3MTA::Server::SMTP::Email;
use Tie::IxHash;

use M3MTA::Log;

# Collections
has 'queue' => ( is => 'rw' );
has 'mailboxes' => ( is => 'rw' );
has 'domains' => ( is => 'rw' );
has 'store' => ( is => 'rw' );

#------------------------------------------------------------------------------

after 'init_db' => sub {
    my ($self) = @_;

    # incoming queue from smtp daemon
    my $coll_queue = $self->config->{backend}->{database}->{queue}->{collection};
    M3MTA::Log->debug("Getting collection: " . $coll_queue);
    $self->queue($self->database->get_collection($coll_queue));

    # user mailboxes/aliases
    my $coll_mbox = $self->config->{backend}->{database}->{mailboxes}->{collection};
    M3MTA::Log->debug("Getting collection: " . $coll_mbox);
    $self->mailboxes($self->database->get_collection($coll_mbox));

    # domains this system recognises
    my $coll_domain = $self->config->{backend}->{database}->{domains}->{collection};
    M3MTA::Log->debug("Getting collection: " . $coll_domain);
    $self->domains($self->database->get_collection($coll_domain));

    # message store (i.e. GridFS behind real mailboxes)
    my $coll_store = $self->config->{backend}->{database}->{store}->{collection};
    M3MTA::Log->debug("Getting collection: " . $coll_store);
    $self->store($self->database->get_collection($coll_store));

    M3MTA::Log->debug("Database initialisation completed");
};

#------------------------------------------------------------------------------

override 'get_postmaster' => sub {
    my ($self, $domain) = @_;

    M3MTA::Log->debug("Looking for postmaster address for domain " . $domain);
    my $d = $self->domains->find_one({domain => $domain});

    if(!$d || !$d->{postmaster}) {
        # use a default address
        M3MTA::Log->debug("Postmaster address not found, using default postmaster\@$domain");
        return "postmaster\@$domain";
    } else {
        M3MTA::Log->debug("Using postmaster address " . $d->{postmaster});
    }

    return $d->{postmaster};
};

#------------------------------------------------------------------------------

override 'poll' => sub {
    my ($self) = @_;

    # Look for queued emails
    my %cmd;
    my $cmd = Tie::IxHash->new(
        findAndModify => 'queue', # TODO configuration
        remove => 1,
        query => {
            '$or' => [
                { "status" => "Pending" },
                { "status" => undef },
            ],
            "delivery_time" => {
                '$lte' => DateTime->now,
            }
        }
    );

    my $result = $self->database->run_command($cmd);
    return undef if !$result->{ok};
    return $result->{value};
};

#------------------------------------------------------------------------------

override 'requeue' => sub {
	my ($self, $email, $error) = @_;

	$email->{requeued} = 0 if !$email->{requeued};

    # Why these values are chosen in default config
    # 1: +900    (15m after queued)
    # 2: +900    (30m after queued)
    # 3: +1800   ( 1h after queued)
    # 4: +7200   ( 3h after queued)
    # 5: +32400  (12h after queued)
    # 6: +43200  ( 1d after queued)
    # 7: +86400  ( 2d after queued)
    # 8: +172800 ( 4d after queued)
    # 9: +259200 ( 1w after queued)

    # Note - notify value is the one *after* the "after" setting
    # i.e., to notify of temporary failure on the 1hr requeue,
    # we add notify => 1 to the 3hr config

    # this is because the notification is actually a 
    # 'notify of requeue or failure' notification, not a 
    # 'notify of item requeued for later date'

    # also notice that the final notify => 1 is on the after => undef
    # config item, this causes the item to not be requeued and for a 
    # permanent failure response to be sent

    my $rq = $self->config->{retry}->{durations}->[$email->{requeued}];    

    if($rq && $rq->{after}) {
        # Requeue for delivery
        my $rq_seconds = $rq->{after};

        # TODO timezones
        my $rq_date = DateTime->now->add(DateTime::Duration->new(seconds => $rq_seconds));

        M3MTA::Log->debug("Requeued email for $rq_seconds seconds at $rq_date");

        $email->{delivery_time} = $rq_date;
        $email->{requeued} = int($email->{requeued}) + 1;
        $email->{attempts} = [] if !$email->{attempts};
        push $email->{attempts}, {
            date => DateTime->now,
            reason => $error,
        };
        $email->{status} = 'Pending';

        $self->queue->insert($email, { upsert => 1 });

        M3MTA::Log->trace(Data::Dumper::Dumper $email);

        if($rq->{notify}) {
            # send a temporary failure message (message requeued)
            M3MTA::Log->debug("Email requeued, notification requested");
            return 2;
        }

        M3MTA::Log->debug("Email requeued, no notification requested");
        return 1;
    }

    M3MTA::Log->debug("E-mail not requeued");
	return 0;
};

#------------------------------------------------------------------------------

override 'dequeue' => sub {
	my ($self, $email) = @_;

    M3MTA::Log->debug("Dequeueing e-mail with id: " . $email->{_id});
	$self->queue->remove({ "_id" => $email->{_id} });

	return 1;
};

#------------------------------------------------------------------------------

override 'local_delivery' => sub {
    my ($self, $user, $domain, $email) = @_;

    # Check if we have a real mailbox entry
    my $mailbox = $self->mailboxes->find_one({ mailbox => $user, domain => $domain });
    # ... or a catch-all
    $mailbox ||= $self->mailboxes->find_one({ mailbox => '*', domain => $domain });
    if($mailbox) {
        M3MTA::Log->debug("Local mailbox found, attempting GridFS delivery");

        my $path = $mailbox->{delivery}->{path} // 'INBOX';

        # Make the message for the store
        my $msg = {
            uid => $mailbox->{store}->{children}->{$path}->{nextuid},
            message => {
                headers => $email->headers,
                body => $email->body,
                size => $email->size,
            },
            mailbox => { domain => $domain, user => $user },
            path => $path,
            flags => ['\\Unseen', '\\Recent'],
        };

        my $current = $mailbox->{size}->{current};
        use Data::Dumper;
        M3MTA::Log->trace(Dumper $email);
        my $msgsize = $email->size // "<undef>";
        my $mbox_size = $current + $msgsize;
        M3MTA::Log->debug("Current size [$current], message size [$msgsize], new size [$mbox_size]");

        # Update mailbox next UID
        $self->mailboxes->update({mailbox => $user, domain => $domain}, {
            '$inc' => {
                "store.children.$path.nextuid" => 1,
                "store.children.$path.unseen" => 1,
                "store.children.$path.recent" => 1 
            },
            '$set' => {
                "size.current" => $mbox_size,
            }
        } );

        # Save it to the database
        my $oid = $self->store->insert($msg);
        M3MTA::Log->info("Message accepted with ObjectID [$oid], UID [" . $msg->{uid} . "] for User [$user], Domain [$domain]");

        # Successful local delivery
        return 1;
    }

    # Check if we have a domain entry for local delivery (means user doesn't exist)
    my $domain2 = $self->domains->find_one({ domain => $domain });
    if($domain2 && $domain2->{delivery} eq 'local') {
        M3MTA::Log->debug("Domain entry found for local delivery but no user or catch-all exists");

        # No local user found
        return -1;
    }

    # Not for local delivery
    M3MTA::Log->debug("Message not for local delivery");
    return 0;
};

#------------------------------------------------------------------------------

override 'notify' => sub {
    my ($self, $message) = @_;

    $message->{delivery_time} = DateTime->now;
    $self->queue->insert($message);

    return 1;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;