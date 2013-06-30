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

The RCPT check is set in
    $config->{extensions}->{size}->{rcpt_check}
When enabled, recipients are rejected up-front if delivery would cause the
mailbox to exceed its maximum size.

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

    # Policy thing not RFC, but check if size is ok for recipient    
    if($smtp->config->{extensions}->{size}->{rcpt_check}) {
        $smtp->register_command('RCPT', sub {
            my ($session, $data) = @_;
            $self->rcpt($session, $data);
        });
    }

    # Enforcing DATA maximum size against stashed size is optional
    if($smtp->config->{extensions}->{size}->{enforce}) {
        # Capture DATA state hook so we can do a final test of message size against stash size
        $smtp->register_state('DATA', sub {
            my ($session, $data) = @_;
            $self->data($session, $data);
        });
        # Create a new state to sink data more efficiently
        $smtp->register_state('DATA_RFC1870', sub {
            my ($session, $data) = @_;
            $self->data($session, $data);
        });
    }
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

    return $session->smtp->has_rfc('RFC5321')->mail($session, $data);
}

#------------------------------------------------------------------------------

sub rcpt {
    my ($self, $session, $data) = @_;

    $session->log("Using RCPT from RFC1870 (SIZE)");

    # We need to re-check these here, otherwise we accidentally give
    # an EXCEEDED_STORAGE_ALLOCATION error before a MAIL command
    if(!$session->stash('envelope') || !$session->stash('envelope')->from) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "send MAIL command first");
        return;
    }
    if(!$session->stash('envelope') || !!$session->stash('envelope')->data) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "DATA command already received");
        return;
    }
    if(my ($recipient) = $data =~ /^To:\s*<(.+)>$/i) {
        $session->log("Checking size for $recipient");
        my ($u, $d) = $recipient =~ /(.*)@(.*)/;
        my $mailbox = $session->smtp->get_mailbox($u, $d);
        if($mailbox && !$mailbox->size->ok($session->stash('rfc1870_size'))) {
            $session->respond($M3MTA::Server::SMTP::ReplyCodes{EXCEEDED_STORAGE_ALLOCATION}, "Maximum message size exceeded");
            return;
        }
    }
    
    return $session->smtp->has_rfc('RFC5321')->rcpt($session, $data);
}

#------------------------------------------------------------------------------

sub data {
    my ($self, $session, $data) = @_;

    # If no size was given in MAIL command, do nothing
    if($session->stash('rfc1870_size')) {
        # Capture the new state to sink data
        if($session->state eq 'DATA_RFC1870') {
            $session->error("DATA_RFC1870 state");
            $session->stash->{'data'} .= $session->buffer;
            $session->buffer('');

            # Once we get end of data, respond with failure
            if($session->stash('data') =~ /.*\r\n\.\r\n$/s) {
                $session->respond($M3MTA::Server::SMTP::ReplyCodes{EXCEEDED_STORAGE_ALLOCATION}, "Maximum message size exceeded");
                $session->state('ERROR');
                return;
            }

            # Otherwise sink
            return;
        }

        # Test the length against the final message
        # otherwise the . gets counted and causes the size to always exceed
        my $d = $session->stash('data') . $session->buffer;
        $d =~ s/\r\n\.\r\n$//s;
        my $len = length($d);
        my $max = $session->stash('rfc1870_size');

        if($len > $max) {
            # Don't bother calling RFC5321, we'll just wait until the end
            # of the DATA input and return an error 552
            $session->error("Message length [$len] exceeds declared size [$max]");

            # Store data
            $session->stash->{'data'} .= $session->buffer;
            $session->buffer('');

            # Handle end of message here, we may have exceeded by only a few bytes
            if($session->stash('data') =~ /.*\r\n\.\r\n$/s) {
                $session->respond($M3MTA::Server::SMTP::ReplyCodes{EXCEEDED_STORAGE_ALLOCATION}, "Maximum message size exceeded");
                $session->state('ERROR');
                return;
            }

            # Otherwise, set new state to sink data
            $session->state('DATA_RFC1870');

            return;
        }
    }

    # Finally let RFC5321 have it
    return $session->smtp->has_rfc('RFC5321')->data($session, $data);
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;