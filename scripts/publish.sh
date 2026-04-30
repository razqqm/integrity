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
#       --bundle <local-path>[:<public-url>][:<logical-name>] \
#       [--bundle ...]                # repeat for additional artifacts
#
# Example:
#   ./publish.sh tg.ilia.ae \
#       --commit 1bf2ac5 \
#       --commit-full 1bf2ac5bcc... \
#       --branch main \
#       --bundle dist/browser/main-XYZ.js:https://tg.ilia.ae/main-XYZ.js:main.js
#
# The script must run inside a checkout of the integrity repo. It does NOT
# touch the project's repo. It expects `git`, `jq`, and `shasum -a 256` to be
# available.

set -Eeuo pipefail

INTEGRITY_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$INTEGRITY_REPO_DIR"

err() { echo "publish.sh: $*" >&2; exit 1; }

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

bundles_json="["
for i in "${!BUNDLES[@]}"; do
    spec="${BUNDLES[$i]}"
    IFS=':' read -r path url name <<<"$spec"
    [ -f "$path" ] || err "bundle file not found: $path"
    [ "$name" ] || name="$(basename "$path" | sed -E 's/-[A-Z0-9]+\.js$/.js/')"
    sha="$(shasum -a 256 "$path" | awk '{print $1}')"
    size="$(wc -c <"$path" | tr -d ' ')"
    [ "$i" -gt 0 ] && bundles_json+=","
    bundles_json+=$(jq -n --arg name "$name" --arg url "$url" --arg sha "$sha" --argjson size "$size" \
        '{name: $name, url: ($url|select(.!="")), sha256: $sha, size: $size} | with_entries(select(.value != null))')
done
bundles_json+="]"

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

manifest=$(jq -n \
    --arg project "$PROJECT" \
    --arg commit "$COMMIT" \
    --arg commit_full "$COMMIT_FULL" \
    --arg branch "$BRANCH" \
    --arg built_at "$now" \
    --arg published_at "$now" \
    --arg source_vis "$SOURCE_VIS" \
    --arg source_url "$SOURCE_URL" \
    --argjson bundles "$bundles_json" \
    '{
        project: $project,
        commit: $commit,
        commitFull: ($commit_full|select(.!="")),
        branch: ($branch|select(.!="")),
        builtAt: $built_at,
        publishedAt: $published_at,
        bundles: $bundles,
        sourceRepoVisibility: $source_vis,
        publicSourceUrl: ($source_url|select(.!=""))
    } | with_entries(select(.value != null))')

echo "$manifest" >"$PROJECT_DIR/manifest.json"
echo "$manifest" >"$HISTORY_DIR/$COMMIT.json"

git add "$PROJECT_DIR"
if git diff --cached --quiet; then
    echo "publish.sh: no changes — manifest already up to date"
    exit 0
fi
git commit -m "$PROJECT: publish $COMMIT"
git push
echo "publish.sh: published manifest for $PROJECT @ $COMMIT"
