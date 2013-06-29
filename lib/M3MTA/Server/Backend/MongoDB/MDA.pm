package M3MTA::Server::Backend::MongoDB::MDA;

use Moose;
extends 'M3MTA::Server::Backend::MDA', 'M3MTA::Server::Backend::MongoDB';

use Data::Dumper;
use DateTime;
use DateTime::Duration;
use M3MTA::Server::SMTP::Email;
use Tie::IxHash;

use M3MTA::Server::Backend::MongoDB::Util;
use M3MTA::Server::Models::Message;
use M3MTA::Log;
use MongoDB::OID;

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
    my $d = $self->util->get_domain($domain);

    if(!$d || !$d->postmaster) {
        # use a default address
        M3MTA::Log->debug("Postmaster address not found, using default postmaster\@$domain");
        return "postmaster\@$domain";
    }

    M3MTA::Log->debug("Using postmaster address " . $d->postmaster);
    return $d->postmaster;
};

#------------------------------------------------------------------------------

override 'poll' => sub {
    my ($self) = @_;

    M3MTA::Log->trace("Polling for queued emails");

    # Look for queued emails
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
    M3MTA::Log->trace(Dumper $cmd);

    my $result = $self->database->run_command($cmd);
    M3MTA::Log->trace(Dumper $result);

    if(!$result->{ok}) {
        M3MTA::Log->error("Error in query polling for message: " . (Dumper $result));
        return undef;
    }

    return undef if !$result->{value};
    
    return M3MTA::Server::Models::Message->new->from_json($result->{value});
};

#------------------------------------------------------------------------------

override 'requeue' => sub {
	my ($self, $email, $error) = @_;

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

    my $rq = $self->config->{retry}->{durations}->[$email->requeued];    

    if($rq && $rq->{after}) {
        # Requeue for delivery
        my $rq_seconds = $rq->{after};

        # TODO timezones
        my $rq_date = DateTime->now->add(DateTime::Duration->new(seconds => $rq_seconds));

        $email->delivery_time($rq_date);
        $email->requeued(int($email->{requeued}) + 1);
        push $email->attempts, M3MTA::Server::Models::Message::Attempt->new(
            date => DateTime->now,
            error => $error,
        );
        $email->status('Pending');

        M3MTA::Log->debug("Requeueing email for $rq_seconds seconds at $rq_date");

        my $result = $self->util->add_to_queue($email);
        if($result) {
            if($rq->{notify}) {
                # send a temporary failure message (message requeued)
                M3MTA::Log->debug("Email requeued, notification requested");
                return 2;
            }

            M3MTA::Log->debug("Email requeued, no notification requested");
            return 1;
        }

        M3MTA::Log->debug("E-mail not requeued, database error (enable TRACE to see result)");
        return 0;
    }

    M3MTA::Log->debug("E-mail not requeued");
	return 0;
};

#------------------------------------------------------------------------------

override 'dequeue' => sub {
	my ($self, $id) = @_;

    M3MTA::Log->debug("Dequeueing e-mail with id: $id");
	my $result = $self->queue->remove({ "_id" => MongoDB::OID->new($id) });

    if($result->{ok}) {
        M3MTA::Log->debug("E-mail dequeued (enable TRACE to see result)");
    } else {
        M3MTA::Log->error("Failed to dequeue e-mail (enable TRACE to see result)");
    }

    M3MTA::Log->trace(Dumper $result);

	return 1;
};

#------------------------------------------------------------------------------

override 'local_delivery' => sub {
    my ($self, $user, $domain, $email, $dest) = @_;

    # Get the local mailbox
    my $mailbox = $self->util->get_mailbox($user, $domain);

    if($mailbox && ref($mailbox) =~ /::Alias$/) {
        # Mailbox is external alias
        M3MTA::Log->debug("Destination is external alias");
        $$dest = $mailbox->destination;

        return $M3MTA::Server::Backend::MDA::EXTERNAL_ALIAS;
    } elsif ($mailbox) {
        # Attempt local delivery
        M3MTA::Log->debug("Local mailbox found, attempting GridFS delivery");
        M3MTA::Log->trace(Dumper $mailbox);

        return $self->util->add_to_mailbox($user, $domain, $mailbox, $email);
    }

    # Mailbox not found, check if we have a domain entry for local delivery (i.e. invalid user)
    my $domain2 = $self->domains->find_one({ domain => $domain });
    if($domain2 && $domain2->{delivery} eq 'local') {
        M3MTA::Log->debug("Domain entry found for local delivery but no user or catch-all exists");

        # No local user found
        return $M3MTA::Server::Backend::MDA::USER_NOT_FOUND;
    }

    # Not for local delivery
    M3MTA::Log->debug("Message not for local delivery");
    return $M3MTA::Server::Backend::MDA::NOT_LOCAL_DELIVERY;
};

#------------------------------------------------------------------------------

override 'notify' => sub {
    my ($self, $message) = @_;

    M3MTA::Log->debug("Queueing notification message");

    $message->delivery_time(DateTime->now) unless $message->delivery_time;
    my $result = $self->util->add_to_queue($message);

    return $result ? $M3MTA::Server::Backend::MDA::SUCCESSFUL : $M3MTA::Server::Backend::MDA::FAILED;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;