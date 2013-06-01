package M3MTA::SMTP;

use Mojo::IOLoop;
use Modern::Perl;
use Mouse;
use Try::Tiny;
use Data::Dumper;
use DateTime::Tiny;
use MongoDB::MongoClient;
use Data::Uniqid qw/ luniqid /;
use MIME::Base64 qw/ decode_base64 encode_base64 /;

use M3MTA::SMTP::Session;

# Server config
has 'config'    => ( is => 'rw' );
has 'ident'     => ( is => 'rw', default => sub { 'M3MTA ESMTP'});

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

# Debug
has 'debug'       => ( is => 'rw', default => sub { $ENV{M3MTA_SMTP_DEBUG} // 1 } );

our %ReplyCodes = (
    SERVICE_READY                               => 220,
    SERVICE_CLOSING_TRANSMISSION_CHANNEL        => 221,

    REQUESTED_MAIL_ACTION_OK                    => 250,

    START_MAIL_INPUT                            => 354,

    COMMAND_NOT_UNDERSTOOD                      => 500,
    SYNTAX_ERROR_IN_PARAMETERS                  => 501,
    BAD_SEQUENCE_OF_COMMANDS                    => 503,
);

sub BUILD {
    my ($self) = @_;

    # Setup database
    $self->client(MongoDB::MongoClient->new);
    $self->database($self->client->get_database($self->config->{database}->{database}));

    # Get collections
    $self->queue($self->database->get_collection($self->config->{database}->{queue}->{collection}));
    $self->mailboxes($self->database->get_collection($self->config->{database}->{mailboxes}->{collection}));
}

sub log {
    my ($self, $message, @args) = @_;

    return if !$self->debug;

    $message = sprintf("%s $message", DateTime::Tiny->now, @args);
    print "$message\n";

    return;
}

sub start {
    my ($self) = @_;

    for my $port (@{$self->config->{ports}}) {
        $self->log("Starting M3MTA::SMTP server on port %s", $port);

        my $server = Mojo::IOLoop->server({port => $port}, sub {
    	    my ($loop, $stream, $id) = @_;

            $self->log("Session accepted with id %s", $id);

            my $session = new M3MTA::SMTP::Session(
                smtp => $self, 
                stream => $stream,
                loop => $loop,
                id => $id,
            );

            $session->accept;

            return;
        });
    }

    $self->log("Starting Mojo::IOLoop");
    Mojo::IOLoop->start;

    return;
}

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

sub _user_auth {
    my ($self, $username, $password) = @_;

    if($self->user_auth) {
        return &{$self->user_auth}($self, $username, $password);
    }

    print "Trying to load mailbox for '$username' with password '$password'\n";
    my $mailbox = $self->mailboxes->find_one({ username => $username, password => $password });
    print Dumper $mailbox;

    return $mailbox;
}

sub _mail_accept {
    my ($self, $session, $to) = @_;

    if($self->mail_accept) {
        return &{$self->mail_accept}($self, $session, $to);
    }

    my ($user, $domain) = split /@/, $to;
    print "Checking if server will accept messages addressed to '$user'\@'$domain'\n";
    print ("- User:\n", Dumper $session->user) if $session->user;

    # Check if the server is acting as an open relay
    if( $self->config->{relay}->{anon} ) {
        print "- Server is acting as open relay\n";
        return 1;
    }

    # Check if server allows all authenticated users to relay
    if( $session->user && $self->config->{relay}->{auth} ) {
        print "- User is authenticated and all authenticated users can relay\n";
        return 1;
    }

    # Check if this user can open relay
    if( $session->user && $session->user->{user}->{relay} ) {
        print "- User has remote relay rights\n";
        return 1;
    }

    # Check for local delivery mailboxes (may be an alias, but thats dealt with after queueing)
    my $mailbox = $self->mailboxes->find_one({ mailbox => $user, domain => $domain });
    if( $mailbox ) {
        print "- Mailbox exists locally:\n";
        print Dumper $mailbox;
        return 1;
    }

    # Check if we have a catch-all mailbox (also may be an alias)
    my $catch = $self->mailboxes->find_one({ mailbox => '*', domain => $domain });
    if( $catch ) {
        print "- Recipient caught by domain catch-all\n";
        return 1;
    }

    # Finally check if we have a relay domain
    my $rdomain = $self->domains->find_one({ domain => $domain, delivery => 'relay' });
    if( $rdomain ) {
        print "- Domain exists as 'relay'\n";
        return 1;
    }

    # None of the above
    print "x Mail not accepted for delivery\n";
    return 0;
}

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
        print "Queue message failed for '$id'\n";
    } else {
        @res = ("250", "$id message accepted for delivery");
        print "Message queued for '$id'\n";
    }
    print Dumper $email;
    return wantarray ? @res : join ' ', @res;
}

1;