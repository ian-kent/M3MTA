package M3MTA::Server::Backend::MDA;

use Moose;
extends 'M3MTA::Server::Backend';

use M3MTA::Log;

#------------------------------------------------------------------------------

sub local_delivery {
    my ($self, $user, $domain, $email) = @_;

    M3MTA::Log->fatal("local_delivery not implemented by backend");
    die;
}

#------------------------------------------------------------------------------    

sub poll {
    my ($self) = @_;

    M3MTA::Log->fatal("poll not implemented by backend");
    die;
}

#------------------------------------------------------------------------------    

sub requeue {
	my ($self, $email) = @_;

	M3MTA::Log->fatal("requeue not implemented by backend");
	die;
}

#------------------------------------------------------------------------------    

sub dequeue {
	my ($self, $email) = @_;

	M3MTA::Log->fatal("dequeue not implemented by backend");
	die;
}

#------------------------------------------------------------------------------    

sub notify {
	my ($self, $message) = @_;

	M3MTA::Log->fatal("notify not implemented by backend");
	die;
}

#------------------------------------------------------------------------------    

sub get_postmaster {
	my ($self, $domain) = @_;

	M3MTA::Log->fatal("get_postmaster not implemented by backend");
	die;
}

#------------------------------------------------------------------------------    

__PACKAGE__->meta->make_immutable;