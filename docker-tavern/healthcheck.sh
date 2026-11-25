#!/bin/sh
# Succeeds while the tavern answers through the gate: the address is one that
# the tavern itself serves without a login, written down by the entrypoint.
set -eu
address=$(cat /run/dsh-tavern-docker/address 2>/dev/null) || exit 1
code=$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' -H 'Host: localhost' "$address") || exit 1
[ "$code" = 200 ]
