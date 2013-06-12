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

	if(-e $self->pidfile) {
	    my $realpid = $self->read_pid_file;

	    my $existing = kill 0, $realpid;
	    die($self->name . " is already running") if $existing;

	    my $unlinked = unlink $self->pidfile;
	    die("pidfile '" . $self->pidfile . "'' found but process doesn't exist, pidfile delete failed") if !$unlinked;
	}

	# Start in daemon mode
	my $pid = 0;
	if($self->daemon) {
		#TODO?
	    #mkdir $self->pid_dir if !-d $self->pid_dir;

	    # Fork a child process
	    $pid = fork;
	    if(!defined $pid || $pid < 0) {
	        die("Failed to fork process");
	    }
	}

	# Exit this if we're the parent process
	$pid and exit;

	if($self->daemon) {
	    # Set our session ID
	    setsid;
	    $pid = fork;
	    exit 0 if $pid;
	    exit 1 if not defined $pid;

	    # chdir to / (its safe, and lets system unmount things)
	    chdir '/' or die $!;

	    # Set our umask
	    umask(0);
	}

	if($self->daemon) {
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

	if($self->pidfile) {
	    open my $fh, ">", $self->pidfile or die "Unable to write pidfile " . $self->pidfile;
	    print $fh $$;
	    close $fh;
	}

	$args{begin}->();
}

#------------------------------------------------------------------------------

sub stop {
	my ($self) = @_;

	if(-e $self->pidfile) {
        my $realpid = $self->read_pid_file;
        
        my $cnt = kill 9, $realpid;
        die("Failed to kill process $realpid") if !$cnt;

        my $unlinked = unlink $self->pidfile;
        die("Failed to delete pidfile " . $self->pidfile) if !$unlinked;

        exit 0;
    } else {
        die($self->pidfile . " not found");
    }
}

#------------------------------------------------------------------------------

sub read_pid_file {
	my ($self) = @_;

    open my $fh, "<", $self->pidfile or die "Unable to open pidfile " . $self->pidfile;
    my $realpid = <$fh>;
    close $fh;
    return $realpid;
}

#------------------------------------------------------------------------------

1;