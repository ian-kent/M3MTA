package M3MTA::Server::Backend::MongoDB::MDA;

use Moose;
extends 'M3MTA::Server::Backend::MDA', 'M3MTA::Server::Backend::MongoDB';

use Data::Dumper;
use DateTime;
use DateTime::Duration;
use M3MTA::Util;

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
    # TODO limit and delivery_time from requeue
    my @queued = $self->queue->find({
    	'$or' => [
    		{ "status" => "Pending" },
    		{ "status" => undef },
    	]
    })->all;

    $self->queue->update({
    	'$or' => [
            { "status" => "Pending" },
            { "status" => undef },
        ]
    },{
    	'$set' => { "status" => "Delivering" },
    }, {
    	"multiple" => 1
    });


    return \@queued;
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

    # TODO move to db?    
    my $rq = $self->config->{retry}->{durations}->[$email->{requeued}];    

    if($rq && $rq->{after}) {
        # Requeue for delivery
        my $rq_seconds = $rq->{after};

        # TODO timezones
        my $rq_date = DateTime->now->add(DateTime::Duration->new(seconds => $rq_seconds));

        $email->{delivery_time} = $rq_date;
        $email->{requeued} = int($email->{requeued}) + 1;
        $email->{attempts} = [] if !$email->{attempts};
        push $email->{attempts}, {
            date => DateTime->now,
            reason => $error,
        };
        $email->{status} = 'Pending';

        $self->queue->insert($email, { upsert => 1 });

        print STDOUT Data::Dumper::Dumper $email;

        if($rq->{notify}) {
            # send a temporary failure message (message requeued)
            return 2;
        }

        return 1;
    }

	return 0;
};

#------------------------------------------------------------------------------

override 'dequeue' => sub {
	my ($self, $email) = @_;

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

override 'notify' => sub {
    my ($self, $to, $subject, $content) = @_;

    my $msg_id = "temp\@localhost";
    my $msg_date = DateTime::Tiny->now;
    my $msg_from = "postmaster\@m3mta.mda";

    my $msg_data = <<EOF
Message-ID: $msg_id\r
Date: $msg_date\r
User-Agent: M3MTA/MDA\r
MIME-Version: 1.0\r
To: $to\r
From: $msg_from\r
Subject: $subject\r
Content-Type: text/plain; charset=UTF-8;\r
Content-Transfer-Encoding: 7bit\r
\r
$content\r
\r
M3MTA-MDA Postmaster
EOF
;
    $msg_data =~ s/\r?\n\./\r\n\.\./gm;

    my $reply = {
        date => $msg_date,
        status => 'Pending',
        data => $msg_data,
        helo => "localhost",
        id => "$msg_id",
        from => $msg_from,
        to => [ $to ],
    };
    $self->queue->insert($reply);

    return 1;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;