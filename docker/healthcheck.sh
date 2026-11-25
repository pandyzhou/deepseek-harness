#!/bin/sh
# Succeeds while the Web UI answers. Without the login token it answers 401,
# which shows as well that it is up.
set -eu
host="${DSH_HOST:-$(hostname -i | awk '{print $1}')}"
code="$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' "http://$host:${DSH_PORT:-3080}/")"
[ "$code" = 200 ] || [ "$code" = 401 ]
