package M3MTA::Server::Base;

#-------------------------------------------------------------------------------

use Modern::Perl;
use Moose;
use DateTime::Tiny;
use Mojolicious;
use Mojo::IOLoop;
use M3MTA::Log;

#-------------------------------------------------------------------------------

# Backend
has 'backend'       => ( is => 'rw' );

# RFC/Plugin hooks
has 'commands'      => ( is => 'rw' );
has 'states'        => ( is => 'rw' );
has 'hooks'         => ( is => 'rw' );
has 'rfcs'          => ( is => 'rw' );

# Server config
has 'config'    => ( is => 'rw' );
has 'ident'     => ( is => 'rw', default => sub { 'M3MTA' });

#-------------------------------------------------------------------------------

sub BUILD {
    my ($self) = @_;

    # Get backend from config
    my $backend = $self->config->{backend}->{handler};
    if(!$backend) {
        M3MTA::Log->fatal("No backend found in server configuration");
        die;
    }
    
    # Load it
    my $r = eval "require $backend";
    if(!$r) {
        M3MTA::Log->fatal("Unable to load backend %s: %s", $backend, $@);
        die;
    }

    # Instantiate it
    $self->backend($backend->new(server => $self, config => $self->config));
    M3MTA::Log->debug("Created backend $backend");
}

#-------------------------------------------------------------------------------

sub register_command {
    my ($self, $command, $callback) = @_;
	$self->commands({}) if !$self->commands;

    $command = [$command] if ref($command) ne 'ARRAY';    
    M3MTA::Log->debug("Registered callback for commands: %s", (join ', ', @$command));
    map { $self->commands->{$_} = $callback } @$command;
}

#-------------------------------------------------------------------------------

sub register_state {
    my ($self, $pattern, $callback) = @_;
    $self->states([]) if !$self->states;

    M3MTA::Log->debug("Registered callback for state '%s'", $pattern);
    push $self->states, [ $pattern, $callback ];
}

#-------------------------------------------------------------------------------

sub register_hook {
    my ($self, $hook, $callback) = @_;
    $self->hooks({}) if !$self->hooks;    
    $self->hooks->{$hook} = [] if !$self->hooks->{$hook};

    M3MTA::Log->debug("Registered callback for hook '%s'", $hook);
    push $self->hooks->{$hook}, $callback;
}

#-------------------------------------------------------------------------------

sub call_hook {
    my ($self, $hook, @args) = @_;
    
    my $result = 1;
    M3MTA::Log->debug("Calling hook '%s'", $hook);

    if($self->hooks && $self->hooks->{$hook}) {
        for my $h (@{$self->hooks->{$hook}}) {
            my $r = &{$h}(@args);
            $result = 0 if !$r;
            last if !$result;
        }
    }

    return $result;
}

#-------------------------------------------------------------------------------

sub register_rfc {
    my ($self, $rfc, $class) = @_;
    $self->rfcs({}) if !$self->rfcs;

    my ($package) = caller;
    M3MTA::Log->debug("Registered RFC '%s' with package '%s'", $rfc, $package);
    $self->rfcs->{$rfc} = $class;
}

#-------------------------------------------------------------------------------

sub unregister_rfc {
    my ($self, $rfc) = @_;
    return if !$self->rfcs;

    M3MTA::Log->debug("Unregistered RFC '%s'", $rfc);
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
        M3MTA::Log->info("Starting %s server on port %s", ref($self), $port);

        M3MTA::Log->debug("Using Mojolicious version " . $Mojolicious::VERSION);

        my $server;
        $server = Mojo::IOLoop->server({port => $port}, sub {
            $self->accept($server, @_);
        });
    }

    M3MTA::Log->debug("Starting Mojo::IOLoop");
    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

    return;
}

#-------------------------------------------------------------------------------

sub accept {
	die("Must be implemented by subclass");
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;