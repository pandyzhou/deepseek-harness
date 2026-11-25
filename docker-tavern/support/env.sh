# The environment every command of the tavern runs with in the container.
# Sourced by the entrypoint and by the dsh-tavern command, so that a restart or
# an update started through either listens at the same address as before.
. /usr/local/lib/dsh-tavern-docker/paths.sh

# One address of the container, its first by default: the service refuses to
# listen on every interface.
if [ -z "${DSH_TAVERN_BIND:-}" ]; then
  DSH_TAVERN_BIND=$(hostname -i 2>/dev/null | awk '{print $1}' || true)
fi
export DSH_TAVERN_BIND="${DSH_TAVERN_BIND:-127.0.0.1}"
export DSH_TAVERN_PORT="${DSH_TAVERN_PORT:-3081}"
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
