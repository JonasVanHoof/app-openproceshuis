#!/usr/bin/env bash
# Runs ON the server. Recreates one compose service.
#   ssh deploy bash -s -- <APP_DIR> <SERVICE> [BRANCH] < deploy/deploy-service.sh
#
# Without BRANCH (frontend): uses the image the preflight already pulled, so it
#   deploys exactly what was checked. Repo is not touched.
# With BRANCH (migrations, resource): syncs the repo to origin/BRANCH, pulls the
#   image, recreates, and records the deployed commit in .git/deployed/<SERVICE>.
set -e
cd "$1"
SVC=$2
BRANCH=${3:-}
GITDIR=$(git rev-parse --git-dir)

if [ -n "$BRANCH" ]; then
  # git under a server-side lock: service deploys can run at the same time
  flock "$GITDIR/deploy.lock" bash -c '
    set -e
    git fetch --quiet origin "$1"
    git checkout --quiet "$1"
    git pull --quiet --ff-only origin "$1"
  ' _ "$BRANCH"
  echo "repo at: $(git log -1 --oneline --no-decorate)"
  docker compose pull --quiet "$SVC"
fi

# new image and/or new mounted files -> force a fresh start
docker compose up -d --no-deps --force-recreate "$SVC"

if [ -n "$BRANCH" ]; then
  mkdir -p "$GITDIR/deployed"
  git rev-parse HEAD > "$GITDIR/deployed/$SVC"
fi

docker compose ps "$SVC"