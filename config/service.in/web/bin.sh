#!/bin/sh
exec 2>&1
export KARASUMA_CONFIG_JSON=@@INSTANCECONFIG@@/@@INSTANCENAME@@.json
export KARASUMA_CONFIG_FILE_DIR_NAME=@@LOCAL@@/keys

export WEBUA_DEBUG=`@@ROOT@@/perl @@ROOT@@/modules/karasuma-config/bin/get-json-config.pl env.WEBUA_DEBUG text`
port=`@@ROOT@@/perl @@ROOT@@/modules/karasuma-config/bin/get-json-config.pl ghh.web.port text`

exec setuidgid @@USER@@ @@ROOT@@/plackup $PLACK_COMMAND_LINE_ARGS \
    -p $port @@ROOT@@/bin/server.psgi
