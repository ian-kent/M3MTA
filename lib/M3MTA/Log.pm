package M3MTA::Log;

use Modern::Perl;
use Moose;
use Log::Log4perl qw/ :easy /;

my $conf = q(
	log4perl.rootLogger = DEBUG, Console

	log4perl.appender.Console 		 = Log::Log4perl::Appender::Screen
	log4perl.appender.Console.layout = Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Console.layout.ConversionPattern = [%c: %p] %d %m%n
);

Log::Log4perl::init(\$conf);

#------------------------------------------------------------------------------

sub trace {
	shift;
	Log::Log4perl->get_logger(caller)->trace(@_);
}

sub debug {
	shift;
	Log::Log4perl->get_logger(caller)->debug(@_);
}

sub info {
	shift;
	Log::Log4perl->get_logger(caller)->info(@_);
}

sub warn {
	shift;
	Log::Log4perl->get_logger(caller)->warn(@_);
}

sub error {
	shift;
	Log::Log4perl->get_logger(caller)->error(@_);
}

sub fatal {
	shift;
	Log::Log4perl->get_logger(caller)->fatal(@_);
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;