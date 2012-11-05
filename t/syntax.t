#!/bin/sh
echo "1..1"
basedir=`dirname $0`/..
($basedir/perl -c $basedir/bin/server.psgi && echo "ok 1") || echo "not ok 1"
