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

# Fixes of our own on top of that commit, until upstream makes them; README.md
# lists them under "在上游之上的修补". Each text to replace has to be there
# exactly once: when a new TAVERN_COMMIT changes the code it touches, the build
# stops here, to drop the fix if upstream has made it or to write it again.
TAVERN_APP="$TAVERN_APP" node - <<'EOF'
const fs = require('node:fs')
const path = require('node:path')
const endsSentence = ['return TAVERN_PROSE_TERMINAL.test(value.trim());',
  'return TAVERN_PROSE_TERMINAL.test(value.trim().replace(/[*_~]+$/, "").trimEnd()); /* docker-tavern 2026-11-26 */']
const ownParagraph = ['if (tavernProseEndsSentence(current)) { paragraphs.push(current); current = piece; return; }',
  'if (tavernProseEndsSentence(current) || (/[*_~]$/.test(current) && /^[*_~]/.test(piece))) { paragraphs.push(current); current = piece; return; } /* docker-tavern 2026-11-26 */']
const fixes = [
  // 2026-11-26: the overview of the 预设 tab sits in a panel of fixed height
  // and does not scroll, so its lower rows are cut off in a short panel; it
  // scrolls as a whole now. client.js carries the minified stylesheet that the
  // page uses, tavern.css is its source.
  ['tavern-plugin/lib/client.js',
    '.dsh-tavern-preset-hub{container-type:inline-size}',
    '.dsh-tavern-preset-hub{container-type:inline-size;overflow-y:auto}/* docker-tavern 2026-11-26 */'],
  ['tavern-plugin/lib/client-assets/tavern.css',
    '.dsh-tavern-preset-hub { container-type: inline-size; }',
    '.dsh-tavern-preset-hub { container-type: inline-size; overflow-y: auto; } /* docker-tavern 2026-11-26 */'],
  // 2026-11-26: a picture that a reply carries as plain HTML (the greetings of
  // some cards show the characters with <img>, and the model copies them) is
  // put straight into the page when cards are trusted, which is the default,
  // and nothing there limits its size: a picture 1254 px wide ran out of the
  // column. In a frame the same picture already keeps to the width. It fits
  // now, in proportion, at most 640 px wide and 70% of the window high.
  ['tavern-plugin/lib/client.js',
    '.dsh-tavern-illustration img{display:block;width:auto;height:auto;max-width:min(100%,640px);max-height:70vh;object-fit:contain;border-radius:12px}',
    '.dsh-tavern-illustration img{display:block;width:auto;height:auto;max-width:min(100%,640px);max-height:70vh;object-fit:contain;border-radius:12px}.dsh-tavern-inline-fragment img{max-width:min(100%,640px);max-height:70vh;object-fit:contain}/* docker-tavern 2026-11-26 */'],
  ['tavern-plugin/lib/client-assets/tavern.css',
    '.dsh-tavern-illustration img { display: block; width: auto; height: auto; max-width: min(100%, 640px); max-height: 70vh; object-fit: contain; border-radius: 12px; }',
    '.dsh-tavern-illustration img { display: block; width: auto; height: auto; max-width: min(100%, 640px); max-height: 70vh; object-fit: contain; border-radius: 12px; }\n.dsh-tavern-inline-fragment img { max-width: min(100%, 640px); max-height: 70vh; object-fit: contain; } /* docker-tavern 2026-11-26 */'],
  // 2026-11-26: 自动分段, which is on by default, joins two lines when the
  // first does not end a sentence. A line that ends in ** or * followed by a
  // line that starts with one became "****", and the bold or italics broke:
  // the status lines that some cards write at the top of each reply showed
  // their asterisks. Two such lines are paragraphs of their own now, and a
  // sentence that ends inside the markup ("快走！**") counts as ended.
  // prose-layout.js is the source of that part of client.js.
  ['tavern-plugin/lib/client.js', ...endsSentence],
  ['tavern-plugin/src/client/features/prose-layout.js', ...endsSentence],
  ['tavern-plugin/lib/client.js', ...ownParagraph],
  ['tavern-plugin/src/client/features/prose-layout.js', ...ownParagraph],
]
for (const [file, from, to] of fixes) {
  const target = path.join(process.env.TAVERN_APP, file)
  const text = fs.readFileSync(target, 'utf8')
  const found = text.split(from).length - 1
  if (found !== 1) {
    console.error(`${file}: the text to fix is there ${found} times instead of once: ${from}`)
    process.exit(1)
  }
  fs.writeFileSync(target, text.replace(from, () => to))
  console.log(`fixed ${file}`)
}
EOF

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
