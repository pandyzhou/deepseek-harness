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
data=/tmp/tavern-smoke-data
home=$data/dsh-tavern
work=$(mktemp -d)
service='--profile tavern .*--port '
session=

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

# Logs in with a token and keeps the cookie it leaves, in $session.
login() {
  local status
  rm -f "$work/jar"
  status=$(code -c "$work/jar" "$base/?token=$1")
  case "$status" in 200 | 30?) ;; *) fail "the login link answered $status" ;; esac
  session=$(awk -F '\t' '($1 !~ /^#/ || $1 ~ /^#HttpOnly_/) && NF >= 7 { printf "%s%s=%s", sep, $6, $7; sep = "; " }' "$work/jar")
  [ -n "$session" ] || fail 'the login link left no cookie'
}

# The status of a request for the API, logged in, as it arrives through a
# reverse proxy for the given name.
api() {
  local host=$1
  shift
  code -H "Host: $host" -H "Cookie: $session" "$@" "$base/api/smoke-test-no-such-route"
}

expect() {
  local what=$1 wanted=$2 got=$3
  printf '%-64s %s\n' "$what" "$got"
  case " $wanted " in *" $got "*) ;; *) fail "$what: expected $wanted, got $got" ;; esac
}

# Let in: whatever the API then answers about a route it does not have, it is
# neither "log in first" nor "not from this name".
expect_let_in() {
  local what=$1 got=$2
  printf '%-64s %s\n' "$what" "$got"
  case "$got" in 000 | 401 | 403) fail "$what: was refused with $got" ;; esac
}

count() { logs; grep -c -- "$1" "$work/logs.txt" || true; }

cleanup() {
  docker rm -f tavern-smoke tavern-smoke-volume > /dev/null 2>&1 || true
  docker volume rm -f tavern-smoke-volume > /dev/null 2>&1 || true
  sudo rm -rf "$data" "$work"
}
trap cleanup EXIT

docker image ls "$image" --format 'size of the image: {{.Size}}'
docker run --rm --entrypoint cat "$image" /opt/dsh-tavern/seed.json

step 'An address that is not one is refused before anything is unpacked'
if docker run --rm -e DSH_PUBLIC_URL=tavern.example.com "$image" > "$work/refused.txt" 2>&1; then
  fail 'started with a DSH_PUBLIC_URL that is not an address'
fi
cat "$work/refused.txt"
grep -q 'DSH_PUBLIC_URL' "$work/refused.txt" || fail 'the refusal does not name DSH_PUBLIC_URL'

step 'First start, on an empty directory of the host that belongs to root'
sudo rm -rf "$data"
sudo mkdir -p "$data"
docker run -d --name "$name" --health-interval 5s --stop-timeout 30 \
  -p "127.0.0.1:$port:3081" \
  -e DSH_PUBLIC_URL=https://tavern.example.com/ \
  -e DSH_TRUSTED_HOSTS=second.example.com:8443 \
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
login "$fresh"
expect 'the page, with the cookie' 200 "$(code -H "Cookie: $session" -o "$work/page.html" "$base/")"
grep -qi '<html' "$work/page.html" || fail 'the page is not HTML'
{ grep -o 'dsh-tavern[a-z-]*' "$work/page.html" | sort | uniq -c | sort -rn; } > "$work/mentions.txt" || true
head -n 8 "$work/mentions.txt"
[ -s "$work/mentions.txt" ] || fail 'the page does not load the tavern'
docker exec "$name" dsh-tavern status > "$work/status.txt" 2>&1 || { cat "$work/status.txt"; fail 'dsh-tavern status failed'; }
hide < "$work/status.txt"
who=$(docker exec "$name" sh -c 'ps -o user= -p "$(pgrep -o -f -- "$0")" | xargs' "$service")
expect 'the service runs as' node "$who"
expect 'the files belong to user' 1000 "$(sudo stat -c %u "$home/profiles/tavern/package.json")"

step 'Only the names given are let in'
expect_let_in 'the public name' "$(api tavern.example.com)"
expect_let_in 'the public name, from its own HTTPS page' "$(api tavern.example.com -H 'Origin: https://tavern.example.com')"
expect_let_in 'a second name with its port' "$(api second.example.com:8443)"
expect 'the second name on another port' 403 "$(api second.example.com)"
expect 'a name that was not given' 403 "$(api evil.example.com)"
expect 'the public name, from the page of another site' 403 "$(api tavern.example.com -H 'Origin: https://evil.example.com')"
expect 'the public name, not logged in' '401 403' "$(code -H 'Host: tavern.example.com' "$base/api/smoke-test-no-such-route")"

step 'The health check of the image'
health=starting
for _ in $(seq 1 30); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$name")
  [ "$health" != healthy ] || break
  sleep 2
done
expect 'health' healthy "$health"

step 'A restart keeps the data and does not unpack again'
docker exec -u node "$name" sh -c 'echo kept > /data/dsh-tavern/profile-data/tavern/data/cards/smoke.txt'
before=$fresh
docker restart "$name" > /dev/null
wait_up 300
wait_token "$before"
expect 'times the install was unpacked' 1 "$(count '放进数据目录')"
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/data/cards/smoke.txt")"
echo "the cookie from before the restart now answers: $(code -H "Cookie: $session" "$base/")"

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

step 'The dsh-tavern command restarts the service, and the container stays'
before=$fresh
since=$(docker inspect -f '{{.State.StartedAt}}' "$name")
docker exec "$name" dsh-tavern restart > "$work/restart.txt" 2>&1 || { hide < "$work/restart.txt"; fail 'dsh-tavern restart failed'; }
hide < "$work/restart.txt"
wait_up 300
wait_token "$before"
expect 'the container was not restarted' "$since" "$(docker inspect -f '{{.State.StartedAt}}' "$name")"
login "$fresh"
expect 'the page, after the restart' 200 "$(code -H "Cookie: $session" "$base/")"
expect_let_in 'the public name, after the restart' "$(api tavern.example.com)"

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
  login "$fresh"
  expect 'the page, after the update' 200 "$(code -H "Cookie: $session" "$base/")"
  expect_let_in 'the public name, after the update' "$(api tavern.example.com)"
  expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/data/cards/smoke.txt")"
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
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/data/cards/smoke.txt")"

step 'The repair command does the same on demand'
before=$fresh
docker stop "$name" > /dev/null
echo broken | sudo tee "$home/apps/dsh-tavern/bin/dsh-tavern.mjs" > /dev/null
docker run --rm -v "$data:/data" "$image" repair
docker start "$name" > /dev/null
wait_up 300
wait_token "$before"
expect 'times the install was unpacked at a start' 2 "$(count '放进数据目录')"
expect 'the file written before' kept "$(sudo cat "$home/profile-data/tavern/data/cards/smoke.txt")"
sudo du -sm "$data"
docker rm -f "$name" > /dev/null

step 'First start on a volume of Docker'
name=tavern-smoke-volume
docker run -d --name "$name" -p "127.0.0.1:$port:3081" \
  -e DSH_PUBLIC_URL=https://tavern.example.com/ -v tavern-smoke-volume:/data "$image" > /dev/null
wait_up 900
wait_token ''
login "$fresh"
expect 'the page' 200 "$(code -H "Cookie: $session" "$base/")"

printf '\nAll checks passed.\n'
