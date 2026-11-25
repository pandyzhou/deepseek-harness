#!/bin/sh
# Starts the Web UI of dsh, or runs dsh with the arguments given.
#
#   DSH_HOST           the address to listen on; one address of the container,
#                      its first by default (dsh refuses 0.0.0.0)
#   DSH_PORT           the port to listen on; 3080 by default
#   DSH_TRUSTED_HOSTS  the names the Web UI is reached by through the reverse
#                      proxy, separated by spaces, e.g. "dsh.example.com"
#   DSH_PUBLIC_URL     the address the Web UI is reached at, e.g.
#                      "https://dsh.example.com/"
set -eu

# Directories mounted from the host belong to root at first.
if [ "$(id -u)" -eq 0 ]; then
  install -d -m 0700 -o node -g node /data/dsh /data/dsh/home
  install -d -m 0750 -o node -g node /workspace
fi

if [ "$#" -gt 0 ]; then
  exec dsh "$@"
fi

host="${DSH_HOST:-$(hostname -i | awk '{print $1}')}"
port="${DSH_PORT:-3080}"

set -- web --no-open --host "$host" --port "$port"
if [ -n "${DSH_PUBLIC_URL:-}" ]; then
  set -- "$@" --public-url "$DSH_PUBLIC_URL"
fi
# Unquoted on purpose: one argument for each name.
# shellcheck disable=SC2086
set -- "$@" --trusted-host "$host:$port" ${DSH_TRUSTED_HOSTS:-}

exec dsh "$@"
