#!/usr/bin/env bash
# Runs ON the server. The ONLY script that moves the server repo.
#   ssh deploy bash -s -- <APP_DIR> <BRANCH> <MARKER_SERVICE>... < .woodpecker/scripts/repo-pull.sh
# Seeds missing .git/deployed/<service> markers at the OLD HEAD before pulling,
# so undeployed changes stay visible to the service preflights.
set -e
cd "$1"
BRANCH=$2
shift 2
GITDIR=$(git rev-parse --git-dir)
# lock in case two pipeline runs overlap
flock "$GITDIR/deploy.lock" bash -c '
  set -e
  GITDIR=$1; BRANCH=$2; shift 2
  mkdir -p "$GITDIR/deployed"
  for svc in "$@"; do
    if [ ! -f "$GITDIR/deployed/$svc" ]; then
      git rev-parse HEAD > "$GITDIR/deployed/$svc"
      echo "marker seeded: $svc at $(git log -1 --format=%h)"
    fi
  done
  echo "before: $(git log -1 --oneline --no-decorate)"
  git fetch --quiet origin "$BRANCH"
  git checkout --quiet "$BRANCH"
  git pull --quiet --ff-only origin "$BRANCH"
  echo "after:  $(git log -1 --oneline --no-decorate)"
' _ "$GITDIR" "$BRANCH" "$@"
