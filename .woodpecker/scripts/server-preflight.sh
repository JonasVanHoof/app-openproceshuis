#!/usr/bin/env bash
# Read-only inspection of the server repo. Runs ON the server:
#   ssh deploy bash -s -- <APP_DIR> <BRANCH> < .woodpecker/scripts/server-preflight.sh
# Prints key=value lines: current_branch, sync_needed, checkout_possible, info=, blocker=
set -e
cd "$1"
git fetch --quiet origin "$2"
GITDIR=$(git rev-parse --git-dir)
CURRENT=$(git rev-parse --abbrev-ref HEAD)
echo "current_branch=$CURRENT"

if [ "$CURRENT" != "$2" ]; then
  echo "sync_needed=true"
  echo "info=server is on '$CURRENT', will switch to '$2'"
elif [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$2")" ]; then
  echo "sync_needed=true"
  echo "info=new commits ($(git rev-list --count "HEAD..origin/$2")):"
  git log --oneline --no-decorate "HEAD..origin/$2" | sed 's/^/info=  /'
else
  echo "sync_needed=false"
  echo "info=already at origin/$2: $(git log -1 --oneline --no-decorate)"
fi

blockers=()
[ -f "$GITDIR/MERGE_HEAD" ] && blockers+=("merge in progress")
[ -f "$GITDIR/CHERRY_PICK_HEAD" ] && blockers+=("cherry-pick in progress")
{ [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; } && blockers+=("rebase in progress")

while read -r line; do
  [ -n "$line" ] && blockers+=("uncommitted change: $line")
done < <(git status --porcelain --untracked-files=no)

# untracked files that exist in origin/$2 would be overwritten by checkout
while read -r f; do
  [ -n "$f" ] && git cat-file -e "origin/$2:$f" 2>/dev/null \
    && blockers+=("untracked file would be overwritten: $f")
done < <(git ls-files --others --exclude-standard)

# local $2 must be able to fast-forward to origin/$2
if git rev-parse --verify --quiet "refs/heads/$2" >/dev/null \
   && ! git merge-base --is-ancestor "$2" "origin/$2"; then
  blockers+=("local $2 has commits not on origin:")
  while read -r c; do blockers+=("  $c"); done \
    < <(git log --oneline --no-decorate "origin/$2..$2")
fi

if [ ${#blockers[@]} -eq 0 ]; then
  echo "checkout_possible=true"
else
  echo "checkout_possible=false"
  printf 'blocker=%s\n' "${blockers[@]}"
fi