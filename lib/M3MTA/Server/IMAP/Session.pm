package M3MTA::Server::IMAP::Session;

use Modern::Perl;
use Mouse;
use Data::Dumper;

#------------------------------------------------------------------------------

has 'imap'   => ( is => 'rw' );
has 'stream' => ( is => 'rw' );
has 'ioloop' => ( is => 'rw' );
has 'id' 	 => ( is => 'rw' );
has 'server' => ( is => 'rw' );

# Current IMAP state (NotAuthenticated, Authenticated, Selected)
has 'state'    => ( is => 'rw' );
has 'selected' => ( is => 'rw' );
has 'buffer'   => ( is => 'rw' );
has 'receive_hook' => ( is => 'rw' );

# User authentication
has 'auth'     => ( is => 'rw' );
has 'authtype' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub log {
	my $self = shift;
	return if !$self->imap->debug;

	my $message = shift;
	$message = '[SESSION %s] ' . $message;

	$self->imap->log($message, $self->id, @_);
}

#------------------------------------------------------------------------------

sub respond {
    my ($self, @cmd) = @_;

    my $c = join ' ', @cmd;
    $self->stream->write("$c\r\n");
    $self->log("[SENT] %s", $c);
    return;
}

#------------------------------------------------------------------------------

sub begin {
    my ($self) = @_;

    my $capability = $self->imap->has_rfc('RFC3501.Any')->get_capability;
    $self->respond('* OK', "[$capability]", $self->imap->config->{hostname}, " " . $self->imap->ident);

    $self->stream->on(error => sub {
        my ($stream, $error) = @_;
        $self->log("Stream error: %s", $error);
    });
    $self->stream->on(close => sub {
        $self->log("Stream closed");
    });
    $self->stream->on(read => sub {
        my ($stream, $chunk) = @_;

        $self->buffer(($self->buffer ? $self->buffer : '') . $chunk);
        $self->receive if $self->buffer =~ /\n$/m;
    });
}

#------------------------------------------------------------------------------

sub receive {
	my ($self) = @_;

    $self->log("[RECD] %s", $self->buffer);

    if($self->receive_hook) {
        return $self->receive_hook->($self);
    }

    # Only continue if we had an EOL
    my $buffer = $self->buffer;
    return unless $buffer =~ /\n$/gs; #FIXME not necessary? done above
    $self->buffer('');

    # Get the id, command and any data
    my ($id, $cmd, $data) = $buffer =~ m/^([\w\d]+)\s*(\w+)\s?(.*)\r\n$/s;
    $self->log("Got id[%s], cmd[%s], data[%s]", $id, $cmd, $data);

    # See if we've got a command which can happen in any state
    return if &{$self->imap->get_state('Any')}($self, $id, $cmd, $data);

    if($self->state() =~ /^NotAuthenticated$/) {
        return if &{$self->imap->get_state('NotAuthenticated')}($self, $id, $cmd, $data);
    } else {
        # If we're authenticated or selected state, try authenticated first
        if($self->state() =~ /^(Authenticated|Selected)$/) {
            return if &{$self->imap->get_state('Authenticated')}($self, $id, $cmd, $data);
        }

        # If it didn't match authenticated state, and we're in selected state, try that next
        if ($self->state() =~ /^Selected$/) {
            return if &{$self->imap->get_state('Selected')}($self, $id, $cmd, $data);
        }
    }

    # Otherwise its a bad command
    $self->respond($id, 'BAD', "Command not understood.");

}

#------------------------------------------------------------------------------

1;