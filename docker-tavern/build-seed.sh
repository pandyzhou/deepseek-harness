#!/bin/bash
# Runs once while the image is built, as the user node. Installs dsh-tavern at
# /data with the project's own installer, at exactly the commit in the file
# TAVERN_COMMIT, and packs the result into the archive that the first start of
# a container unpacks.
set -euo pipefail
. /usr/local/lib/dsh-tavern-docker/paths.sh

: "${TAVERN_REPOSITORY:?}"
TAVERN_COMMIT=$(tr -d '[:space:]' < /usr/local/lib/dsh-tavern-docker/TAVERN_COMMIT)
case "${TAVERN_COMMIT:-}" in
  *[!0-9a-f]* | '') echo "TAVERN_COMMIT is not a full commit id: ${TAVERN_COMMIT:-}" >&2; exit 1 ;;
esac
[ "${#TAVERN_COMMIT}" -eq 40 ] || { echo "TAVERN_COMMIT is not a full commit id: $TAVERN_COMMIT" >&2; exit 1; }

work=$(mktemp -d)
mkdir -p "$HOME"

# The installer always takes the head of main. A local repository whose main
# is the wanted commit pins it; install.sh comes from the same commit.
git init -q --bare "$work/source.git"
git -C "$work/source.git" fetch -q --depth 1 \
  "https://github.com/$TAVERN_REPOSITORY.git" "$TAVERN_COMMIT:refs/heads/main"
git -C "$work/source.git" show "$TAVERN_COMMIT:install.sh" > "$work/install.sh"

DSH_TAVERN_HOST=cli \
DSH_TAVERN_DEFER_SERVICE_START=1 \
DSH_TAVERN_GIT_URL="file://$work/source.git" \
  sh "$work/install.sh"

# What was installed is what was asked for, and its launcher runs.
installed=$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).commit' \
  "$TAVERN_APP/.dsh-tavern-release.json")
if [ "$installed" != "$TAVERN_COMMIT" ]; then
  echo "installed $installed instead of $TAVERN_COMMIT" >&2
  exit 1
fi
version=$(node -p 'require(process.argv[1]).version' "$TAVERN_APP/package.json")
dsh=$(node -p 'require(process.argv[1]).version' \
  "$TAVERN_HOME/runtime/lib/node_modules/@deepseek-ai/dsh/package.json")
node "$TAVERN_APP/bin/dsh-tavern.mjs" --version
test -x "$TAVERN_HOME/runtime/bin/dsh"
test -f "$TAVERN_HOME/profiles/tavern/package.json"
if [ -e "$TAVERN_HOME/.tavern-install.lock" ]; then
  echo 'the installer left its lock behind' >&2
  exit 1
fi

# Not part of an install: what the downloads were cached in, the source cache
# that points at the repository above, and the log of this run.
rm -rf "$work" "$HOME/.npm" "$HOME/.cache" "$TAVERN_HOME/source-cache" "$TAVERN_HOME/logs"

echo 'Sizes, in MB:'
du -sm "$TAVERN_HOME"/* "$HOME" | sort -n
kilobytes=$(du -sk /data | cut -f1)

# Sorted, so that of the files the package store shares with the installed
# packages the installed one is stored and the store's one is a link to it.
# The long window finds the packages that are there more than once; a higher
# level takes minutes for a few megabytes less.
tar --sort=name -C /data -cf - dsh-tavern home | zstd -q -T0 -12 --long=27 -o "$SEED"
printf '{"commit":"%s","version":"%s","dsh":"%s","kilobytes":%s}\n' \
  "$TAVERN_COMMIT" "$version" "$dsh" "$kilobytes" > "$SEED_INFO"
echo "Packed $((kilobytes / 1024)) MB into $(du -m "$SEED" | cut -f1) MB: $(cat "$SEED_INFO")"

# /data stays empty in the image: a volume is mounted there.
rm -rf /data/dsh-tavern /data/home
