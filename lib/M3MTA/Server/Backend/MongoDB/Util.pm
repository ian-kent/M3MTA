package M3MTA::Server::Backend::MongoDB::Util;

use Modern::Perl;
use Moose;

use Data::Dumper;
use M3MTA::Log;
use M3MTA::Server::Models::Domain;
use M3MTA::Server::Models::Mailbox;
use M3MTA::Server::Models::Mailbox::Alias;
use M3MTA::Server::Models::Mailbox::Local;
use M3MTA::Server::Models::Mailbox::Message;

has 'backend' => ( is => 'rw', required => 1 );

#------------------------------------------------------------------------------

sub get_domain {
	my ($self, $domain) = @_;

	M3MTA::Log->debug("Loading domain: $domain");

	my $d = $self->domains->find_one({domain => $domain});
	return undef if !$d;

	return M3MTA::Server::Models::Domain->new->from_json($d);
}

#------------------------------------------------------------------------------

sub get_user {
	my ($self, $username, $password) = @_;

	M3MTA::Log->debug("Loading mailbox for username [$username], password [<hidden>]");
    my $mailbox = $self->backend->mailboxes->find_one({ username => $username, password => $password });

    if($mailbox && $mailbox->{destination}) {
        M3MTA::Log->debug("Mailbox is alias");
        return M3MTA::Server::Models::Mailbox::Alias->new->from_json($mailbox);
    } elsif ($mailbox) {
        M3MTA::Log->debug("Mailbox is local");
        return M3MTA::Server::Models::Mailbox::Local->new->from_json($mailbox);
    }

    M3MTA::Log->debug("Mailbox not found");
    return undef;
}

#------------------------------------------------------------------------------

sub get_mailbox {
	my ($self, $user, $domain) = @_;

	my $mailbox = $self->backend->mailboxes->find_one({ mailbox => $user, domain => $domain });
	$mailbox ||= $self->backend->mailboxes->find_one({ mailbox => '*', domain => $domain });

	# Resolve aliases
    while($mailbox && $mailbox->{destination}) {
        my $alias = $mailbox->{destination};
        my $alias_mb = $mailbox;
        M3MTA::Log->debug("Mailbox is alias, looking up $alias");

        ($user, $domain) = split /@/, $alias;
        $mailbox = $self->util->get_mailbox($user, $domain);

        if($mailbox) {
            M3MTA::Log->debug("Alias refers to local mailbox");
        } else {
            M3MTA::Log->debug("Alias points to external address");
            return M3MTA::Server::Models::Mailbox::Alias->new->from_json($alias_mb);
        }
    }

    if($mailbox) {
		return M3MTA::Server::Models::Mailbox::Local->new->from_json($mailbox);
	}

	return undef;
}

#------------------------------------------------------------------------------

sub add_to_queue {
	my ($self, $email) = @_;

	my $result = $self->backend->queue->insert($email->to_json);

	# TODO proper check?
	return $result ? 1 : 0;
}

#------------------------------------------------------------------------------

sub add_to_mailbox {
	my ($self, $user, $domain, $mailbox, $email, $path, $flags) = @_;

	# TODO chunked/oversize messages

	M3MTA::Log->debug(Dumper $mailbox);
    M3MTA::Log->debug("Local mailbox found, attempting GridFS delivery");

    $path //= $mailbox->delivery->path // 'INBOX';
    M3MTA::Log->debug("Delivering message to: $path");

    $flags //= ['\\Unseen', '\\Recent'];
    my %flag_map = map { $_ => 1 } @$flags;

    # Make the message for the store
    my $msg = M3MTA::Server::Models::Mailbox::Message->new;
    $msg->uid($mailbox->store->children->{$path}->nextuid);
    $msg->content($email);
    $msg->mailbox(M3MTA::Server::Models::Mailbox->new->from_json($mailbox->to_json));
    $msg->path($path);
    $msg->flags($flags);

    my $current = $mailbox->size->current;
    my $msgsize = $email->size // "<undef>";
    my $mbox_size = $current + $msgsize;
    M3MTA::Log->debug("Current mailbox size [$current], message size [$msgsize], new size [$mbox_size]");

    # Update mailbox next UID and total message count
    my $inc = {
    	"store.children.$path.nextuid" => 1,
    	"store.children.$path.exists" => 1,
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

    if(!$result->{ok}) {
        M3MTA::Log->debug("Mailbox failed to update, temporary failure");
        return $M3MTA::Server::Backend::SMTP::TEMPORARY_FAILURE;
    }

    M3MTA::Log->debug("Mailbox successfully updated, storing message");

    # Save it to the database
    my $oid = $self->backend->store->insert($msg->to_json);
    M3MTA::Log->info("Message accepted with ObjectID [$oid], UID [" . $msg->uid . "] for User [$user], Domain [$domain]");

    # Successful local delivery
    return $M3MTA::Server::Backend::SMTP::SUCCESSFUL;
}

#------------------------------------------------------------------------------

1;