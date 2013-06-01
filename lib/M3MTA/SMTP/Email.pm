package M3MTA::SMTP::Email;

use Mouse;

has 'id'	=> ( is => 'rw' );
has 'date'	=> ( is => 'rw' );
has 'helo' 	=> ( is => 'rw' );
has 'to' 	=> ( is => 'rw' );
has 'data' 	=> ( is => 'rw' );
has 'from'	=> ( is => 'rw' );

sub to_hash {
	my ($self) = @_;

	my $obj = {};
	for my $key ('id', 'date', 'helo', 'to', 'data', 'from') {
		$obj->{$key} = $self->$key;
	}

	return $obj;
}

1;