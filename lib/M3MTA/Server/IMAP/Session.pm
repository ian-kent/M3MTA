package M3MTA::Server::IMAP::Session;

use Modern::Perl;
use Moose;
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

has '_stash' => ( is => 'rw', isa => 'HashRef' );

sub stash {
    my $self = shift;

    $self->_stash({}) if !$self->_stash;

    return $self->_stash unless @_;

    return $self->_stash->{$_[0]} unless @_ > 1 || ref $_[0];

    my $values = ref $_[0] ? $_[0] : {@_};
    for my $key (keys %$values) {
        $self->_stash->{$key} = $values->{$key};
    }
}

#------------------------------------------------------------------------------

sub log {
	my $self = shift;

	my $message = shift;
	$message = '[SESSION %s] ' . $message;

	M3MTA::Log->debug($message, $self->id, @_);
}

sub trace {
    my $self = shift;

    my $message = shift;
    $message = '[SESSION %s] ' . $message;

    M3MTA::Log->trace($message, $self->id, @_);
}

sub error {
    my $self = shift;

    my $message = shift;
    $message = '[SESSION %s] ' . $message;

    M3MTA::Log->error($message, $self->id, @_);
}

#------------------------------------------------------------------------------

sub respond {
    my ($self, @cmd) = @_;

    my $c = join ' ', @cmd;
    $self->stream->write("$c\r\n");
    $self->trace("[SENT] %s", $c);
    return;
}

#------------------------------------------------------------------------------

sub begin {
    my ($self) = @_;

    my $capability = $self->imap->has_rfc('RFC3501.Any')->get_capability;
    $self->respond('* OK', "[$capability]", $self->imap->config->{hostname}, " " . $self->imap->ident);

    $self->stream->on(error => sub {
        my ($stream, $error) = @_;
        $self->error("Stream error: %s", $error);
    });
    $self->stream->on(close => sub {
        $self->error("Stream closed");
    });
    $self->stream->on(read => sub {
        my ($stream, $chunk) = @_;

        my @parts = split /\r\n/, $chunk;
        for my $part (@parts) {
            $self->buffer(($self->buffer ? $self->buffer : '') . $part . "\r\n");
            $self->receive if $self->buffer =~ /\r?\n$/m;
        }
    });
}

#------------------------------------------------------------------------------

sub receive {
	my ($self) = @_;

    $self->trace("[RECD] %s", $self->buffer);

    if($self->receive_hook) {
        return $self->receive_hook->($self);
    }

    # Only continue if we had an EOL
    my $buffer = $self->buffer;
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

__PACKAGE__->meta->make_immutable;