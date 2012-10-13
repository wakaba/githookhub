all:

# ------ Setup ------

WGET = wget
GIT = git
PERL = ./perl
PROVE = ./prove

deps: git-submodules pmbp-install

git-submodules:
	$(GIT) submodule update --init

local/bin/pmbp.pl: 
	mkdir -p local/bin
	$(WGET) -O $@ https://github.com/wakaba/perl-setupenv/raw/master/bin/pmbp.pl

pmbp-upgrade: local/bin/pmbp.pl
	perl local/bin/pmbp.pl --update-pmbp-pl

pmbp-update: pmbp-upgrade
	perl local/bin/pmbp.pl --update

pmbp-install: pmbp-upgrade
	perl local/bin/pmbp.pl --install

# ------ Tests ------

test: test-deps test-main

test-deps: deps

test-main:
	$(PROVE) t/*.t
