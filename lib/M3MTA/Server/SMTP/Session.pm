package M3MTA::Server::SMTP::Session;

use Modern::Perl;
use Moose;

use Data::Dumper;
use M3MTA::Server::Models::Message;

#------------------------------------------------------------------------------

has 'smtp'   => ( is => 'rw' );
has 'stream' => ( is => 'rw' );
has 'ioloop' => ( is => 'rw' );
has 'id' 	 => ( is => 'rw' );
has 'server' => ( is => 'rw' );

has 'user'	 => ( is => 'rw' );
has 'buffer' => ( is => 'rw' );
has 'email'  => ( is => 'rw' );
has 'state'	 => ( is => 'rw' );

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
	return if !$self->smtp->debug;

	my $message = shift;
	$message = '[SESSION %s] ' . $message;

	$self->smtp->log($message, $self->id, @_);
}

#------------------------------------------------------------------------------

sub respond {
    my ($self, @cmd) = @_;

    my $c = join ' ', @cmd;

    $self->stream->write("$c\n");
    $self->log("[SENT] %s", $c);

    return;
}

#------------------------------------------------------------------------------

sub begin {
    my ($self, $args) = @_;

    my $settings = {
        send_welcome => 1,
        $args ? %$args : (),
    };
    $self->smtp->call_hook('accept', $self, $settings);

    if($settings->{send_welcome}) { 
        $self->respond($M3MTA::Server::SMTP::ReplyCodes{SERVICE_READY}, $self->smtp->config->{hostname}, $self->smtp->ident);
    }

    $self->buffer('');
    $self->email(M3MTA::Server::Models::Message->new);
    $self->state('ACCEPT');

    $self->stream->on(error => sub {
    	my ($stream, $error) = @_;
        $self->log("Stream error: %s", $error);
    });
    $self->stream->on(close => sub {
        $self->log("Stream closed");
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

	$self->log("[RECD] %s", $self->buffer);

    # Check if we have a state hook
    for my $ar (@{$self->smtp->states}) {
        if($self->state =~ $ar->[0]) {
            return &{$ar->[1]}($self);
        }
    }
    
    # Clear the buffer
    my $buffer = $self->buffer;
    $self->buffer('');

    # Get the command and data
    my ($cmd, $data) = $buffer =~ m/^(\w+)\s?(.*)\r\n$/s;
    $self->log("Got cmd[%s], data[%s]", $cmd, $data);

    # SMTP commands aren't case sensitive, we are!
    $cmd = uc $cmd;

    # Call the command hook
    my $result = {
        bad_command => 0,
        response => undef,
    };
    $self->smtp->call_hook('command', $self, $cmd, $data, $result);
    if($result->{response}) {
        # A hook provided a response
        $self->respond(@{$result->{response}});
        return;
    }

    # Check if command is registered by an RFC
    if(!$result->{bad_command}) {
        if($self->smtp->commands->{$cmd}) {
            return &{$self->smtp->commands->{$cmd}}($self, $data);
        }
    }

    # Respond with command not understood
    $self->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_NOT_UNDERSTOOD}, "Command not understood.");
}

#------------------------------------------------------------------------------

1;