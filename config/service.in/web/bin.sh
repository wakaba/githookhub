#!/bin/sh
exec 2>&1
export KARASUMA_CONFIG_JSON=@@INSTANCECONFIG@@/@@INSTANCENAME@@.json
export KARASUMA_CONFIG_FILE_DIR_NAME=@@LOCAL@@/keys
export GHH_RULES_D=@@INSTANCECONFIG@@/rules

export WEBUA_DEBUG=`@@ROOT@@/perl @@ROOT@@/modules/karasuma-config/bin/get-json-config.pl env.WEBUA_DEBUG text`
export GHH_DEBUG=`@@ROOT@@/perl @@ROOT@@/modules/karasuma-config/bin/get-json-config.pl env.GHH_DEBUG text`
port=`@@ROOT@@/perl @@ROOT@@/modules/karasuma-config/bin/get-json-config.pl ghh.web.port text`

eval "exec setuidgid @@USER@@ @@ROOT@@/plackup $PLACK_COMMAND_LINE_ARGS \
    -p $port @@ROOT@@/bin/server.psgi"
