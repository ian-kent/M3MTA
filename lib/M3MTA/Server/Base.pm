package M3MTA::Server::Base;

#-------------------------------------------------------------------------------

use Modern::Perl;
use Moose;
use DateTime::Tiny;
use Mojolicious;
use Mojo::IOLoop;

#-------------------------------------------------------------------------------

# Backend
has 'backend'       => ( is => 'rw' );

# RFC/Plugin hooks
has 'commands'      => ( is => 'rw' );
has 'states'        => ( is => 'rw' );
has 'hooks'         => ( is => 'rw' );
has 'rfcs'          => ( is => 'rw' );

# Debug
has 'debug'         => ( is => 'rw', default => sub { $ENV{M3MTA_DEBUG} // 1 } );

# Server config
has 'config'    => ( is => 'rw' );
has 'ident'     => ( is => 'rw', default => sub { 'M3MTA' });

#-------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

    # Create backend
    my $backend = $self->config->{backend};
    if(!$backend) {
        die("No backend found in server configuration");
    }
    
    eval "require $backend" or die ("Unable to load backend $backend: $@");
    $self->backend($backend->new(server => $self, config => $self->config));
    $self->log("Created backend $backend");
}

#-------------------------------------------------------------------------------

sub log {
    my ($self, $message, @args) = @_;

    return 0 unless $self->debug;

    $message = sprintf("[%s] %s $message", ref($self), DateTime::Tiny->now, @args);
    print STDOUT "$message\n";

    return 1;
}

#-------------------------------------------------------------------------------

sub register_command {
    my ($self, $command, $callback) = @_;
	$self->commands({}) if !$self->commands;

    $command = [$command] if ref($command) ne 'ARRAY';    
    $self->log("Registered callback for commands: %s", (join ', ', @$command));
    map { $self->commands->{$_} = $callback } @$command;
}

#-------------------------------------------------------------------------------

sub register_state {
    my ($self, $pattern, $callback) = @_;
    $self->states([]) if !$self->states;

    $self->log("Registered callback for state '%s'", $pattern);
    push $self->states, [ $pattern, $callback ];
}

#-------------------------------------------------------------------------------

sub register_hook {
    my ($self, $hook, $callback) = @_;
    $self->hooks({}) if !$self->hooks;    
    $self->hooks->{$hook} = [] if !$self->hooks->{$hook};

    $self->log("Registered callback for hook '%s'", $hook);
    push $self->hooks->{$hook}, $callback;
}

#-------------------------------------------------------------------------------

sub call_hook {
    my ($self, $hook, @args) = @_;
    my $result = 1;
    if($self->hooks && $self->hooks->{$hook}) {
        for my $h (@{$self->hooks->{$hook}}) {
            my $r = &{$h}(@args);
            $result = 0 if !$r;
        }
    }
    return $result;
}

#-------------------------------------------------------------------------------

sub register_rfc {
    my ($self, $rfc, $class) = @_;
    $self->rfcs({}) if !$self->rfcs;

    my ($package) = caller;
    $self->log("Registered RFC '%s' with package '%s'", $rfc, $package);
    $self->rfcs->{$rfc} = $class;
}

#-------------------------------------------------------------------------------

sub unregister_rfc {
    my ($self, $rfc) = @_;    return if !$self->rfcs;

    $self->log("Unregistered RFC '%s'", $rfc);
    return delete $self->rfcs->{$rfc};
}

#-------------------------------------------------------------------------------

sub has_rfc {
    my ($self, $rfc) = @_;

    return 0 if !$self->rfcs;  
    return 0 if !$self->rfcs->{$rfc};
    return $self->rfcs->{$rfc};
}

#-------------------------------------------------------------------------------

sub start {
    my ($self) = @_;

    for my $port (@{$self->config->{ports}}) {
        $self->log("Starting %s server on port %s", ref($self), $port);

        $self->log("Using Mojolicious version " . $Mojolicious::VERSION);

        my $server;
        $server = Mojo::IOLoop->server({port => $port}, sub {
            $self->accept($server, @_);
        });
    }

    $self->log("Starting Mojo::IOLoop");
    Mojo::IOLoop->start;

    return;
}

#-------------------------------------------------------------------------------

sub accept {
	die("Must be implemented by subclass");
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;