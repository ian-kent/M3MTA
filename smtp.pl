#!/usr/local/bin/perl

use Modern::Perl;
use Config::Any;
use M3MTA::SMTP;

my $config = Config::Any->load_files({ files => ['config.json'], use_ext => 1 })->[0]->{'config.json'}->{smtp};
M3MTA::SMTP->new(config => $config)->start;