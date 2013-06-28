package M3MTA::Server::Backend;

use Moose;
use M3MTA::Log;

# Config
has 'config' => ( is => 'rw', isa => 'HashRef', required => 1 );
has 'server' => ( is => 'rw', required => 1 ); # normally isa => 'M3MTA::Server::Base', but not for MDA

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;