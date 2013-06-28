package M3MTA::Server::Backend::MongoDB::SMTP;

use Moose;
extends 'M3MTA::Server::Backend::SMTP', 'M3MTA::Server::Backend::MongoDB';

use MIME::Base64 qw/ decode_base64 encode_base64 /;
use Data::Dumper;
use M3MTA::Log;

# Collections
has 'queue'     => ( is => 'rw' );
has 'mailboxes' => ( is => 'rw' );
has 'domains' => ( is => 'rw' );

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

    M3MTA::Log->debug("Database initialisation completed");
};

#------------------------------------------------------------------------------

override 'get_user' => sub {
    my ($self, $username, $password) = @_;

    my $mailbox = $self->mailboxes->find_one({ username => $username, password => $password });
    M3MTA::Log->debug("Trying to load mailbox for '$username' with password '$password': " . (ref($mailbox)));

    return $mailbox;
};

#------------------------------------------------------------------------------

override 'can_user_send' => sub {
    my ($self, $session, $from) = @_;

    my ($user, $domain) = split /@/, $from;
    M3MTA::Log->debug("Checking if user is permitted to send from '%s'\@'%s'", $user, $domain);

    M3MTA::Log->debug("Auth: %s", Dumper $session->user);

    # Get the mailbox
    my $mailbox = $self->mailboxes->find_one({ mailbox => $user, domain => $domain });
    M3MTA::Log->debug("Mailbox: %s", Dumper $mailbox);

    if(!$mailbox) {
        # The 'from' address isn't local
        # TODO SPF sender checking etc
        # - perhaps shouldn't be done here - maybe as filter in MDA?
        return 1;
    }

    # local mailbox
    if($session->user && $session->user->{success} && $session->user->{username} eq $mailbox->{username}) {
        # user is authenticated against this mailbox
        return 1;
    }

    # user is not authenticated against this mailbox
    return 0;    
};

#------------------------------------------------------------------------------

override 'can_accept_mail' => sub {
    my ($self, $session, $to) = @_;

    my ($user, $domain) = split /@/, $to;
    M3MTA::Log->debug("Checking if server will accept messages addressed to '$user'\@'$domain'");
    M3MTA::Log->debug("- User: %s", Dumper $session->user) if $session->user;

    # Check for local delivery mailboxes (may be an alias, but thats dealt with after queueing)
    my $mailbox = $self->mailboxes->find_one({ mailbox => $user, domain => $domain });
    if( $mailbox ) {
        M3MTA::Log->debug("- Mailbox exists locally:");
        M3MTA::Log->debug(Dumper $mailbox);

        if($mailbox->{size}->{maximum} && $mailbox->{size}->{maximum} <= $mailbox->{size}->{current}) {
            # not an rfc, this is server mailbox policy
            M3MTA::Log->debug("x Mailbox is over size limit");
            return 3; # means mailbox over limit
        }

        return 1;
    }

    # Check if we have a catch-all mailbox (also may be an alias)
    my $catch = $self->mailboxes->find_one({ mailbox => '*', domain => $domain });
    if( $catch ) {
        M3MTA::Log->debug("- Recipient caught by domain catch-all");
        return 1;
    }

    # Check if the server is acting as an open relay
    if( $self->config->{relay}->{anon} ) {
        M3MTA::Log->debug("- Server is acting as open relay");
        return 1;
    }

    # Check if server allows all authenticated users to relay
    if( $session->user && $self->config->{relay}->{auth} ) {
        M3MTA::Log->debug("- User is authenticated and all authenticated users can relay");
        return 1;
    }

    # Check if this user can open relay
    if( $session->user && $session->user->{user}->{relay} ) {
        M3MTA::Log->debug("- User has remote relay rights");
        return 1;
    }

    # Check if we have the domain but not the user
    my $rdomain = $self->domains->find_one({ domain => $domain });
    if( $rdomain && $rdomain->{delivery} ne 'relay') {
        M3MTA::Log->debug("- Domain exists as local delivery but user doesn't exist and domain has no catch-all");
        return 2; # on this one we let the caller decide what response to give, e.g. so we can give a 
    }

    # Finally check if we have a relay domain
    if( $rdomain && $rdomain->{delivery} eq 'relay' ) {
        M3MTA::Log->debug("- Domain exists as 'relay'");
        return 1;
    }

    # None of the above
    M3MTA::Log->debug("x Mail not accepted for delivery");
    return 0;
};

#------------------------------------------------------------------------------

override 'queue_message' => sub {
    my ($self, $email) = @_;

    # TODO recheck size against mailbox if its local delivery
    # maybe store the delivery info on the $email object?
    # not an rfc thing at all, just a mailbox policy thing

    $email->date(DateTime->now);
    eval {
        my $data = $email->to_hash;
        $data->{delivery_time} = DateTime->now;
        $self->queue->insert($data);
    };

    if($email->{data} =~ /Subject: finish_profile/) {
        M3MTA::Log->debug("Finished profiling");
        DB::finish_profile();
    }

    my @res;
    my $id = $email->id;
    if($@) {
        @res = ("451", "$id message store failed, please retry later");
        M3MTA::Log->debug("Queue message failed for '%s': %s\n%s", $id, $@, (Dumper $email));
    } else {
        @res = ("250", "$id message accepted for delivery");
        M3MTA::Log->debug("Message queued for '%s':\n%s", $id, (Dumper $email));
    }

    return wantarray ? @res : join ' ', @res;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;