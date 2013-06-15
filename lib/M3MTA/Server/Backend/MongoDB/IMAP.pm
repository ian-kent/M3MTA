package M3MTA::Server::Backend::MongoDB::IMAP;

use Moose;

has 'backend' => ( is => 'rw', isa => 'M3MTA::Server::Backend::MongoDB', required => 1);
has 'config' => ( is => 'rw', isa => 'HashRef', required => 1 );

#------------------------------------------------------------------------------



#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;