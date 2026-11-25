#!/bin/sh
# Succeeds while the Web UI answers.
set -eu
host="${DSH_HOST:-$(hostname -i | awk '{print $1}')}"
exec curl -fsS --max-time 4 -o /dev/null "http://$host:${DSH_PORT:-3080}/"
