package M3MTA::Server::Backend::MDA;

use Moose;
extends 'M3MTA::Server::Backend';

#------------------------------------------------------------------------------

sub local_delivery {
    my ($self, $user, $domain, $email) = @_;

    die("local_delivery not implemented by backend");
}

#------------------------------------------------------------------------------    

sub poll {
    my ($self, $count) = @_;

    die("poll not implemented by backend");
}

#------------------------------------------------------------------------------    

sub requeue {
	my ($self, $email) = @_;

	die("requeue not implemented by backend");
}

#------------------------------------------------------------------------------    

sub dequeue {
	my ($self, $email) = @_;

	die("dequeue not implemented by backend");
}

#------------------------------------------------------------------------------    

sub notify {
	my ($self, $to, $subject, $content) = @_;

	die("notify not implemented by backend");
}

#------------------------------------------------------------------------------    

__PACKAGE__->meta->make_immutable;