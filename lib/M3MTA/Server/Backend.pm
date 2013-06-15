package M3MTA::Server::Backend;

use Moose;

# Config
has 'config' => ( is => 'rw', isa => 'HashRef', required => 1 );
has 'server' => ( is => 'rw', isa => 'M3MTA::Server::Base', required => 1 );

#------------------------------------------------------------------------------

sub log {
	my $self = shift;
	return if !$self->server->debug;

	my $message = shift;
	$message = '[BACKEND] ' . $message;

	$self->server->log($message, @_);
}

#------------------------------------------------------------------------------

sub BUILD {
	my ($self) = @_;
}

#------------------------------------------------------------------------------
__PACKAGE__->meta->make_immutable;