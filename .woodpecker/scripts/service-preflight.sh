#!/usr/bin/env bash
# Runs ON the server. Read-only check for a repo-driven service (migrations, resource):
# image tag/version, compose config, and changes in the watched config folder.
#   ssh deploy bash -s -- <APP_DIR> <BRANCH> <SERVICE> <WATCH> <DEPLOY_ON> < .woodpecker/scripts/service-preflight.sh
#   DEPLOY_ON: added = only new files in WATCH trigger a deploy
#              any   = new/changed files, new image or changed compose config
# Compares origin/BRANCH with the commit this service was LAST DEPLOYED at
# (.git/deployed/<SERVICE>), not HEAD: another service's deploy may have moved HEAD.
# Only side effects: image pull, temp files, and creating a missing marker (fallback).
# Prints a changed=true|false line (and optionally warning=...).
set -e
cd "$1"
BRANCH=$2; SVC=$3; WATCH=$4; DEPLOY_ON=$5
GITDIR=$(git rev-parse --git-dir)
MARKER="$GITDIR/deployed/$SVC"
TARGET="origin/$BRANCH"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -f "$MARKER" ]; then
  BASE=$(cat "$MARKER")
  echo "base: last $SVC rollout at $(git log -1 --format='%h %s' "$BASE")"
else
  # fallback (normally seeded by repo-pull.sh): record the current checkout
  # as deployed state NOW, before HEAD can move
  BASE=$(git rev-parse HEAD)
  mkdir -p "$GITDIR/deployed"
  echo "$BASE" > "$MARKER"
  echo "base: current checkout $(git log -1 --format='%h %s' "$BASE") (no $SVC rollout recorded yet, marker created)"
fi
echo "target: $TARGET at $(git log -1 --format='%h %s' "$TARGET")"

# --- compose files as they will be after the pull ---
# tracked: version from $TARGET, untracked (e.g. local override): as on disk
CF=$(grep -E '^COMPOSE_FILE=' .env 2>/dev/null | cut -d= -f2- || true)
[ -z "$CF" ] && CF="docker-compose.yml:docker-compose.override.yml"
files=()
IFS=: read -ra list <<< "$CF"
for f in "${list[@]}"; do
  if git cat-file -e "$TARGET:$f" 2>/dev/null; then
    mkdir -p "$TMP/$(dirname "$f")"
    git show "$TARGET:$f" > "$TMP/$f"
    files+=(-f "$TMP/$f")
  elif [ -f "$f" ]; then
    files+=(-f "$PWD/$f")
  fi
done
PROJECT=$(docker compose config --format json 2>/dev/null | grep -oE '"name": *"[^"]+"' | head -1 | cut -d'"' -f4)
# project dir = app dir, so .env and relative volume paths resolve as usual
NEXT=(docker compose --project-directory "$PWD" ${PROJECT:+-p "$PROJECT"} "${files[@]}")
CID=$(docker compose ps -a -q "$SVC")

# --- 1. image tag ---
# image of exactly $SVC (config --images also lists depends_on services)
image_of() {
  "$@" config | awk -v s="$SVC" '
    /^[^ ]/ { in_s = ($0 == "services:"); svc = 0; next }
    in_s && /^  [^ ]/ { svc = ($0 == "  " s ":"); next }
    in_s && svc && /^    image:/ { gsub(/"/, "", $2); print $2; exit }'
}
image_new=false
IMAGE_NOW=$(image_of docker compose)
IMAGE_NEXT=$(image_of "${NEXT[@]}")
"${NEXT[@]}" pull --quiet "$SVC"   # downloads only, container untouched
echo
echo "== image =="
if [ "$IMAGE_NOW" != "$IMAGE_NEXT" ]; then
  image_new=true
  echo "tag changes: $IMAGE_NOW -> $IMAGE_NEXT"
elif [ -n "$CID" ] && [ "$(docker image inspect -f '{{.Id}}' "$IMAGE_NEXT")" = "$(docker inspect -f '{{.Image}}' "$CID")" ]; then
  echo "$IMAGE_NEXT: no new version"
else
  image_new=true
  echo "$IMAGE_NEXT: new version available"
fi

# --- 2. service config ---
config_changed=false
echo
echo "== config =="
if [ -z "$CID" ]; then
  config_changed=true
  echo "no $SVC container yet"
elif [ "$("${NEXT[@]}" config --hash "$SVC" | awk '{print $2}')" \
     != "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$CID")" ]; then
  config_changed=true
  echo "$SVC service config changes"
else
  echo "no config changes for $SVC"
fi

# --- 3. watched files ---
echo
echo "== $WATCH =="
added=$(git diff --name-only --diff-filter=A "$BASE" "$TARGET" -- "$WATCH")
changed=$(git diff --name-status --diff-filter=MDR "$BASE" "$TARGET" -- "$WATCH")
if [ -n "$added" ]; then
  echo "new files ($(echo "$added" | wc -l)):"
  echo "$added" | sed 's/^/  + /'
else
  echo "no new files"
fi
if [ -n "$changed" ]; then
  echo "changed/removed files:"
  echo "$changed" | sed 's/^/  ~ /'
fi

# --- decision ---
deploy=false
case "$DEPLOY_ON" in
  added) [ -n "$added" ] && deploy=true ;;
  any)   { [ -n "$added$changed" ] || [ "$image_new" = true ] || [ "$config_changed" = true ]; } && deploy=true ;;
  *)     echo "unknown DEPLOY_ON '$DEPLOY_ON' (use added|any)" >&2; exit 1 ;;
esac
echo
echo "changed=$deploy"
if [ "$DEPLOY_ON" = added ] && [ -n "$changed" ]; then
  echo "warning=existing files changed/removed; already-run migrations are NOT re-run"
fi