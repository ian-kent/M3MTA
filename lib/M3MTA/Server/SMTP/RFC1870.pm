package M3MTA::Server::SMTP::RFC1870;

=head NAME

M3MTA::Server::SMTP::RFC1870 - SIZE extension

=head2 DESCRIPTION

RFC1870 implements the SIZE extension in SMTP.

It advertises the maximum message size in the EHLO response, and enforces
the maximum message size on the DATA command. It also provides an up-front
test on the RCPT command to reject messages which would take the user over-limit.

=head2 CONFIGURATION

The maximum message size is set in
    $config->{maximum_size}
and applies even if this RFC is disabled.

The broadcast option is set in 
    $config->{extensions}->{size}->{broadcast}
and determines whether the SIZE extension displays the maximum size in its 
EHLO response.

=cut

use Modern::Perl;
use Moose;

has 'helo' => ( is => 'rw', isa => 'Str' );

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

	# Register this RFC
    if(!$smtp->has_rfc('RFC5321')) {
        die "M3MTA::Server::SMTP::RFC1870 requires RFC5321";
    }
    $smtp->register_rfc('RFC1870', $self);

	# Add a list of commands to EHLO output
    $smtp->register_helo(sub {
        my ($session) = @_;
        return $self->helo;
    });

    # Build the helo response
    if($smtp->config->{extensions}->{size}->{broadcast}) {
        my $size = $smtp->config->{maximum_size} // "0";
        $self->helo("SIZE $size");
    } else {
        $self->helo("SIZE");
    }

    # Replace RFC5321's MAIL, RCPT and DATA commands
    $smtp->register_command('MAIL', sub {
        my ($session, $data) = @_;
        $self->mail($session, $data);
    });
    $smtp->register_command('RCPT', sub {
        my ($session, $data) = @_;
        $self->rcpt($session, $data);
    });
    # TODO capture DATA so we can do a final test of message size against stash size
    #$smtp->register_command('DATA', sub {
    #    my ($session, $data) = @_;
    #    $self->data($session, $data);
    #});
    # Register a state hook to capture data
    # TODO capture this too!
    #$smtp->register_state(qr/^DATA$/, sub {
    #    my ($session) = @_;
    #    $self->data($session);
    #});
}

#------------------------------------------------------------------------------

sub mail {
    my ($self, $session, $data) = @_;

    # TODO strip off SIZE=n
    if(my ($size) = $data =~ /SIZE=(\d+)/) {
        $data =~ s/\s*SIZE=\d+//;

        $session->log("Using MAIL from RFC1870, size provided [$size], remaining data [$data]");

        $session->stash(rfc1870_size => $size);

        my $max_size = $session->smtp->config->{maximum_size} // 0;
        unless ($max_size <= 0) {
            if($size > $max_size) {
                $session->respond($M3MTA::Server::SMTP::ReplyCodes{EXCEEDED_STORAGE_ALLOCATION}, "Maximum message size exceeded");
                $session->log("Rejected message as too big");
                return;
            }
        }
    }

    # TODO need to get base to handle chained rfc implementations
    return $session->smtp->has_rfc('RFC5321')->mail($session, $data);
}

#------------------------------------------------------------------------------

sub rcpt {
    my ($self, $session, $data) = @_;

    $session->log("Using RCPT from RFC1870 (SIZE)");

    if(!$session->stash('envelope') || !$session->stash('envelope')->from) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "send MAIL command first");
        return;
    }
    if(!$session->stash('envelope') || !!$session->stash('envelope')->data) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "DATA command already received");
        return;
    }
    if(my ($recipient) = $data =~ /^To:\s*<(.+)>$/i) {
        print "Checking size for $recipient\n";

        # if we have a local mailbox, we want to check if the current mailbox size
        # + the provided message size (in stash) will exceed the maximum mailbox size
        # so we can notify up-front on RCPT command
        # (not an RFC thing, a local policy thing - RFC lets us wait until after DATA)
        # 
        # a test to see if the user is already over limit is done by RFC5321
        # a test to prevent the user going over limit is done by queue_message in backend
    }
    
    return $session->smtp->has_rfc('RFC5321')->rcpt($session, $data);
}

#------------------------------------------------------------------------------

1;