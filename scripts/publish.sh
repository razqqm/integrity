#!/usr/bin/env bash
# Publish or update a project's deployment integrity manifest.
#
# Designed to run from a project's deploy pipeline AFTER the build artifacts
# are finalized. Computes SHA-256 of the local file(s), produces manifest.json,
# stores a copy under projects/<project>/history/<commit>.json, commits, pushes.
#
# Usage:
#   publish.sh <project> --commit <short-sha> [--commit-full <full-sha>] \
#       [--branch <branch>] [--source-public-url <url>] \
#       --bundle <local-path>[|<public-url>][|<logical-name>] \
#       [--bundle ...]                # repeat for additional artifacts
#
# The bundle spec uses `|` as separator so URLs containing `:` parse correctly.
#
# Example:
#   ./publish.sh tg.ilia.ae \
#       --commit 1bf2ac5 \
#       --commit-full 1bf2ac5bcc... \
#       --branch main \
#       --bundle 'dist/browser/main-XYZ.js|https://tg.ilia.ae/main-XYZ.js|main.js'
#
# The script must run inside a checkout of the integrity repo. It does NOT
# touch the project's repo. It expects only POSIX tools (`git`, `shasum -a 256`,
# `wc`, `awk`, `sed`, `date`) — no `jq`, no Python, so it works on minimal
# server images out of the box.

set -Eeuo pipefail

INTEGRITY_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$INTEGRITY_REPO_DIR"

err() { echo "publish.sh: $*" >&2; exit 1; }

# JSON-escape a string. Our inputs are short and free of control characters
# (project name, sha, branch, ISO date, http URL, hex hash, file name), so
# escaping backslash + double quote covers every value we ever pass in.
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

[ "${1:-}" ] || err "missing <project>"
PROJECT="$1"; shift

COMMIT=""; COMMIT_FULL=""; BRANCH=""; SOURCE_URL=""; SOURCE_VIS="private"
BUNDLES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --commit)             COMMIT="$2"; shift 2 ;;
        --commit-full)        COMMIT_FULL="$2"; shift 2 ;;
        --branch)             BRANCH="$2"; shift 2 ;;
        --source-public-url)  SOURCE_URL="$2"; SOURCE_VIS="public"; shift 2 ;;
        --bundle)             BUNDLES+=("$2"); shift 2 ;;
        *) err "unknown arg: $1" ;;
    esac
done

[ "$COMMIT" ] || err "missing --commit"
[ "${#BUNDLES[@]}" -gt 0 ] || err "at least one --bundle is required"

PROJECT_DIR="projects/$PROJECT"
HISTORY_DIR="$PROJECT_DIR/history"
mkdir -p "$HISTORY_DIR"

# ---- bundles array ----
bundles_json="["
for i in "${!BUNDLES[@]}"; do
    spec="${BUNDLES[$i]}"
    IFS='|' read -r path url name <<<"$spec"
    [ -f "$path" ] || err "bundle file not found: $path"
    [ "$name" ] || name="$(basename "$path" | sed -E 's/-[A-Z0-9]+\.js$/.js/')"
    sha="$(shasum -a 256 "$path" | awk '{print $1}')"
    size="$(wc -c <"$path" | tr -d ' ')"

    [ "$i" -gt 0 ] && bundles_json+=","
    bundles_json+=$'\n    {'
    bundles_json+=$'\n      '"$(json_str name)"': '"$(json_str "$name")"
    if [ -n "$url" ]; then
        bundles_json+=','$'\n      '"$(json_str url)"': '"$(json_str "$url")"
    fi
    bundles_json+=','$'\n      '"$(json_str sha256)"': '"$(json_str "$sha")"
    bundles_json+=','$'\n      '"$(json_str size)"': '"$size"
    bundles_json+=$'\n    }'
done
bundles_json+=$'\n  ]'

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- manifest object ----
manifest='{'
manifest+=$'\n  '"$(json_str project)"': '"$(json_str "$PROJECT")"','
manifest+=$'\n  '"$(json_str commit)"': '"$(json_str "$COMMIT")"','
if [ -n "$COMMIT_FULL" ]; then
    manifest+=$'\n  '"$(json_str commitFull)"': '"$(json_str "$COMMIT_FULL")"','
fi
if [ -n "$BRANCH" ]; then
    manifest+=$'\n  '"$(json_str branch)"': '"$(json_str "$BRANCH")"','
fi
manifest+=$'\n  '"$(json_str builtAt)"': '"$(json_str "$now")"','
manifest+=$'\n  '"$(json_str publishedAt)"': '"$(json_str "$now")"','
manifest+=$'\n  '"$(json_str bundles)"': '"$bundles_json"','
manifest+=$'\n  '"$(json_str sourceRepoVisibility)"': '"$(json_str "$SOURCE_VIS")"
if [ -n "$SOURCE_URL" ]; then
    manifest+=','$'\n  '"$(json_str publicSourceUrl)"': '"$(json_str "$SOURCE_URL")"
fi
manifest+=$'\n}'

printf '%s\n' "$manifest" >"$PROJECT_DIR/manifest.json"
printf '%s\n' "$manifest" >"$HISTORY_DIR/$COMMIT.json"

git add "$PROJECT_DIR"
if git diff --cached --quiet; then
    echo "publish.sh: no changes — manifest already up to date"
    exit 0
fi
# Set identity inline — no filesystem writes, no $HOME dependency, works under
# server users (root, www-data, …) that have no global git config.
git -c user.email='deploy@razqqm-integrity.local' \
    -c user.name='razqqm-integrity-bot' \
    commit -m "$PROJECT: publish $COMMIT"
git push
echo "publish.sh: published manifest for $PROJECT @ $COMMIT"
