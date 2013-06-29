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
	my $message = shift;
	$message = sprintf($message, @_) if @_;
	Log::Log4perl->get_logger(caller)->trace($message);
}

sub debug {
	shift;
	my $message = shift;
	$message = sprintf($message, @_) if @_;
	Log::Log4perl->get_logger(caller)->debug($message);
}

sub info {
	shift;
	my $message = shift;
	$message = sprintf($message, @_) if @_;
	Log::Log4perl->get_logger(caller)->info($message);
}

sub warn {
	shift;
	my $message = shift;
	$message = sprintf($message, @_) if @_;
	Log::Log4perl->get_logger(caller)->warn($message);
}

sub error {
	shift;
	my $message = shift;
	$message = sprintf($message, @_) if @_;
	Log::Log4perl->get_logger(caller)->error($message);
}

sub fatal {
	shift;
	my $message = shift;
	$message = sprintf($message, @_) if @_;
	Log::Log4perl->get_logger(caller)->fatal($message);
}

#------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;