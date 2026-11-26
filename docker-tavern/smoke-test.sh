#!/usr/bin/env bash
# Runs the image the way it is deployed and checks what its README says.
#
#   smoke-test.sh <image> [<repository> <commit>]
#
# With a repository and a commit of dsh-tavern it also runs an update inside the
# container, to that same commit.
set -euo pipefail

image=$1
repository=${2:-}
commit=${3:-}

name=tavern-smoke
port=13081
base=http://127.0.0.1:$port
# The name the published port is reached by here, without a reverse proxy.
direct=127.0.0.1:$port
account=smoke
password='correct horse battery'
data=/tmp/tavern-smoke-data
home=$data/dsh-tavern
work=$(mktemp -d)
service='--profile tavern .*--port '
site=
session=
let_in=

step() { printf '\n=== %s\n' "$*"; }
# Into a file first: a reader that stops early would end `docker logs` with an
# error, which a pipeline here does not forgive.
logs() { docker logs "$name" > "$work/logs.txt" 2>&1 || true; }

fail() {
  printf '\nFAILED: %s\n' "$*" >&2
  docker ps -a --filter name=tavern-smoke >&2 || true
  logs
  tail -n 150 "$work/logs.txt" >&2 || true
  exit 1
}

# The status of a request; 000 when there is no answer.
code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@" || true; }

expect() {
  local what=$1 wanted=$2 got=$3
  printf '%-68s %s\n' "$what" "$got"
  case " $wanted " in *" $got "*) ;; *) fail "$what: expected $wanted, got $got" ;; esac
}

# Let in: the API answers about the route, which it does not have, as it does
# when reached directly, and neither "log in first" nor "not from this name".
expect_let_in() {
  local what=$1 got=$2
  printf '%-68s %s\n' "$what" "$got"
  case "$got" in 000 | 401 | 403) fail "$what: was refused with $got" ;; esac
  [ "$got" = "$let_in" ] || fail "$what: answered $got, but $let_in when reached directly"
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; }

# Waits until the tavern answers through the gate, at an address that it
# serves without a login; the container must keep running meanwhile.
wait_up() {
  local seconds=$1
  for _ in $(seq 1 "$seconds"); do
    running || fail "the container stopped: exit $(docker inspect -f '{{.State.ExitCode}}' "$name")"
    [ "$(code "$base/version")" != 200 ] || return 0
    sleep 1
  done
  fail "the tavern did not answer within $seconds seconds"
}

# The link of the tavern's own login, which changes whenever the service
# starts, as the entrypoint hands it to the gate.
link() { docker exec "$name" cat /run/dsh-tavern-docker/login 2> /dev/null || true; }

# Waits until the service has started anew: its link is another one.
wait_new() {
  local before=$1 now
  for _ in $(seq 1 120); do
    now=$(link)
    if [ -n "$now" ] && [ "$now" != "$before" ]; then
      return 0
    fi
    sleep 1
  done
  fail 'the service did not start anew'
}

# Tries to log in at the login page the way a browser does that reaches it
# under the given name, and answers the status.
login() {
  code -H "Host: $1" -D "$work/login-headers.txt" \
    --data-urlencode "username=${2:-$account}" --data-urlencode "password=${3:-$password}" "$base/_login"
}

# Logs in, and keeps the name and the cookie it is given in $site and $session.
# The cookie is read from the answer itself: one that is for HTTPS only is not
# kept by curl, which talks to the gate without the reverse proxy here.
logged_in() {
  local status
  status=$(login "$@")
  site=$1
  session=$(tr -d '\r' < "$work/login-headers.txt" | sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p')
  [ "$status" = 303 ] && [ -n "$session" ] || fail "the login under $1 answered $status"
}

# The last lines of what a command said, without any that show a link.
said() { grep -v 'token=' "$1" | tail -n "$2" || true; }

# The status of the page, and of a request for the API, under the name of the
# last login and with its cookie, as they arrive through a reverse proxy.
page() { code -H "Host: $site" -H "Cookie: $session" "$@" "$base/"; }
api() { code -H "Host: $site" -H "Cookie: $session" "$@" "$base/api/smoke-test-no-such-route"; }

# Whether the page loads the client code of a plugin, under the name of the
# last login: the page names the bundle of every plugin that the service has
# loaded. The stylesheet of the tavern names the layout for phones as well, so
# only the name of its bundle counts.
loads() {
  curl -s -m 15 -H "Host: $site" -H "Cookie: $session" -o "$work/now.html" "$base/" || true
  if grep -Eq "$1(/|%2F|\\\\/)client\\.js" "$work/now.html"; then echo loaded; else echo missing; fi
}

# The layout for phones that the image asks for, and the part of it that
# build-seed.sh switches off: it would write thinking levels into the model
# settings. The count of the call that does it, a slash, and the count of the
# mark of the fix.
layout_fix() {
  local file=$home/profiles/tavern/node_modules/dsh-web-mobile/lib/index.js
  echo "$(sudo grep -c 'installReasoningEffortDefaults(ctx);' "$file" || true)/$(sudo grep -c 'docker-tavern 2026-11-26' "$file" || true)"
}

count() {
  logs
  grep -c -- "$1" "$work/logs.txt" || true
}

cleanup() {
  docker rm -f tavern-smoke tavern-smoke-volume > /dev/null 2>&1 || true
  docker volume rm -f tavern-smoke-volume > /dev/null 2>&1 || true
  sudo rm -rf "$data" "$work"
}
trap cleanup EXIT

# Starts the container on the directory of the host, with the given password.
start_on_directory() {
  docker run -d --name "$name" --health-interval 5s --stop-timeout 30 \
    -p "127.0.0.1:$port:3081" \
    -e DSH_LOGIN_USER="$account" \
    -e DSH_LOGIN_PASSWORD="$1" \
    -e DSH_PUBLIC_URL=https://tavern.example.com/ \
    -e DSH_TRUSTED_HOSTS=second.example.com:8443 \
    -v "$data:/data" "$image" > /dev/null
}

docker image ls "$image" --format 'size of the image: {{.Size}}'
docker run --rm --entrypoint cat "$image" /opt/dsh-tavern/seed.json | tee "$work/seed.json"

step 'Without a password, or with settings that are not right, nothing starts'
refused() {
  local what=$1 names=$2
  shift 2
  if docker run --rm "$@" "$image" > "$work/refused.txt" 2>&1; then
    fail "started $what"
  fi
  printf '%-34s %s\n' "$what:" "$(tail -n 1 "$work/refused.txt")"
  grep -q "$names" "$work/refused.txt" || fail "the refusal $what does not name $names"
  ! grep -q '放进数据目录' "$work/refused.txt" || fail "unpacked before refusing $what"
}
refused 'without a password' DSH_LOGIN_PASSWORD
refused 'with a short password' DSH_LOGIN_PASSWORD -e DSH_LOGIN_PASSWORD=short
refused 'with an address that is not one' DSH_PUBLIC_URL -e DSH_LOGIN_PASSWORD="$password" -e DSH_PUBLIC_URL=tavern.example.com
refused 'with a port that is not one' DSH_TAVERN_PORT -e DSH_LOGIN_PASSWORD="$password" -e DSH_TAVERN_PORT=web

step 'First start, on an empty directory of the host that belongs to root'
sudo rm -rf "$data"
sudo mkdir -p "$data"
start_on_directory "$password"
began=$(date +%s)
wait_up 900
echo "up after $(($(date +%s) - began)) seconds"
logs
tail -n 30 "$work/logs.txt"
docker top "$name"
sudo du -sm "$data"
! grep -q 'token=' "$work/logs.txt" || fail 'the log shows the link of the tavern'

step 'Nobody gets in without the login; with it, the page is the tavern'
expect 'a browser without a login: the page' 302 "$(code -H 'Accept: text/html' -D "$work/headers.txt" "$base/")"
grep -qi '^location: /_login' "$work/headers.txt" || fail 'a browser without a login is not sent to the login page'
expect 'without a login: the API' 401 "$(code "$base/api/smoke-test-no-such-route")"
expect 'without a login: writing' 401 "$(code -X POST "$base/api/dsh-tavern/static-assets")"
expect 'without a login: what cards fetch' 200 "$(code "$base/version")"
expect 'the login page' 200 "$(code "$base/_login")"
curl -s -m 15 -o "$work/login.html" "$base/_login"
grep -q 'name="password"' "$work/login.html" || fail 'the login page has no field for the password'
expect 'a wrong password' 401 "$(login "$direct" "$account" 'not the password')"
expect 'another account' 401 "$(login "$direct" someone "$password")"
# The link of the tavern's own login, which the gate keeps to itself.
inside=$(link)
[ -n "$inside" ] || fail 'the gate was not handed the link of the tavern'
expect 'the link of the tavern, from outside' 302 "$(code -H 'Accept: text/html' -D "$work/headers.txt" "$base$inside")"
grep -qi '^location: /_login' "$work/headers.txt" || fail 'the link of the tavern leads somewhere from outside'
! grep -qi 'dsh-auth' "$work/headers.txt" || fail 'the link of the tavern is exchanged from outside'
expect 'the link of the tavern for a program, from outside' 401 "$(code "$base/connect${inside#/}")"
logged_in "$direct"
expect 'the page, logged in' 200 "$(page)"
curl -s -m 15 -H "Cookie: $session" -D "$work/headers.txt" -o "$work/page.html" "$base/"
grep -qi '<html' "$work/page.html" || fail 'the page is not HTML'
{ grep -o 'dsh-tavern[a-z-]*' "$work/page.html" | sort | uniq -c | sort -rn; } > "$work/mentions.txt" || true
head -n 6 "$work/mentions.txt"
[ -s "$work/mentions.txt" ] || fail 'the page does not load the tavern'
expect 'the layout for phones' loaded "$(loads dsh-web-mobile)"
expect 'the layout for phones of the desktop app, which collides with it' missing "$(loads dsh-pocket)"
expect 'calls that write thinking levels into the model settings / fixes' 0/1 "$(layout_fix)"
! grep -qi 'dsh-auth' "$work/headers.txt" "$work/login-headers.txt" || fail 'the cookie of the tavern reached the browser'
docker exec "$name" dsh-tavern status > "$work/status.txt" 2>&1 || {
  cat "$work/status.txt"
  fail 'dsh-tavern status failed'
}
head -n 1 "$work/status.txt"
who=$(docker exec "$name" sh -c 'ps -o user= -p "$(pgrep -o -f -- "$0")" | xargs' "$service")
expect 'the service runs as' node "$who"
listening=$(docker exec "$name" pgrep -a -f -- "$service")
grep -q -- '--host 127.0.0.1 ' <<< "$listening" || fail 'the tavern listens beyond the container itself'
expect 'the files belong to user' 1000 "$(sudo stat -c %u "$home/profiles/tavern/package.json")"
# Nothing that runs as node, the tavern and its agent among it, has the
# password: looked at as node, which sees the environment of its own processes
# (this shell and what it starts aside, which Docker gives the container's).
knowing=$(docker exec -u node "$name" sh -c '
  seen=0
  have=0
  for process in $(pgrep -u node); do
    [ "$process" != "$$" ] || continue
    [ "$(ps -o ppid= -p "$process" 2> /dev/null | tr -d " ")" != "$$" ] || continue
    [ -r "/proc/$process/environ" ] || continue
    seen=$((seen + 1))
    if tr "\0" "\n" < "/proc/$process/environ" | grep -q "^DSH_LOGIN_PASSWORD="; then have=$((have + 1)); fi
  done
  echo "$have of $seen"')
printf '%-68s %s\n' 'processes of node that have the password' "$knowing"
case "$knowing" in '0 of '[3-9]* | '0 of '[1-9][0-9]*) ;; *) fail "the password is in the environment of $knowing processes" ;; esac
expect 'the environment of the first process, which has it, read as node' closed \
  "$(docker exec -u node "$name" sh -c 'cat /proc/1/environ > /dev/null 2>&1 && echo open || echo closed')"

step 'Only the names given are let in, and a login holds for its name alone'
let_in=$(api)
expect_let_in 'the API, reached directly' "$let_in"
grep -qi '^set-cookie:.*HttpOnly' "$work/login-headers.txt" || fail 'the cookie of the login can be read by scripts'
! grep -qi '^set-cookie:.*Secure' "$work/login-headers.txt" || fail 'the cookie of a login over HTTP is for HTTPS only'
logged_in tavern.example.com
grep -qi '^set-cookie:.*Secure' "$work/login-headers.txt" || fail 'the cookie of a login under the HTTPS name is sent over HTTP as well'
expect 'the page under the public name' 200 "$(page)"
expect_let_in 'the public name' "$(api)"
expect_let_in 'the public name, from its own HTTPS page' "$(api -H 'Origin: https://tavern.example.com')"
expect 'the public name, from the page of another site' 403 "$(api -H 'Origin: https://evil.example.com')"
expect 'the public name, not logged in' 401 "$(code -H 'Host: tavern.example.com' "$base/api/smoke-test-no-such-route")"
expect 'the login of the public name, under another name' 401 "$(code -H 'Host: second.example.com:8443' -H "Cookie: $session" "$base/api/smoke-test-no-such-route")"
logged_in second.example.com:8443
expect_let_in 'a second name with its port' "$(api)"
logged_in second.example.com
expect 'the second name on another port' 403 "$(api)"
logged_in evil.example.com
expect 'a name that was not given' 403 "$(api)"

step 'The health check of the image'
health=starting
for _ in $(seq 1 30); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$name")
  [ "$health" != healthy ] || break
  sleep 2
done
expect 'health' healthy "$health"

step 'The page can keep a connection open, and has a Documents directory to start in'
# The opening of a WebSocket the way the page does it, and the status it gets.
open_socket() {
  rm -f "$work/headers.txt"
  curl -s -o /dev/null -m 3 --http1.1 -D "$work/headers.txt" -H "Host: $site" "$@" \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: c21va2UtdGVzdC1rZXkhIQ==' "$base/api/dsh-tavern/ws" || true
  head -n 1 "$work/headers.txt" | tr -d '\r' | cut -d ' ' -f 2
}
logged_in tavern.example.com
expect 'the opening of a WebSocket, logged in' 101 "$(open_socket -H "Cookie: $session" -H 'Origin: https://tavern.example.com')"
expect 'the opening of a WebSocket, not logged in' 401 "$(open_socket)"
expect 'the Documents directory that the page is given' /data/home/Documents \
  "$(docker exec -u node "$name" sh -c 'HOME=/data/home xdg-user-dir DOCUMENTS')"

step 'A restart keeps the data and the logins, and does not unpack again'
docker exec -u node "$name" sh -c 'mkdir -p /data/dsh-tavern/profile-data/tavern/smoke && echo kept > /data/dsh-tavern/profile-data/tavern/smoke/kept.txt'
logged_in tavern.example.com
before=$(link)
docker restart "$name" > /dev/null
wait_up 300
wait_new "$before"
expect 'times the install was unpacked' 1 "$(count '放进数据目录')"
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/smoke/kept.txt")"
expect 'the page, with the login from before the restart' 200 "$(page)"
expect_let_in 'the public name, with the login from before' "$(api)"

step 'Leftovers of a container that was killed do not keep the next from starting'
before=$(link)
docker kill "$name" > /dev/null
sudo mkdir -p "$home/.tavern-install.lock" "$home/apps/dsh-tavern.staging" "$home/logs"
printf '{"attemptId":"smoke","generation":"smoke","pid":7,"startedAt":%s000,"state":"running"}\n' "$(date +%s)" |
  sudo tee "$home/.tavern-install.lock/owner.json" > /dev/null
printf '{"pid":7,"port":3080,"bindHost":"127.0.0.1","profile":"tavern"}\n' |
  sudo tee "$home/logs/tavern.pid.json" > /dev/null
sudo chown -R 1000:1000 "$home/.tavern-install.lock" "$home/apps/dsh-tavern.staging" "$home/logs/tavern.pid.json"
docker start "$name" > /dev/null
wait_up 300
wait_new "$before"
[ ! -e "$home/.tavern-install.lock" ] || fail 'the lock of an install that no longer runs is still there'
[ ! -e "$home/apps/dsh-tavern.staging" ] || fail 'the half-prepared version is still there'

step 'A directory that another image filled keeps its tavern, and is told so once'
before=$(link)
docker stop "$name" > /dev/null
sudo sed -i 's/"commit":"[0-9a-f]*"/"commit":"0000000000000000000000000000000000000000"/' "$home/.docker-seed"
docker start "$name" > /dev/null
wait_up 300
wait_new "$before"
expect 'times the image said that it carries another version' 1 "$(count '这个镜像自带的酒馆是')"
expect 'times the install was unpacked' 1 "$(count '放进数据目录')"
expect 'the commit recorded for the directory' "$(jq -r .commit "$work/seed.json")" "$(sudo jq -r .commit "$home/.docker-seed")"

step 'The dsh-tavern command restarts the service, and the container stays'
before=$(link)
since=$(docker inspect -f '{{.State.StartedAt}}' "$name")
docker exec "$name" dsh-tavern restart > "$work/restart.txt" 2>&1 || {
  cat "$work/restart.txt"
  fail 'dsh-tavern restart failed'
}
said "$work/restart.txt" 6
wait_up 300
wait_new "$before"
expect 'the container was not restarted' "$since" "$(docker inspect -f '{{.State.StartedAt}}' "$name")"
listening=$(docker exec "$name" pgrep -a -f -- "$service")
grep -q -- '--host 127.0.0.1 ' <<< "$listening" || fail 'the tavern listens beyond the container itself after the restart'
expect 'the page, with the login from before the restart' 200 "$(page)"
expect_let_in 'the public name, after the restart' "$(api)"

if [ -n "$commit" ]; then
  step 'An update inside the container, as the page starts one'
  before=$(link)
  docker exec -u node "$name" sh -c \
    'git init -q --bare /tmp/pinned.git && git -C /tmp/pinned.git fetch -q --depth 1 "https://github.com/$0.git" "$1:refs/heads/main"' \
    "$repository" "$commit"
  began=$(date +%s)
  if ! docker exec -e DSH_TAVERN_GIT_URL=file:///tmp/pinned.git "$name" dsh-tavern update > "$work/update.txt" 2>&1; then
    said "$work/update.txt" 200
    fail 'the update failed'
  fi
  said "$work/update.txt" 12
  echo "updated in $(($(date +%s) - began)) seconds"
  wait_up 300
  wait_new "$before"
  expect 'the container was not restarted' "$since" "$(docker inspect -f '{{.State.StartedAt}}' "$name")"
  expect 'the installed commit' "$commit" "$(sudo jq -r .commit "$home/apps/dsh-tavern/.dsh-tavern-release.json")"
  expect 'the page, with the login from before the update' 200 "$(page)"
  expect_let_in 'the public name, after the update' "$(api)"
  expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/smoke/kept.txt")"
  # The update installs the tavern anew and reads the switch again.
  expect 'the layout for phones, after the update' loaded "$(loads dsh-web-mobile)"
fi

step 'When the service dies, the container ends, for Docker to start it again'
before=$(link)
docker exec "$name" pkill -KILL -f -- "$service"
expect 'exit code' 1 "$(timeout 90 docker wait "$name")"

step 'An update that was cut off after the switch is undone at the next start'
sudo cp -al "$home/apps/dsh-tavern" "$home/apps/dsh-tavern.previous"
printf '{"fresh":false,"moved":[]}\n' | sudo tee "$home/apps/dsh-tavern/.dsh-tavern-swap.json" > /dev/null
sudo chown 1000:1000 "$home/apps/dsh-tavern/.dsh-tavern-swap.json"
docker start "$name" > /dev/null
wait_up 300
wait_new "$before"
[ ! -e "$home/apps/dsh-tavern.previous" ] || fail 'the version from before the update was not put back'
[ ! -e "$home/apps/dsh-tavern/.dsh-tavern-swap.json" ] || fail 'the switch is still recorded as unfinished'
expect 'times an unfinished update was undone' 2 "$(count '上次更新没有做完')"

step 'Stopping ends the service and the container within the time Docker gives'
before=$(link)
began=$(date +%s)
docker stop "$name" > /dev/null
echo "stopped after $(($(date +%s) - began)) seconds"
expect 'exit code' 0 "$(docker inspect -f '{{.State.ExitCode}}' "$name")"
[ ! -e "$home/logs/tavern.pid.json" ] || fail 'the record of the running service is still there'

step 'Program files that are gone are put back at the start; the data stays'
sudo rm -rf "$home/runtime"
docker start "$name" > /dev/null
wait_up 900
expect 'times the install was unpacked' 2 "$(count '放进数据目录')"
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/smoke/kept.txt")"

step 'The repair command does the same on demand, and leaves the plugins as they are'
docker stop "$name" > /dev/null
echo broken | sudo tee "$home/apps/dsh-tavern/bin/dsh-tavern.mjs" > /dev/null
# STcontext is installed switched off. Switching it on removes its marker,
# which the seed carries: the repair must not bring the marker back.
off=$home/profile-data/tavern/data/plugins/dsh-tavern-STcontext/.tavern-disabled
sudo test -f "$off" || fail 'STcontext is no longer installed switched off: this check needs another plugin'
sudo rm "$off"
docker run --rm -v "$data:/data" "$image" repair
! sudo test -e "$off" || fail 'the repair switched off a plugin that was on'
docker start "$name" > /dev/null
wait_up 300
! sudo test -e "$off" || fail 'the start after the repair switched off a plugin that was on'
expect 'times the install was unpacked at a start' 2 "$(count '放进数据目录')"
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/smoke/kept.txt")"
expect 'the page, with the login from before all this' 200 "$(page)"
expect_let_in 'the public name, after the repair' "$(api)"
expect 'the layout for phones, after the repair' loaded "$(loads dsh-web-mobile)"
expect 'calls that write thinking levels / fixes, after the repair' 0/1 "$(layout_fix)"
expect 'times the image said that it carries another version' 1 "$(count '这个镜像自带的酒馆是')"
! grep -q 'token=' "$work/logs.txt" || fail 'the log shows the link of the tavern'
sudo du -sm "$data"

step 'Another password ends every login there is'
docker rm -f "$name" > /dev/null
start_on_directory 'another password altogether'
wait_up 300
expect 'the login made with the password before: the API' 401 "$(api)"
expect 'the password before' 401 "$(login tavern.example.com)"
logged_in tavern.example.com "$account" 'another password altogether'
expect 'the page, logged in with the new password' 200 "$(page)"
docker rm -f "$name" > /dev/null

step 'First start on a volume of Docker; wrong passwords in a row lock the login page'
name=tavern-smoke-volume
docker run -d --name "$name" -p "127.0.0.1:$port:3081" \
  -e DSH_LOGIN_PASSWORD="$password" -e DSH_PUBLIC_URL=https://tavern.example.com/ \
  -v tavern-smoke-volume:/data "$image" > /dev/null
wait_up 900
logged_in "$direct" tavern
expect 'the page, logged in with the account that is the default' 200 "$(page)"
for attempt in $(seq 1 10); do
  expect "wrong password $attempt" 401 "$(login "$direct" tavern 'guess after guess')"
done
expect 'one more wrong password' 429 "$(login "$direct" tavern 'guess after guess')"
expect 'the right password, while the page is locked' 429 "$(login "$direct" tavern "$password")"
expect 'the page, with the login from before the lock' 200 "$(page)"

printf '\nAll checks passed.\n'
