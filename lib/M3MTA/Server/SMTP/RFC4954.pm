package M3MTA::Server::SMTP::RFC4954;

=head NAME
M3MTA::Server::SMTP::RFC4954 - AUTH extension
=cut

use Modern::Perl;
use Moose;

use M3MTA::Log;

use M3MTA::Server::SMTP::RFC4954::PLAIN;
use M3MTA::Server::SMTP::RFC4954::LOGIN;

use MIME::Base64 qw/ decode_base64 encode_base64 /;

has 'mechanisms' => ( is => 'rw', isa => 'HashRef', default => sub { {} } );

#------------------------------------------------------------------------------

sub register {
	my ($self, $smtp) = @_;

    # Register this RFC
    if(!$smtp->has_rfc('RFC5321')) {
        die "M3MTA::Server::SMTP::RFC4954 requires RFC5321";
    }
    $smtp->register_rfc('RFC4954', $self);

    # Register known mechanisms
    $self->mechanisms->{PLAIN} = M3MTA::Server::SMTP::RFC4954::PLAIN->new(rfc => $self);
    $self->mechanisms->{LOGIN} = M3MTA::Server::SMTP::RFC4954::LOGIN->new(rfc => $self);

    # Add some reply codes
    $smtp->register_replycode({
        AUTHENTICATION_SUCCESSFUL  => 235,

        SERVER_CHALLENGE           => 334,

        PASSWORD_TRANSITION_NEEDED => 432,

        TEMPORARY_FAILURE          => 454,

        AUTHENTICATION_FAILED     => 535,

        AUTHENTICATION_REQUIRED    => 530,
        AUTHENTICATION_TOO_WEAK    => 534,
        ENCRYPTION_REQUIRED        => 538,
    });

	# Register the AUTH command
	$smtp->register_command(['AUTH'], sub {
        my ($session, $data) = @_;
		$self->auth($session, $data);
	});

    # Register a state hook to capture data
    $smtp->register_state('AUTHENTICATE', sub {
        my ($session) = @_;
        $self->authenticate($session);
    });

    # Add a list of commands to EHLO output
    $smtp->register_helo(sub {
        $self->helo(@_);
    });

    # TODO replace MAIL command to support AUTH=<mailbox> parameter
}

#------------------------------------------------------------------------------

sub helo {
    my $self = shift;
    
    my $mechanisms = '';
    for my $mech (keys %{$self->mechanisms}) {
        my $helo = $self->mechanisms->{$mech}->helo(@_);
        if($helo) {
            $mechanisms .= ' ' if $mechanisms;
            $mechanisms .= $helo;
        }
    }

    return "AUTH $mechanisms";
}

#------------------------------------------------------------------------------

sub auth {
	my ($self, $session, $data) = @_;

    if($session->user) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{BAD_SEQUENCE_OF_COMMANDS}, "Error: already authenticated");
        return;
    }

    if(!$data) {
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{SYNTAX_ERROR_IN_PARAMETERS}, "Syntax: AUTH mechanism");
        return;
    }

    my ($mechanism, $args) = $data =~ /^(\w+)\s?(.*)?$/;
    $session->log("Got mechanism [$mechanism] with args [$args]");

    if(!$self->mechanisms->{$mechanism}) {
        $session->log("Mechanism $mechanism not registered");
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{COMMAND_PARAMETER_NOT_IMPLEMENTED}, "Error: authentication failed: no mechanism available");
        return;
    }

    $session->log("Mechanism $mechanism found, calling inital_response");
    $session->stash(rfc4954_mechanism => $mechanism);
    $self->mechanisms->{$mechanism}->initial_response($session, $args);
}

#------------------------------------------------------------------------------

sub authenticate {
    my ($self, $session) = @_;

    my $buffer = $session->buffer;
    $buffer =~ s/\r?\n$//s;
    $session->buffer('');

    if($buffer eq '*') {
        $session->log("Client cancelled authentication with *");
        $session->respond($M3MTA::Server::SMTP::ReplyCodes{SYNTAX_ERROR_IN_PARAMETERS}, "Error: authentication failed: client cancelled authentication");
    }

    my $mechanism = $session->stash('rfc4954_mechanism');
    $session->log("Calling data for mechanism $mechanism");
    $self->mechanisms->{$mechanism}->data($session, $buffer);
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;