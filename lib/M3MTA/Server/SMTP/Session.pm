package M3MTA::Server::SMTP::Session;

use Modern::Perl;
use Mouse;
use Data::Dumper;

use M3MTA::Server::SMTP::Email;

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
    my ($self) = @_;

    my $settings = {
        send_welcome => 1,
    };
    $self->smtp->call_hook('accept', $self, $settings);

    if($settings->{send_welcome}) { 
        $self->respond($M3MTA::Server::SMTP::ReplyCodes{SERVICE_READY}, $self->smtp->config->{hostname}, $self->smtp->ident);
    }

    $self->buffer('');
    $self->email(new M3MTA::Server::SMTP::Email);
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

        $self->buffer(($self->buffer ? $self->buffer : '') . $chunk);
        $self->receive if $self->buffer =~ /\r?\n$/m;
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
    
    # Only continue if we had an EOL
    my $buffer = $self->buffer;
    return unless $buffer =~ /\r\n$/gs;
    $self->buffer('');

    # Get the command and data
    my ($cmd, $data) = $buffer =~ m/^(\w+)\s?(.*)\r\n$/s;
    $self->log("Got cmd[%s], data[%s]", $cmd, $data);

    # Call the command hook, and exit if we get a negative response
    my $result = $self->smtp->call_hook('command', $self, $cmd, $data);
    return if !$result;

    # Check if command is registered by an RFC
    if($self->smtp->commands->{$cmd}) {
        return &{$self->smtp->commands->{$cmd}}($self, $data);
    }

    # Respond with command not understood
    $self->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_NOT_UNDERSTOOD}, "Command not understood.");
}

#------------------------------------------------------------------------------

1;