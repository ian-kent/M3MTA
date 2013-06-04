package M3MTA::SMTP::Session;

use Modern::Perl;
use Mouse;
use Data::Dumper;

use M3MTA::SMTP::Email;

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
	$message = '[SESSION] ' . $message;

	$self->smtp->log($message, @_);
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

sub accept {
    my ($self) = @_;

    # TODO should probably have an API for preventing welcome
    my $settings = {
        send_welcome => 1,
    };
    $self->smtp->call_hook('accept', $self, $settings);

    if($settings->{send_welcome}) { 
        $self->respond($M3MTA::SMTP::ReplyCodes{SERVICE_READY}, $self->smtp->config->{hostname}, $self->smtp->ident);
    }

    $self->buffer('');
    $self->email(new M3MTA::SMTP::Email);
    $self->state('ACCEPT');

    $self->stream->on(error => sub {
    	my ($stream, $error) = @_;
        $self->log("Stream error: %s", $error);
    });
    $self->stream->on(close => sub {
        $self->log("Stream closed");
        # TODO also should probably have an API
        if((my $rfc = $self->smtp->has_rfc('RFC2487')) && $self->{tls_enabled}) {
            my $handle = $rfc->{handles}->{$self->id};
            delete $rfc->{handles}->{$handle};
            delete $rfc->{handles}->{$self->id};
        }
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

    # Call the receive hook, and exit if we get a negative response
    my $result = $self->smtp->call_hook('receive', $self, $cmd, $data);
    return if !$result;

    # Check if command is registered by an RFC
    if($self->smtp->commands->{$cmd}) {
        return &{$self->smtp->commands->{$cmd}}($self, $data);
    }

    # Respond with command not understood
    $self->respond($M3MTA::SMTP::ReplyCodes{COMMAND_NOT_UNDERSTOOD}, "Command not understood.");
}

#------------------------------------------------------------------------------

1;