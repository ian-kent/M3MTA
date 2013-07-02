package M3MTA::Chaos;

use Modern::Perl;

# TODO make configurable
our %monkeys = (
	'process_message_failure' 			=> 0,
	'dequeue_failure'		  			=> 0,
	'process_message_failure_requeue' 	=> 0,
	'process_message_held_failure'		=> 0,
	'local_delivery_failure'			=> 0,
);

#------------------------------------------------------------------------------

sub monkey {
	my ($self, $name) = @_;

	return if !$monkeys{$name};

	die("Chaos monkey $name!") if rand(100) < $monkeys{$name};

	return;
}

#------------------------------------------------------------------------------

1;