package M3MTA::Server::Backend::MongoDB::SMTP;

use Moose;
extends 'M3MTA::Server::Backend::SMTP', 'M3MTA::Server::Backend::MongoDB';

use Data::Uniqid qw/ luniqid /;
use MIME::Base64 qw/ decode_base64 encode_base64 /;
use Data::Dumper;

# Collections
has 'queue'     => ( is => 'rw' );
has 'mailboxes' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;

    # Get collections
    $self->queue(
    	$self->database->get_collection(
    		$self->config->{database}->{queue}->{collection}
    	)
    );
    $self->mailboxes(
    	$self->database->get_collection(
    		$self->config->{database}->{mailboxes}->{collection}
    	)
    );
}

#------------------------------------------------------------------------------

override 'get_user' => sub {
    my ($self, $username, $password) = @_;

    my $mailbox = $self->mailboxes->find_one({ username => $username, password => $password });
    $self->log("Trying to load mailbox for '$username' with password '$password': " . (ref($mailbox)));

    return $mailbox;
};

#------------------------------------------------------------------------------

override 'can_user_send' => sub {
    my ($self, $session, $from) = @_;

    my ($user, $domain) = split /@/, $from;
    $self->log("Checking if user is permitted to send from '%s'\@'%s'", $user, $domain);

    $self->log("Auth: %s", Dumper $session->user);

    # Get the mailbox
    my $mailbox = $self->mailboxes->find_one({ mailbox => $user, domain => $domain });
    $self->log("Mailbox: %s", Dumper $mailbox);

    if(!$mailbox) {
        # The 'from' address isn't local
        # TODO SPF sender checking etc
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
    $self->log("Checking if server will accept messages addressed to '$user'\@'$domain'");
    $self->log("- User: %s", Dumper $session->user) if $session->user;

    # Check if the server is acting as an open relay
    if( $self->config->{relay}->{anon} ) {
        $self->log("- Server is acting as open relay");
        return 1;
    }

    # Check if server allows all authenticated users to relay
    if( $session->user && $self->config->{relay}->{auth} ) {
        $self->log("- User is authenticated and all authenticated users can relay");
        return 1;
    }

    # Check if this user can open relay
    if( $session->user && $session->user->{user}->{relay} ) {
        $self->log("- User has remote relay rights");
        return 1;
    }

    # Check for local delivery mailboxes (may be an alias, but thats dealt with after queueing)
    my $mailbox = $self->mailboxes->find_one({ mailbox => $user, domain => $domain });
    if( $mailbox ) {
        $self->log("- Mailbox exists locally:");
        $self->log(Dumper $mailbox);
        return 1;
    }

    # Check if we have a catch-all mailbox (also may be an alias)
    my $catch = $self->mailboxes->find_one({ mailbox => '*', domain => $domain });
    if( $catch ) {
        $self->log("- Recipient caught by domain catch-all");
        return 1;
    }

    # Finally check if we have a relay domain
    my $rdomain = $self->domains->find_one({ domain => $domain, delivery => 'relay' });
    if( $rdomain ) {
        $self->log("- Domain exists as 'relay'");
        return 1;
    }

    # None of the above
    $self->log("x Mail not accepted for delivery");
    return 0;
};

#------------------------------------------------------------------------------

override 'queue_message' => sub {
    my ($self, $email) = @_;

    my $id = luniqid . "@" . $self->config->{hostname};
    $email->id($id);
    $email->date(DateTime->now);
    eval {
        $self->queue->insert($email->to_hash);
    };

    my @res;
    if($@) {
        @res = ("451", "$id message store failed, please retry later");
        $self->log("Queue message failed for '%s': %s\n%s", $id, $@, (Dumper $email));
    } else {
        @res = ("250", "$id message accepted for delivery");
        $self->log("Message queued for '%s':\n%s", $id, (Dumper $email));
    }

    return wantarray ? @res : join ' ', @res;
};

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;