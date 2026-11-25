#!/usr/bin/env bash
# Runs the image the way it is deployed and checks what its README says.
#
#   smoke-test.sh <image> [<repository> <commit>]
#
# With a repository and a commit of dsh-tavern it also runs an update inside the
# container, to that same commit. With SMOKE_PICTURES naming a directory, it
# leaves a picture of the first screen there (see first-screen.cjs).
set -euo pipefail

image=$1
repository=${2:-}
commit=${3:-}

name=tavern-smoke
port=13081
base=http://127.0.0.1:$port
# The name the published port is reached by here, without a reverse proxy.
direct=127.0.0.1:$port
# The login helper's port, and the reverse proxy that is put in front of both.
login_port=13082
proxy_site=https://tavern.example.com
proxy_user=smoke
proxy_password='correct horse'
data=/tmp/tavern-smoke-data
home=$data/dsh-tavern
work=$(mktemp -d)
service='--profile tavern .*--port '
site=
session=
let_in=

step() { printf '\n=== %s\n' "$*"; }
hide() { sed -E 's/(token=)[A-Za-z0-9._~%-]+/\1<hidden>/g'; }
# Into a file first: a reader that stops early would end `docker logs` with an
# error, which a pipeline here does not forgive.
logs() { docker logs "$name" > "$work/logs.txt" 2>&1 || true; }

fail() {
  printf '\nFAILED: %s\n' "$*" >&2
  docker ps -a --filter name=tavern-smoke >&2 || true
  logs
  hide < "$work/logs.txt" | tail -n 150 >&2 || true
  exit 1
}

# The status of a request; 000 when there is no answer.
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" || true; }

running() { [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ]; }

# Waits until the page answers; the container must keep running meanwhile.
wait_up() {
  local seconds=$1 status
  for _ in $(seq 1 $((seconds / 2))); do
    running || fail "the container stopped: exit $(docker inspect -f '{{.State.ExitCode}}' "$name")"
    status=$(code "$base/")
    case "$status" in 200 | 401) return 0 ;; esac
    sleep 2
  done
  fail "the page did not answer within $seconds seconds"
}

# The login token the service printed last.
token() {
  logs
  sed -n 's/^dsh web: .*[?&]token=\([^&[:space:]]*\).*/\1/p' "$work/logs.txt" | tail -n 1
}

# Waits for a login token other than the one given, and for its link to have
# been printed with the public address. Leaves it in $fresh.
wait_token() {
  local before=$1
  for _ in $(seq 1 60); do
    fresh=$(token)
    if [ -n "$fresh" ] && [ "$fresh" != "$before" ] \
      && grep -qF "https://tavern.example.com/?token=$fresh" "$work/logs.txt"; then
      return 0
    fi
    sleep 2
  done
  fail 'no new login link was printed'
}

# Logs in with a token the way a browser does that reaches the page under the
# given name, and keeps the cookie it is given, in $session. The service makes
# the cookie out to that name and takes it from requests for that name only.
login() {
  local status
  site=$1
  rm -f "$work/jar"
  status=$(code -H "Host: $site" -c "$work/jar" "$base/?token=$2")
  case "$status" in 200 | 30?) ;; *) fail "the login link answered $status for $site" ;; esac
  session=$(awk -F '\t' '($1 !~ /^#/ || $1 ~ /^#HttpOnly_/) && NF >= 7 { printf "%s%s=%s", sep, $6, $7; sep = "; " }' "$work/jar")
  [ -n "$session" ] || fail "the login link left no cookie for $site"
}

# The status of the page, and of a request for the API, under the name of the
# last login and with its cookie, as they arrive through a reverse proxy.
page() { code -H "Host: $site" -H "Cookie: $session" "$@" "$base/"; }
api() { code -H "Host: $site" -H "Cookie: $session" "$@" "$base/api/smoke-test-no-such-route"; }

expect() {
  local what=$1 wanted=$2 got=$3
  printf '%-64s %s\n' "$what" "$got"
  case " $wanted " in *" $got "*) ;; *) fail "$what: expected $wanted, got $got" ;; esac
}

# Let in: the API answers about the route, which it does not have, as it does
# when reached directly, and neither "log in first" nor "not from this name".
expect_let_in() {
  local what=$1 got=$2
  printf '%-64s %s\n' "$what" "$got"
  case "$got" in 000 | 401 | 403) fail "$what: was refused with $got" ;; esac
  [ "$got" = "$let_in" ] || fail "$what: answered $got, but $let_in when reached directly"
}

count() {
  logs
  grep -c -- "$1" "$work/logs.txt" || true
}

cleanup() {
  docker rm -f tavern-smoke tavern-smoke-volume tavern-smoke-proxy > /dev/null 2>&1 || true
  docker volume rm -f tavern-smoke-volume > /dev/null 2>&1 || true
  sudo rm -rf "$data" "$work"
}
trap cleanup EXIT

docker image ls "$image" --format 'size of the image: {{.Size}}'
docker run --rm --entrypoint cat "$image" /opt/dsh-tavern/seed.json | tee "$work/seed.json"

step 'An address that is not one is refused before anything is unpacked'
if docker run --rm -e DSH_PUBLIC_URL=tavern.example.com "$image" > "$work/refused.txt" 2>&1; then
  fail 'started with a DSH_PUBLIC_URL that is not an address'
fi
cat "$work/refused.txt"
grep -q 'DSH_PUBLIC_URL' "$work/refused.txt" || fail 'the refusal does not name DSH_PUBLIC_URL'
if docker run --rm -e DSH_TAVERN_LOGIN_PORT=3081 "$image" > "$work/refused.txt" 2>&1; then
  fail 'started with the login helper on the port of the tavern'
fi
cat "$work/refused.txt"
grep -q 'DSH_TAVERN_LOGIN_PORT' "$work/refused.txt" || fail 'the refusal does not name DSH_TAVERN_LOGIN_PORT'

step 'First start, on an empty directory of the host that belongs to root'
sudo rm -rf "$data"
sudo mkdir -p "$data"
docker run -d --name "$name" --health-interval 5s --stop-timeout 30 \
  -p "127.0.0.1:$port:3081" \
  -p "127.0.0.1:$login_port:3082" \
  -e DSH_PUBLIC_URL=https://tavern.example.com/ \
  -e DSH_TRUSTED_HOSTS=second.example.com:8443 \
  -e DSH_TAVERN_LOGIN_PORT=3082 \
  -v "$data:/data" "$image" > /dev/null
began=$(date +%s)
wait_up 900
wait_token ''
echo "up after $(($(date +%s) - began)) seconds"
hide < "$work/logs.txt" | tail -n 40
docker top "$name"
sudo du -sm "$data"

step 'Nobody gets in without the token; with it, the page is the tavern'
expect 'without the token' 401 "$(code "$base/")"
login "$direct" "$fresh"
expect 'the page, with the cookie' 200 "$(page)"
curl -s -m 10 -H "Cookie: $session" -o "$work/page.html" "$base/"
grep -qi '<html' "$work/page.html" || fail 'the page is not HTML'
{ grep -o 'dsh-tavern[a-z-]*' "$work/page.html" | sort | uniq -c | sort -rn; } > "$work/mentions.txt" || true
head -n 8 "$work/mentions.txt"
[ -s "$work/mentions.txt" ] || fail 'the page does not load the tavern'
docker exec "$name" dsh-tavern status > "$work/status.txt" 2>&1 || {
  cat "$work/status.txt"
  fail 'dsh-tavern status failed'
}
hide < "$work/status.txt"
who=$(docker exec "$name" sh -c 'ps -o user= -p "$(pgrep -o -f -- "$0")" | xargs' "$service")
expect 'the service runs as' node "$who"
expect 'the files belong to user' 1000 "$(sudo stat -c %u "$home/profiles/tavern/package.json")"
if [ -n "${SMOKE_PICTURES:-}" ]; then
  node "$(dirname "$0")/first-screen.cjs" "$base/?token=$fresh" "$SMOKE_PICTURES" ||
    fail 'no picture of the first screen could be taken'
  echo 'The first screen reads:'
  head -n 60 "$SMOKE_PICTURES/first-screen.txt" | hide
fi

step 'Only the names given are let in'
let_in=$(api)
expect_let_in 'the API, reached directly' "$let_in"
login tavern.example.com "$fresh"
expect 'the page under the public name' 200 "$(page)"
expect_let_in 'the public name' "$(api)"
expect_let_in 'the public name, from its own HTTPS page' "$(api -H 'Origin: https://tavern.example.com')"
expect 'the public name, from the page of another site' 403 "$(api -H 'Origin: https://evil.example.com')"
expect 'the public name, not logged in' 401 "$(code -H 'Host: tavern.example.com' "$base/api/smoke-test-no-such-route")"
login second.example.com:8443 "$fresh"
expect_let_in 'a second name with its port' "$(api)"
login second.example.com "$fresh"
expect 'the second name on another port' 403 "$(api)"
login evil.example.com "$fresh"
expect 'a name that was not given' 403 "$(api)"

step 'The health check of the image'
health=starting
for _ in $(seq 1 30); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$name")
  [ "$health" != healthy ] || break
  sleep 2
done
expect 'health' healthy "$health"

step 'Behind a reverse proxy that checks a password, set up as openresty.conf says'
proxy=$work/proxy
mkdir -p "$proxy"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=tavern.example.com \
  -addext subjectAltName=DNS:tavern.example.com -keyout "$proxy/key.pem" -out "$proxy/cert.pem" 2> /dev/null
printf '%s:%s\n' "$proxy_user" "$(openssl passwd -apr1 "$proxy_password")" > "$proxy/htpasswd"
sed -e 's#/path/to/fullchain.pem#/etc/nginx/tavern/cert.pem#' \
  -e 's#/path/to/privkey.pem#/etc/nginx/tavern/key.pem#' \
  -e 's#/path/to/tavern.htpasswd#/etc/nginx/tavern/htpasswd#' \
  -e "s#127.0.0.1:10444#127.0.0.1:$port#" \
  -e "s#127.0.0.1:10445#127.0.0.1:$login_port#" \
  "$(dirname "$0")/openresty.conf" > "$proxy/site.conf"
chmod -R a+rX "$proxy"
docker run -d --name tavern-smoke-proxy --network host \
  -v "$proxy/site.conf:/etc/nginx/conf.d/default.conf:ro" -v "$proxy:/etc/nginx/tavern:ro" \
  openresty/openresty:alpine > /dev/null

# A request to the site through the proxy, and its status.
proxied() { curl -sk -m 15 --resolve tavern.example.com:443:127.0.0.1 "$@"; }
through() { proxied -o /dev/null -w '%{http_code}' "$@" || true; }
knows=(-u "$proxy_user:$proxy_password")

for _ in $(seq 1 30); do
  [ "$(through "$proxy_site/version")" != 200 ] || break
  sleep 1
done
expect 'no password: what cards fetch' 200 "$(through "$proxy_site/version")"
expect 'no password: writing where cards fetch' 401 "$(through -X POST "$proxy_site/api/dsh-tavern/static-assets")"
expect 'no password: the API' 401 "$(through "$proxy_site/api/smoke-test-no-such-route")"
expect 'no password: the page' 401 "$(through -D "$work/headers.txt" "$proxy_site/")"
grep -qi '^www-authenticate: *basic' "$work/headers.txt" || fail 'no password: the browser is not asked for one'
! grep -qi '^location:' "$work/headers.txt" || fail 'no password: sent on to the login link'
expect 'a wrong password: the page' 401 "$(through -D "$work/headers.txt" -u "$proxy_user:wrong" "$proxy_site/")"
! grep -qi '^location:' "$work/headers.txt" || fail 'a wrong password: sent on to the login link'
# The opening of a WebSocket is passed on without the password, and the tavern
# refuses it for want of its own cookie.
proxied -o /dev/null -D "$work/headers.txt" --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: c21va2UtdGVzdC1rZXkhIQ==' "$proxy_site/api/remote.mux" || true
printf '%-64s %s\n' 'no password: the opening of a WebSocket' "$(head -n 1 "$work/headers.txt" | tr -d '\r')"
! grep -qi '^www-authenticate:' "$work/headers.txt" || fail 'the opening of a WebSocket is asked for the password'
! grep -q '^HTTP/1.1 101' "$work/headers.txt" || fail 'a WebSocket was opened without any login'

rm -f "$work/proxy.jar"
expect 'the password, not logged in to the tavern: the page' 302 "$(through -D "$work/headers.txt" "${knows[@]}" "$proxy_site/")"
grep -qi '^location: /?token=' "$work/headers.txt" || fail 'the password: not sent on to the login link'
expect 'the password: on from there to the page' 200 "$(through "${knows[@]}" -L -c "$work/proxy.jar" -b "$work/proxy.jar" "$proxy_site/")"
expect 'the password and the cookie: the page' 200 "$(through "${knows[@]}" -b "$work/proxy.jar" "$proxy_site/")"
expect 'the password and the cookie: the API' "$let_in" "$(through "${knows[@]}" -b "$work/proxy.jar" "$proxy_site/api/smoke-test-no-such-route")"
expect 'the cookie without the password: the page' 401 "$(through -b "$work/proxy.jar" "$proxy_site/")"
expect 'the password and a link that is out of date' 302 "$(through "${knows[@]}" "$proxy_site/?token=out-of-date")"

if [ -n "${SMOKE_PICTURES:-}" ]; then
  node "$(dirname "$0")/proxy-check.cjs" "$proxy_site" "$proxy_user" "$proxy_password" "$SMOKE_PICTURES" ||
    fail 'a browser did not get through the proxy as it should'
  # What the proxy saw of the frame's request for what needs the login: no
  # account with it, and so it asked for the password.
  docker logs tavern-smoke-proxy > "$work/proxy.txt" 2>&1 || true
  grep -F 'card-image?smoke=1' "$work/proxy.txt" > "$work/apart.txt" || fail 'the request of the frame did not reach the proxy'
  cat "$work/apart.txt"
  grep -q '^[^ ]* - - .*" 401 ' "$work/apart.txt" || fail 'the request of the frame carried the password after all'
fi
docker rm -f tavern-smoke-proxy > /dev/null

step 'A restart keeps the data and the logins, and does not unpack again'
docker exec -u node "$name" sh -c 'mkdir -p /data/dsh-tavern/profile-data/tavern/smoke && echo kept > /data/dsh-tavern/profile-data/tavern/smoke/kept.txt'
login tavern.example.com "$fresh"
before=$fresh
docker restart "$name" > /dev/null
wait_up 300
wait_token "$before"
expect 'times the install was unpacked' 1 "$(count '放进数据目录')"
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/smoke/kept.txt")"
expect 'the page, with the cookie from before the restart' 200 "$(page)"
expect_let_in 'the public name, with the cookie from before' "$(api)"

step 'Leftovers of a container that was killed do not keep the next from starting'
before=$fresh
docker kill "$name" > /dev/null
sudo mkdir -p "$home/.tavern-install.lock" "$home/apps/dsh-tavern.staging" "$home/logs"
printf '{"attemptId":"smoke","generation":"smoke","pid":7,"startedAt":%s000,"state":"running"}\n' "$(date +%s)" |
  sudo tee "$home/.tavern-install.lock/owner.json" > /dev/null
printf '{"pid":7,"port":3081,"bindHost":"10.255.255.1","profile":"tavern"}\n' |
  sudo tee "$home/logs/tavern.pid.json" > /dev/null
sudo chown -R 1000:1000 "$home/.tavern-install.lock" "$home/apps/dsh-tavern.staging" "$home/logs/tavern.pid.json"
docker start "$name" > /dev/null
wait_up 300
wait_token "$before"
[ ! -e "$home/.tavern-install.lock" ] || fail 'the lock of an install that no longer runs is still there'
[ ! -e "$home/apps/dsh-tavern.staging" ] || fail 'the half-prepared version is still there'

step 'A directory that another image filled keeps its tavern, and is told so once'
before=$fresh
docker stop "$name" > /dev/null
sudo sed -i 's/"commit":"[0-9a-f]*"/"commit":"0000000000000000000000000000000000000000"/' "$home/.docker-seed"
docker start "$name" > /dev/null
wait_up 300
wait_token "$before"
expect 'times the image said that it carries another version' 1 "$(count '这个镜像自带的酒馆是')"
expect 'times the install was unpacked' 1 "$(count '放进数据目录')"
expect 'the commit recorded for the directory' "$(jq -r .commit "$work/seed.json")" "$(sudo jq -r .commit "$home/.docker-seed")"

step 'The dsh-tavern command restarts the service, and the container stays'
before=$fresh
since=$(docker inspect -f '{{.State.StartedAt}}' "$name")
docker exec "$name" dsh-tavern restart > "$work/restart.txt" 2>&1 || {
  hide < "$work/restart.txt"
  fail 'dsh-tavern restart failed'
}
hide < "$work/restart.txt"
wait_up 300
wait_token "$before"
expect 'the container was not restarted' "$since" "$(docker inspect -f '{{.State.StartedAt}}' "$name")"
login tavern.example.com "$fresh"
expect 'the page under the public name, after the restart' 200 "$(page)"
expect_let_in 'the public name, after the restart' "$(api)"

if [ -n "$commit" ]; then
  step 'An update inside the container, as the page starts one'
  before=$fresh
  docker exec -u node "$name" sh -c \
    'git init -q --bare /tmp/pinned.git && git -C /tmp/pinned.git fetch -q --depth 1 "https://github.com/$0.git" "$1:refs/heads/main"' \
    "$repository" "$commit"
  began=$(date +%s)
  if ! docker exec -e DSH_TAVERN_GIT_URL=file:///tmp/pinned.git "$name" dsh-tavern update > "$work/update.txt" 2>&1; then
    hide < "$work/update.txt" | tail -n 200
    fail 'the update failed'
  fi
  hide < "$work/update.txt" | tail -n 30
  echo "updated in $(($(date +%s) - began)) seconds"
  wait_up 300
  wait_token "$before"
  expect 'the container was not restarted' "$since" "$(docker inspect -f '{{.State.StartedAt}}' "$name")"
  expect 'the installed commit' "$commit" "$(sudo jq -r .commit "$home/apps/dsh-tavern/.dsh-tavern-release.json")"
  login tavern.example.com "$fresh"
  expect 'the page under the public name, after the update' 200 "$(page)"
  expect_let_in 'the public name, after the update' "$(api)"
  expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/smoke/kept.txt")"
fi

step 'When the service dies, the container ends, for Docker to start it again'
before=$fresh
docker exec "$name" pkill -KILL -f -- "$service"
expect 'exit code' 1 "$(timeout 90 docker wait "$name")"

step 'An update that was cut off after the switch is undone at the next start'
sudo cp -al "$home/apps/dsh-tavern" "$home/apps/dsh-tavern.previous"
printf '{"fresh":false,"moved":[]}\n' | sudo tee "$home/apps/dsh-tavern/.dsh-tavern-swap.json" > /dev/null
sudo chown 1000:1000 "$home/apps/dsh-tavern/.dsh-tavern-swap.json"
docker start "$name" > /dev/null
wait_up 300
wait_token "$before"
[ ! -e "$home/apps/dsh-tavern.previous" ] || fail 'the version from before the update was not put back'
[ ! -e "$home/apps/dsh-tavern/.dsh-tavern-swap.json" ] || fail 'the switch is still recorded as unfinished'
expect 'times an unfinished update was undone' 2 "$(count '上次更新没有做完')"

step 'Stopping ends the service and the container within the time Docker gives'
before=$fresh
began=$(date +%s)
docker stop "$name" > /dev/null
echo "stopped after $(($(date +%s) - began)) seconds"
expect 'exit code' 0 "$(docker inspect -f '{{.State.ExitCode}}' "$name")"
[ ! -e "$home/logs/tavern.pid.json" ] || fail 'the record of the running service is still there'

step 'Program files that are gone are put back at the start; the data stays'
sudo rm -rf "$home/runtime"
docker start "$name" > /dev/null
wait_up 900
wait_token "$before"
expect 'times the install was unpacked' 2 "$(count '放进数据目录')"
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/smoke/kept.txt")"

step 'The repair command does the same on demand'
before=$fresh
docker stop "$name" > /dev/null
echo broken | sudo tee "$home/apps/dsh-tavern/bin/dsh-tavern.mjs" > /dev/null
docker run --rm -v "$data:/data" "$image" repair
docker start "$name" > /dev/null
wait_up 300
wait_token "$before"
expect 'times the install was unpacked at a start' 2 "$(count '放进数据目录')"
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/smoke/kept.txt")"
login tavern.example.com "$fresh"
expect_let_in 'the public name, after the repair' "$(api)"
expect 'times the image said that it carries another version' 1 "$(count '这个镜像自带的酒馆是')"
sudo du -sm "$data"
docker rm -f "$name" > /dev/null

step 'First start on a volume of Docker'
name=tavern-smoke-volume
docker run -d --name "$name" -p "127.0.0.1:$port:3081" \
  -e DSH_PUBLIC_URL=https://tavern.example.com/ -v tavern-smoke-volume:/data "$image" > /dev/null
wait_up 900
wait_token ''
login "$direct" "$fresh"
expect 'the page' 200 "$(page)"

printf '\nAll checks passed.\n'
