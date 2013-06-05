package M3MTA::Server::SMTP;

=head NAME
M3MTA::Server::SMTP - Mojo::IOLoop based SMTP server
=cut

use Mouse;
extends 'M3MTA::Server::Base';

use Data::Dumper;
use Data::Uniqid qw/ luniqid /;
use MIME::Base64 qw/ decode_base64 encode_base64 /;
use MongoDB::MongoClient;
use Try::Tiny;

use M3MTA::Server::SMTP::Session;
use M3MTA::Server::SMTP::RFC2821;
use M3MTA::Server::SMTP::RFC2554;
use M3MTA::Server::SMTP::RFC2487;

#------------------------------------------------------------------------------

# Database
has 'client'    => ( is => 'rw' );
has 'database'  => ( is => 'rw' );

# Collections
has 'queue'     => ( is => 'rw' );
has 'mailboxes' => ( is => 'rw' );

# Callbacks
has 'queued'      => ( is => 'rw' );
has 'user_auth'   => ( is => 'rw' );
has 'user_send'   => ( is => 'rw' );
has 'mail_accept' => ( is => 'rw' );

our %ReplyCodes = ();

# TODO should probably have this as a hook?
has 'helo'          => ( is => 'rw' );

#------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

    # Setup database
    $self->client(MongoDB::MongoClient->new);
    $self->database($self->client->get_database($self->config->{database}->{database}));

    # Get collections
    $self->queue($self->database->get_collection($self->config->{database}->{queue}->{collection}));
    $self->mailboxes($self->database->get_collection($self->config->{database}->{mailboxes}->{collection}));

    # Initialise RFCs
    M3MTA::Server::SMTP::RFC2821->new->register($self); # Basic SMTP
    M3MTA::Server::SMTP::RFC2554->new->register($self); # AUTH
    M3MTA::Server::SMTP::RFC2487->new->register($self); # STARTTLS
}

#------------------------------------------------------------------------------

# Handles new connections from M3MTA::Server::Base
sub accept {
    my ($self, $server, $loop, $stream, $id) = @_;

    $self->log("Session accepted with id %s", $id);

    my $session = new M3MTA::Server::SMTP::Session(
        smtp => $self, 
        stream => $stream,
        loop => $loop,
        id => $id,
        server => $loop->{acceptors}{$server},
    );

    $session->begin;

    return;
}

#------------------------------------------------------------------------------

sub register_replycode {
    my ($self, $name, $code) = @_;

    if(ref($name) =~ /HASH/) {
        for my $n (keys %$name) {
            $M3MTA::Server::SMTP::ReplyCodes{$n} = $name->{$n};
        }
    } else {
        $M3MTA::Server::SMTP::ReplyCodes{$name} = $code;
    }
}

#------------------------------------------------------------------------------

sub register_helo {
    my ($self, $callback) = @_;
    
    $self->helo([]) if !$self->helo;    
    push $self->helo, $callback;
}

#------------------------------------------------------------------------------
# Application callbacks, i.e. 'business logic'
#------------------------------------------------------------------------------

# Determines whether the MAIL FROM command should succeed
sub _user_send {
    my ($self, $session, $from) = @_;

    if($self->user_send) {
        try {
            return &{$self->user_send}($self, $session, $from);
        } catch {
            $self->log("Error in user_send callback - %s", $@);
            return 0;
        }
    }

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
}

#------------------------------------------------------------------------------

# Validate the username and password - undef if invalid, anything else if valid.
# Anything returned here is stored in $session->user->{user}
sub _user_auth {
    my ($self, $username, $password) = @_;

    if($self->user_auth) {
        return &{$self->user_auth}($self, $username, $password);
    }

    $self->log("Trying to load mailbox for '$username' with password '$password'");
    my $mailbox = $self->mailboxes->find_one({ username => $username, password => $password });
    $self->log(Dumper $mailbox);

    return $mailbox;
}

#------------------------------------------------------------------------------

# Decide whether the RCPT TO command should succeed
sub _mail_accept {
    my ($self, $session, $to) = @_;

    if($self->mail_accept) {
        return &{$self->mail_accept}($self, $session, $to);
    }

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
}

#------------------------------------------------------------------------------

# Handle a queued message (will be a M3MTA::Server::SMTP::Email object)
sub _queued {
    my ($self, $email) = @_;

    if($self->queued) {
        return &{$self->queued}($self, $email);
    }

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
}

#------------------------------------------------------------------------------

1;