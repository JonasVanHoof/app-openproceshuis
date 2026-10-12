#!/usr/bin/env bash
# Runs ON the server. Recreates one compose service on the already-pulled repo.
#   ssh deploy bash -s -- <APP_DIR> <SERVICE> [marker] < .woodpecker/scripts/deploy-service.sh
#
# Without "marker" (frontend): uses the image the preflight already pulled, so it
#   deploys exactly what was checked.
# With "marker" (migrations, resource): pulls the image, force-recreates (new
#   mounted files don't change the compose config), and records the deployed
#   commit in .git/deployed/<SERVICE> for the service preflight.
set -e
cd "$1"
SVC=$2
MODE=${3:-}

if [ "$MODE" = marker ]; then
  GITDIR=$(git rev-parse --git-dir)
  echo "repo at: $(git log -1 --oneline --no-decorate)"
  docker compose pull --quiet "$SVC"
  docker compose up -d --no-deps --force-recreate "$SVC"
  mkdir -p "$GITDIR/deployed"
  git rev-parse HEAD > "$GITDIR/deployed/$SVC"
else
  docker compose up -d --no-deps "$SVC"
fi

docker compose ps "$SVC"
