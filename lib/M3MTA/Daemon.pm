package M3MTA::Daemon;

use Moose;

use POSIX qw/ setsid /;
use Cwd qw/ chdir /;
use IO::Handle;

has 'name' => ( is => 'rw' );
has 'pidfile' => ( is => 'rw', required => 1 );
has 'daemon' => ( is => 'rw', default => sub { 1 } );
has 'stdout' => ( is => 'rw' );
has 'stderr' => ( is => 'rw' );

#------------------------------------------------------------------------------

sub start {
	my ($self, %args) = @_;

	if($self->daemon) {
		# Exit or clean up pid file
		$self->check_pid;

		# Fork
		my $pid = $self->fork;

		# Exit this if we're the parent process
		$pid and exit;

	    # Set our session ID
	    setsid;

	    # Fork again
	    $pid = $self->fork;
	    exit 0 if $pid;

	    # chdir to / (its safe, and lets system unmount things)
	    chdir '/' or die $!;

	    # Set our umask
	    umask(0);

	    $self->set_filehandles;

	    # Write a new pidfile
	    $self->write_pidfile;
	}

	die("No begin callback") if !$args{begin};
	$args{begin}->();
}

#------------------------------------------------------------------------------

sub stop {
	my ($self) = @_;

	if(-e $self->pidfile) {
        $self->kill_processes;
        exit 0;
    } else {
        die($self->pidfile . " not found");
    }
}

#------------------------------------------------------------------------------

sub check_pid {
	my ($self) = @_;

	if(-e $self->pidfile) {
	    my $realpid = $self->read_pidfile;

	    my $existing = kill 0, $realpid;
	    die($self->name . " is already running") if $existing;

	    my $unlinked = unlink $self->pidfile;
	    die("pidfile '" . $self->pidfile . "'' found but process doesn't exist, pidfile delete failed") if !$unlinked;
	}
}

#------------------------------------------------------------------------------

sub read_pidfile {
	my ($self) = @_;

    open my $fh, "<", $self->pidfile or die "Unable to open pidfile " . $self->pidfile;
    my $realpid = <$fh>;
    close $fh;
    return $realpid;
}

#------------------------------------------------------------------------------

sub write_pidfile {
	my ($self) = @_;

	if($self->pidfile) {
	    open my $fh, ">", $self->pidfile or die "Unable to write pidfile " . $self->pidfile;
	    print $fh $$;
	    close $fh;
	}
}

#------------------------------------------------------------------------------

sub fork {
	my ($self) = @_;

	my $pid = fork;
    if(!defined $pid || $pid < 0) {
        die("Failed to fork process");
    }

    return $pid;
}

#------------------------------------------------------------------------------

sub set_filehandles {
	my ($self) = @_;

	# Close unwanted filehandles
    close *STDIN;
    close *STDERR;
    close *STDOUT;

	open STDIN, '<', '/dev/null' or die "Unable to open STDIN to /dev/null: $!";
    
    if($self->stdout) {
		open STDOUT, '>>', $self->stdout or die "Unable to open STDOUT to log file '" . $self->stdout . "': $!";
    } else {
    	open STDOUT, '<', '/dev/null' or die "Unable to open STDOUT to /dev/null: $!";
    }

    if($self->stderr) {
    	open STDERR, '>>', $self->stderr or die "Unable to open STDERR to log file '" . $self->stderr . "': $!";
    } else {
        open STDERR, '<', '/dev/null' or die "Unable to open STDERR to /dev/null: $!";
    }

    *STDOUT->autoflush;
    *STDERR->autoflush;
}

#------------------------------------------------------------------------------

sub kill_processes {
	my ($self) = @_;

	my $realpid = $self->read_pidfile;
        
    my $cnt = kill 9, $realpid;
    die("Failed to kill process $realpid") if !$cnt;

    my $unlinked = unlink $self->pidfile;
    die("Failed to delete pidfile " . $self->pidfile) if !$unlinked;
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;