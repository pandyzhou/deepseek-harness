#!/bin/bash
# Keeps DSH Tavern running in the container.
#
#   (no argument)    unpack the install into /data when it is not there, start
#                    the service, and stay for as long as it runs
#   repair           put the program files of this image back into /data and
#                    exit; cards, chats, settings and keys stay as they are
#   <anything else>  a command of dsh-tavern, such as `status`
#
# Environment:
#   DSH_PUBLIC_URL     the address the page is reached at through the reverse
#                      proxy, e.g. "https://tavern.example.com/". Its name is
#                      trusted, and the login link is printed with it.
#   DSH_TRUSTED_HOSTS  further names the page is reached by, separated by spaces
#   DSH_TAVERN_PORT    the port to listen on; 3081 by default
#   DSH_TAVERN_BIND    the address to listen on; one address of the container,
#                      its first by default (the service refuses 0.0.0.0)
set -euo pipefail

lib=/usr/local/lib/dsh-tavern-docker
run=/run/dsh-tavern-docker

if [ "$(id -u)" -eq 0 ]; then
  # A directory mounted from the host belongs to root at first.
  install -d -o node -g node /data "$run"
  for dir in /data/dsh-tavern /data/home; do
    if [ -e "$dir" ] && [ "$(stat -c %U "$dir")" != node ]; then
      chown -R node:node /data
      break
    fi
  done
  exec setpriv --reuid node --regid node --init-groups /usr/local/bin/docker-entrypoint.sh "$@"
fi

. "$lib/env.sh"

launcher=$TAVERN_APP/bin/dsh-tavern.mjs
marker=$TAVERN_HOME/.docker-seed
patch=$TAVERN_HOME/cordis.patch.yml
log=$TAVERN_HOME/logs/tavern.log
# How they show in the process table: the service itself, and whatever is
# installing, updating or restarting it.
service='--profile tavern .*--port '
busy='bin/dsh-tavern\.mjs|dsh-tavern-install|dsh-tavern-update-'

say() { printf '%s\n' "$*"; }
seed() { jq -r ".$1" "$SEED_INFO"; }

installed() {
  [ -f "$marker" ] && [ -f "$launcher" ] && [ -x "$TAVERN_HOME/runtime/bin/dsh" ] \
    && [ -f "$TAVERN_HOME/profiles/tavern/package.json" ]
}

# Puts the program files of the image into /data. What the installer puts
# there and an update replaces is removed first, so that no file of another
# version stays among them. Everything else is the user's and is kept, since
# a file that is there already is not overwritten: cards and chats in
# profile-data, settings.yaml, the keys, and the model settings in the
# profile's cordis.patch.yml.
unpack() {
  local need free
  rm -rf "$marker" "$TAVERN_HOME/apps" "$TAVERN_HOME/runtime" "$TAVERN_HOME"/runtime.install-* \
    "$TAVERN_HOME/tools" "$TAVERN_HOME/source-cache" "$HOME/.local/share/pnpm"
  if [ -d "$TAVERN_HOME/profiles/tavern" ]; then
    find "$TAVERN_HOME/profiles/tavern" -mindepth 1 -maxdepth 1 ! -name 'cordis.patch.yml*' -exec rm -rf {} +
  fi
  need=$(($(seed kilobytes) + 200000))
  free=$(df -Pk /data | awk 'NR == 2 { print $4 }')
  if [ "$free" -lt "$need" ]; then
    say "数据目录所在的磁盘空间不够：需要约 $((need / 1024)) MB，只剩 $((free / 1024)) MB。" >&2
    exit 1
  fi
  zstd -dc "$SEED" | tar -x --skip-old-files -C /data -f -
  cp "$SEED_INFO" "$marker"
}

# A reverse proxy passes the name of the site on in the Host header, and the
# service answers 403 to a name it was not told about. The launcher has no
# option for more names, but the service reads this file of the home, after the
# profile's own, and the row below adds the names in DSH_TRUSTED_HOSTS to the
# ones the launcher passes.
trust_row() {
  cat <<'EOF'
# docker: trusted hosts. Written by the entrypoint of the image; keep this row.
- id: connection
  inject: [webStartup]
  config:
    trustedHosts: !!js '[...(process.env.DSH_TRUSTED_HOSTS || "").split(" ").filter(Boolean), ...ctx.webStartup.trustedHosts]'
EOF
}

ensure_trust_row() {
  local content
  content=$(grep -vE '^[[:space:]]*(#.*)?$' "$patch" 2>/dev/null || true)
  if [ -z "$content" ] || [ "$(printf '%s' "$content" | tr -d '[:space:]')" = '[]' ]; then
    trust_row > "$patch"
  elif grep -qF '# docker: trusted hosts' "$patch"; then
    :
  elif grep -qE '^-[[:space:]]+id:[[:space:]]+connection[[:space:]]*$' <<< "$content"; then
    say "提示：$patch 里已经有 connection 一行，反向代理用的域名请在那一行里维护。" >&2
  elif [[ ${content%%$'\n'*} == '- '* ]]; then
    # A list written one row after the other, which a further row continues.
    { printf '\n'; trust_row; } >> "$patch"
  else
    say "提示：$patch 的写法无法自动追加，反向代理用的域名没有生效。" >&2
  fi
}

# The last address the service printed, with its login token.
printed_url() {
  grep -a '^dsh web: ' "$log" 2>/dev/null | tail -n 1 | cut -d ' ' -f 3 || true
}

announce() {
  local url=$1 rest
  rest=${url#*://}
  rest=${rest#*/}
  if [ -n "${DSH_PUBLIC_URL:-}" ]; then
    say "登录链接（等同于密码，不要外传）：${DSH_PUBLIC_URL%/}/$rest"
  else
    say '登录时把上面地址里的 http://IP:端口 换成你访问用的地址，?token= 后面是登录令牌。'
  fi
}

stop_service() {
  local first
  first=$(pgrep -o -f -- "$service" || true)
  [ -n "$first" ] || return 0
  # The oldest is the one the launcher started.
  kill -TERM "$first" 2>/dev/null || true
  for _ in $(seq 1 80); do
    pgrep -f -- "$service" > /dev/null || break
    sleep 0.1
  done
  pkill -KILL -f -- "$service" 2>/dev/null || true
  rm -f "$TAVERN_HOME/logs/tavern.pid.json"
}

case "${1:-}" in
  '') ;;
  repair)
    if pgrep -f -- "$service" > /dev/null; then
      say '酒馆正在运行。请先停掉容器，再用 docker run --rm 挂上同一个数据目录执行 repair。' >&2
      exit 1
    fi
    unpack
    say "已把镜像自带的酒馆 $(seed version) 放回数据目录，人物卡、聊天、设置和密钥都没有动。"
    exit 0
    ;;
  *) exec dsh-tavern "$@" ;;
esac

# Nothing of the tavern runs when a container starts. Whatever says otherwise
# was left by the container before, and a process id recorded there may by now
# be another process here.
rm -f "$TAVERN_HOME/logs/tavern.pid.json" "$run/address"
rm -rf "$TAVERN_HOME/.tavern-install.lock"

# An update that the container before was stopped in the middle of: the
# installer's own tool puts back the version from before it.
if [ -e "$TAVERN_APP.previous" ] || [ -e "$TAVERN_APP.staging" ] || [ -e "$TAVERN_APP/.dsh-tavern-swap.json" ]; then
  for stager in "$TAVERN_APP" "$TAVERN_APP.previous"; do
    stager=$stager/bin/staged-app-install.mjs
    [ -f "$stager" ] || continue
    say '上次更新没有做完，正在恢复到更新前的版本……'
    node "$stager" rollback --app "$TAVERN_APP" || true
    break
  done
fi

if ! installed; then
  say "正在把酒馆 $(seed version) 放进数据目录（约 $(($(seed kilobytes) / 1024)) MB），需要一两分钟……"
  unpack
fi
if [ "$(seed commit)" != "$(jq -r .commit "$marker")" ]; then
  # Said once for each image; the tavern in /data updates itself.
  say "提示：这个镜像自带的酒馆是 $(seed version)，数据目录里沿用原来装好的那一份。要更新请用酒馆页面里的“检查更新”；想换成镜像自带的，停掉容器后执行 repair。"
  cp "$SEED_INFO" "$marker"
fi
ensure_trust_row

mkdir -p "$TAVERN_HOME/logs"
touch "$log"
tail -n 0 -F "$log" 2> /dev/null &
tail_pid=$!
start_pid=

on_stop() {
  trap - TERM INT
  say '正在停止酒馆……'
  [ -z "$start_pid" ] || kill "$start_pid" 2> /dev/null || true
  stop_service
  kill "$tail_pid" 2> /dev/null || true
  exit 0
}
trap on_stop TERM INT

# In the background, so that a signal to stop does not wait for it.
node "$launcher" start &
start_pid=$!
if ! wait "$start_pid"; then
  say '酒馆没能启动，原因见上面的日志。程序文件损坏时，可以停掉容器后用 repair 命令放回镜像自带的版本。' >&2
  stop_service
  kill "$tail_pid" 2> /dev/null || true
  exit 1
fi
start_pid=

case "$DSH_TAVERN_BIND" in
  *:*) say "http://[$DSH_TAVERN_BIND]:$DSH_TAVERN_PORT/" > "$run/address" ;;
  *) say "http://$DSH_TAVERN_BIND:$DSH_TAVERN_PORT/" > "$run/address" ;;
esac
announced=$(printed_url)
[ -z "$announced" ] || announce "$announced"

# The service is started detached by the launcher, and an update from inside
# the page stops it and starts another. So this stays while it runs or while
# something is at work on it, and ends, and the container with it, once it
# has been gone for a while with nothing at work.
current=$(pgrep -o -f -- "$service" || true)
missing=0
unannounced=0
while :; do
  sleep 3 &
  wait $! || true
  now=$(pgrep -o -f -- "$service" || true)
  if [ -n "$now" ]; then
    missing=0
    if [ "$now" != "$current" ]; then
      # Started again, with another login token, printed once it listens.
      current=$now
      unannounced=100
    fi
    if [ "$unannounced" -gt 0 ]; then
      unannounced=$((unannounced - 1))
      url=$(printed_url)
      if [ -n "$url" ] && [ "$url" != "$announced" ]; then
        unannounced=0
        announced=$url
        announce "$url"
      fi
    fi
  elif pgrep -f -- "$busy" > /dev/null; then
    missing=0
  else
    missing=$((missing + 1))
    if [ "$missing" -ge 5 ]; then
      say '酒馆的服务已经退出，容器随之退出。' >&2
      kill "$tail_pid" 2> /dev/null || true
      exit 1
    fi
  fi
done
