package M3MTA::Server::Backend::MongoDB::MDA;

use Moose;
extends 'M3MTA::Server::Backend::MDA', 'M3MTA::Server::Backend::MongoDB';

# Collections
has 'queue' => ( is => 'rw' );
has 'mailboxes' => ( is => 'rw' );
has 'domains' => ( is => 'rw' );
has 'store' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

	# TODO configuration

	# incoming queue from smtp daemon
    $self->queue($self->database->get_collection('queue'));

	# user mailboxes/aliases
	$self->mailboxes($self->database->get_collection('mailboxes'));

	# domains this system recognises
	$self->domains($self->database->get_collection('domains'));

	# message store (i.e. GridFS behind real mailboxes)
	$self->store($self->database->get_collection('store'));
}

#------------------------------------------------------------------------------

override 'poll' => sub {
    my ($self, $count) = @_;

    # Look for queued emails
    # TODO limit
    my @queued = $self->queue->find({
    	'$or' => [
    		{ "status" => "Pending" },
    		{ "status" => undef },
    	]
    })->all;

    $self->queue->update({
    	"status" => "Pending",
    },{
    	'$set' => { "status" => "Delivering" },
    }, {
    	"multiple" => 1
    });


    return \@queued;
};

#------------------------------------------------------------------------------

override 'requeue' => sub {
	my ($self, $email) = @_;

	$email->{requeued} = 0 if !$email->{requeued};
	$email->{requeued}++;

	# TODO redelivery time

	$email->{status} = 'Pending';

	$self->queue->insert($email);

	return 1;
};

#------------------------------------------------------------------------------

override 'dequeue' => sub {
	my ($self, $email) = @_;

	$self->queue->remove($email);

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
        print " - Local mailbox found, attempting GridFS delivery\n";

        my $path = $mailbox->{delivery}->{path} // 'INBOX';

        # Make the message for the store
        my $msg = {
            uid => $mailbox->{store}->{children}->{$path}->{nextuid},
            message => $email,
            mailbox => { domain => $domain, user => $user },
            path => $path,
            flags => ['\\Unseen', '\\Recent'],
        };

        # Update mailbox next UID
        $self->mailboxes->update({mailbox => $user, domain => $domain}, {
            '$inc' => {
                "store.children.$path.nextuid" => 1,
                "store.children.$path.unseen" => 1,
                "store.children.$path.recent" => 1 
            } 
        } );

        # Save it to the database
        my $oid = $self->store->insert($msg);
        print " | message stored with ObjectID [$oid], UID [" . $msg->{uid} . "] for User [$user], Domain [$domain]\n";

        # Successful local delivery
        return 1;
    }

    # Check if we have a domain entry for local delivery (means user doesn't exist)
    my $domain2 = $self->domains->find_one({ domain => $domain });
    if($domain2 && $domain2->{delivery} eq 'local') {
        print " - Domain entry found for local delivery but no user or catch-all exists\n";

        # No local user found
        return -1;
    }

    # Not for local delivery
    return 0;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;