package M3MTA::Storage::Mailbox;

use Modern::Perl;
use Moose;

has 'domain' => ( is => 'rw', isa => 'Str' );
has 'mailbox' => ( is => 'rw', isa => 'Str' );
has 'username' => ( is => 'rw', isa => 'Str'  );
has 'password' => ( is => 'rw', isa => 'Str'  );

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	$self->domain($json->{domain});
	$self->mailbox($json->{mailbox});
	$self->username($json->{username} // '');
	$self->password($json->{password} // '');

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	return {
		domain => $self->domain,
		mailbox => $self->mailbox,
		username => $self->username,
		password => $self->password,
	};
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;