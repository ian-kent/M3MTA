package M3MTA::Transport::Path;

use Modern::Perl;
use Moose;

use overload
	'""' => sub {
		my ($self) = @_;
		return $self->to_json;
	};

#------------------------------------------------------------------------------

has 'relays' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );
has 'mailbox' => ( is => 'rw', isa => 'Str' );
has 'domain' => ( is => 'rw', isa => 'Str' );

#------------------------------------------------------------------------------

sub null {
	my ($self) = @_;

	return 1 if !$self->mailbox && !$self->domain;
	return 0;
}

sub postmaster {
	my ($self) = @_;

	return 1 if $self->mailbox =~ /postmaster/i;
	return 0;
}

#------------------------------------------------------------------------------

sub from_json {
	my ($self, $json) = @_;

	my $email = $json;
	my $relays = undef;
	my $mailbox = undef;
	my $domain = undef;
	if($json =~ /:/) {
		($relays, $email) = split /:/, $json, 2;
	}
	if($email =~ /@/) {
		($mailbox, $domain) = split /@/, $email, 2;
	}

	$self->relays(split /,/, $relays) if $relays;
	$self->mailbox($mailbox) if $mailbox;
	$self->domain($domain) if $domain;

	return $self;
}

#------------------------------------------------------------------------------

sub to_json {
	my ($self) = @_;

	my $relays = join ',', @{$self->relays};

	my $path = '';
	if($relays) {
		$path .= "$relays:";
	}

	if($self->mailbox) {
		$path .= $self->mailbox;
	}

	if($self->domain) {
		$path .= "\@" . $self->domain;
	}

	return $path;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;