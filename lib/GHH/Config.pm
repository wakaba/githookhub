package GHH::Config;
use strict;
use warnings;
use Path::Class;

$GHH::Config::RulesD = dir($ENV{GHH_RULES_D} || die "|GHH_RULES_D| not specified");

1;
