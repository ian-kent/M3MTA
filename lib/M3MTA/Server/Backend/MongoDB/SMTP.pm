package M3MTA::Server::Backend::MongoDB::SMTP;

use Moose;
extends 'M3MTA::Server::Backend::SMTP', 'M3MTA::Server::Backend::MongoDB';

use MIME::Base64 qw/ decode_base64 encode_base64 /;
use Data::Dumper;
use M3MTA::Log;

use M3MTA::Storage::Mailbox;
use M3MTA::Storage::Mailbox::Alias;
use M3MTA::Storage::Mailbox::Local;

# Collections
has 'queue'     => ( is => 'rw' );
has 'mailboxes' => ( is => 'rw' );
has 'domains' => ( is => 'rw' );

#------------------------------------------------------------------------------

# Initialise collections
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

# Get a mailbox by username and password
override 'get_user' => sub {
    my ($self, $username, $password) = @_;

    return $self->util->get_user($username, $password);
};

#------------------------------------------------------------------------------

# Check if the from address is valid
override 'can_user_send' => sub {
    my ($self, $session, $from) = @_;

    M3MTA::Log->debug("Checking if user is permitted to send from '$from'");

    # Get the mailbox
    my ($user, $domain) = split /@/, $from;
    my $mailbox = $self->util->get_mailbox($user, $domain);

    # No mailbox found
    if(!$mailbox) {
        # The 'from' address isn't local, so authentication doesn't matter
        M3MTA::Log->debug("Mailbox not found, from address isn't local");
        return $M3MTA::Server::Backend::SMTP::ACCEPTED;
    }

    # Local mailbox found
    if(ref($mailbox) =~ /::Alias$/) {
        # TODO add authentication to aliases for SMTP purposes
        M3MTA::Log->debug("Alias found, not permitted to send");
        return $M3MTA::Server::Backend::SMTP::REJECTED;
    }

    if($session->user && $session->user->username && $session->user->username eq $mailbox->username) {
        # user is authenticated against this mailbox
        M3MTA::Log->debug("Local mailbox found and user is authenticated");
        return $M3MTA::Server::Backend::SMTP::ACCEPTED;
    }

    # user is not authenticated against this mailbox
    M3MTA::Log->debug("Local mailbox found but user isn't authenticated against it");
    return $M3MTA::Server::Backend::SMTP::REJECTED;
};

#------------------------------------------------------------------------------

# Check if the to address is valid
override 'can_accept_mail' => sub {
    my ($self, $session, $to) = @_;

    my ($user, $domain) = split /@/, $to;
    M3MTA::Log->debug("Checking if server will accept messages addressed to '$user'\@'$domain'");
    M3MTA::Log->trace(Dumper $session->user) if $session->user;

    # Check for local delivery mailboxes
    my $mailbox = $self->util->get_mailbox($user, $domain);
    if( $mailbox ) {
        if(ref($mailbox) =~ /::Alias$/) {
            M3MTA::Log->debug("- Mailbox exists locally as alias");
            return $M3MTA::Server::Backend::SMTP::ACCEPTED;
        }

        if($mailbox->size->maximum && $mailbox->size->maximum <= $mailbox->size->current) {
            # not an rfc, this is server mailbox policy
            M3MTA::Log->debug("x Mailbox is over size limit");
            return $M3MTA::Server::Backend::SMTP::REJECTED_OVER_LIMIT; # means mailbox over limit
        }

        return $M3MTA::Server::Backend::SMTP::ACCEPTED;
    }

    # Check if the server is acting as an open relay
    if( $self->config->{relay}->{anon} ) {
        M3MTA::Log->debug("- Server is acting as open relay");
        return $M3MTA::Server::Backend::SMTP::ACCEPTED;
    }

    # Check if server allows all authenticated users to relay
    if( $session->user && $self->config->{relay}->{auth} ) {
        M3MTA::Log->debug("- User is authenticated and all authenticated users can relay");
        return $M3MTA::Server::Backend::SMTP::ACCEPTED;
    }

    # Check if this user can open relay
    if( $session->user && $session->user->{user}->relay ) {
        M3MTA::Log->debug("- User has remote relay rights");
        return $M3MTA::Server::Backend::SMTP::ACCEPTED;
    }

    # Check if we have the domain but not the user
    my $rdomain = $self->domains->find_one({ domain => $domain });
    if( $rdomain && $rdomain->{delivery} ne 'relay') {
        M3MTA::Log->debug("- Domain exists as local delivery but user doesn't exist and domain has no catch-all");
        return $M3MTA::Server::Backend::SMTP::REJECTED_LOCAL_USER_INVALID; # on this one we let the caller decide what response to give, e.g. so we can give a 
    }

    # Finally check if we have a relay domain
    if( $rdomain && $rdomain->{delivery} eq 'relay' ) {
        M3MTA::Log->debug("- Domain exists as 'relay'");
        return $M3MTA::Server::Backend::SMTP::ACCEPTED;
    }

    # None of the above
    M3MTA::Log->debug("x Mail not accepted for delivery");
    return $M3MTA::Server::Backend::SMTP::REJECTED;
};

#------------------------------------------------------------------------------

# Add a message to the queue
override 'queue_message' => sub {
    my ($self, $email) = @_;

    # TODO recheck size against mailbox if its local delivery
    # maybe store the delivery info on the $email object?
    # not an rfc thing at all, just a mailbox policy thing

    $email->created(DateTime->now);
    $email->delivery_time(DateTime->now);    
    my $result = $self->util->add_to_queue($email);

    my @res;
    my $id = $email->id;
    if(!$result) {
        @res = ("451", "$id message store failed, please retry later");
        M3MTA::Log->debug("Queue message failed for '$id'");
        M3MTA::Log->trace(Dumper $email);
    } else {
        @res = ("250", "$id message accepted for delivery");
        M3MTA::Log->debug("Queue message successful for '$id'");
        M3MTA::Log->trace(Dumper $email);
    }

    return wantarray ? @res : join ' ', @res;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;