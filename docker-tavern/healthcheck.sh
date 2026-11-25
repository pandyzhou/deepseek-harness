#!/bin/sh
# Succeeds while the page answers at the address the entrypoint started it at.
# Without the login token it answers 401, which shows as well that it is up.
set -eu
address=$(cat /run/dsh-tavern-docker/address 2>/dev/null) || exit 1
code=$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' "$address") || exit 1
case "$code" in
  200 | 30? | 401) exit 0 ;;
  *) exit 1 ;;
esac
