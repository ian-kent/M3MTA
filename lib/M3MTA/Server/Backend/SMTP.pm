package M3MTA::Server::Backend::SMTP;

use Moose;
extends 'M3MTA::Server::Backend';

use Readonly;
Readonly our $REJECTED => 0;
Readonly our $ACCEPTED => 1;
Readonly our $REJECTED_LOCAL_USER_INVALID => 2;
Readonly our $REJECTED_OVER_LIMIT => 3;

Readonly our $SUCCESSFUL => 1;
Readonly our $TEMPORARY_FAILURE => -2;

#------------------------------------------------------------------------------

sub get_user {
    my ($self, $username, $password) = @_;

    die("get_user not implemented by backend");
}

#------------------------------------------------------------------------------    

sub can_user_send {
    my ($self, $session, $from) = @_;

    die("can_user_send not implemented by backend");
}

#------------------------------------------------------------------------------

sub can_accept_mail {
    my ($self, $session, $to) = @_;

    die("can_accept_mail not implemented by backend");
}

#------------------------------------------------------------------------------

sub queue_message {
    my ($self, $email) = @_;

    die("queue_message not implemented by backend");
}

#------------------------------------------------------------------------------    

__PACKAGE__->meta->make_immutable;