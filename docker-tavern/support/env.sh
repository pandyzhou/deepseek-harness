# The environment every command of the tavern runs with in the container.
# Sourced by the entrypoint and by the dsh-tavern command, so that a restart or
# an update started through either listens where it did before.
. /usr/local/lib/dsh-tavern-docker/paths.sh

# The port to publish is the gate's: the login page, which passes requests on
# to the tavern. Kept under names of their own, since the two that set them are
# read by the tavern's launcher as well, for which they are set anew below.
: "${TAVERN_GATE_PORT:=${DSH_TAVERN_PORT:-3081}}"
: "${TAVERN_GATE_BIND:=${DSH_TAVERN_BIND:-0.0.0.0}}"
case "$TAVERN_GATE_PORT" in
  '' | *[!0-9]*)
    echo "DSH_TAVERN_PORT 应当是一个端口号，现在是：$TAVERN_GATE_PORT" >&2
    exit 64
    ;;
esac
# The tavern itself listens inside the container only, behind the gate.
TAVERN_INNER_PORT=3080
[ "$TAVERN_GATE_PORT" != 3080 ] || TAVERN_INNER_PORT=3082
export TAVERN_GATE_PORT TAVERN_GATE_BIND TAVERN_INNER_PORT
export TAVERN_LOGIN_SECRET=/data/.login-secret
export TAVERN_LOGIN_LINK=/run/dsh-tavern-docker/login
export DSH_TAVERN_BIND=127.0.0.1
export DSH_TAVERN_PORT=$TAVERN_INNER_PORT

# A slow disk takes longer over the first start than the launcher waits.
export DSH_TAVERN_START_TIMEOUT="${DSH_TAVERN_START_TIMEOUT:-300}"
# There is no browser to open here.
export DSH_TAVERN_NO_OPEN=1
# The pnpm the install was made with, which the plugin pages of the service
# look for on the path.
case ":$PATH:" in
  *":$TAVERN_HOME/tools/bin:"*) ;;
  *) export PATH="$TAVERN_HOME/tools/bin:$PATH" ;;
esac

# The names the page is reached by, read by the row that the entrypoint adds
# to cordis.patch.yml.
DSH_TRUSTED_HOSTS=$(node /usr/local/lib/dsh-tavern-docker/trusted-hosts.mjs) || exit 64
export DSH_TRUSTED_HOSTS
