package M3MTA::Server::Backend::MongoDB::Util;

use Modern::Perl;
use Moose;

use Data::Dumper;
use M3MTA::Log;

has 'backend' => ( is => 'rw', required => 1 );

#------------------------------------------------------------------------------

sub get_mailbox {
	my ($self, $user, $domain) = @_;

	my $mailbox = $self->backend->mailboxes->find_one({ mailbox => $user, domain => $domain });
	$mailbox ||= $self->backend->mailboxes->find_one({ mailbox => '*', domain => $domain });

	# Resolve aliases
    while($mailbox && $mailbox->{destination}) {
        my $alias = $mailbox->{destination};
        M3MTA::Log->debug("Mailbox is alias, looking up $alias");

        ($user, $domain) = split /@/, $alias;
        $mailbox = $self->util->get_mailbox($user, $domain);

        if($mailbox) {
            M3MTA::Log->debug("Alias refers to local mailbox");
        } else {
            M3MTA::Log->debug("Alias points to external address");
            return {
            	alias => $alias
            };
        }
    }

	return $mailbox;
}

#------------------------------------------------------------------------------

sub add_to_mailbox {
	my ($self, $user, $domain, $mailbox, $email, $path, $flags) = @_;

	# TODO chunked/oversize messages

	M3MTA::Log->debug(Dumper $mailbox);
    M3MTA::Log->debug("Local mailbox found, attempting GridFS delivery");

    $path //= $mailbox->{delivery}->{path} // 'INBOX';
    M3MTA::Log->debug("Delivering message to: $path");

    $flags //= ['\\Unseen', '\\Recent'];
    my %flag_map = map { $_ => 1 } @$flags;

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
        flags => $flags,
    };

    M3MTA::Log->trace(Dumper $msg);

    my $current = $mailbox->{size}->{current};
    my $msgsize = $email->size // "<undef>";
    my $mbox_size = $current + $msgsize;
    M3MTA::Log->debug("Current mailbox size [$current], message size [$msgsize], new size [$mbox_size]");

    # Update mailbox next UID and total message count
    my $inc = {
    	"store.children.$path.nextuid" => 1,
    	"store.children.$mailbox.exists" => 1,
    };
    # Add to unseen
    if($flag_map{'\\Unseen'}) {
    	$inc->{"store.children.$path.unseen"} = 1;
    }
    # Add to recent
    if($flag_map{'\\Recent'}) {
    	$inc->{"store.children.$path.recent"} = 1;
    }
    # Add to seen
    if($flag_map{'\\Seen'}) {
    	$inc->{"store.children.$path.seen"} = 1;
    }

    my $result = $self->backend->mailboxes->update({mailbox => $user, domain => $domain}, {
        '$inc' => $inc,
        '$set' => {
            "size.current" => $mbox_size,
        }
    } );

    if($result->{ok}) {
        M3MTA::Log->debug("Mailbox successfully updated, storing message");
    } else {
        M3MTA::Log->debug("Mailbox failed to update, temporary failure");
        return -2;
    }

    # Save it to the database
    my $oid = $self->backend->store->insert($msg);
    M3MTA::Log->info("Message accepted with ObjectID [$oid], UID [" . $msg->{uid} . "] for User [$user], Domain [$domain]");

    # Successful local delivery
    return 1;
}

#------------------------------------------------------------------------------

1;