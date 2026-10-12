#!/usr/bin/env bash
# Runs ON the server. Read-only inspection of the server repo.
#   ssh deploy bash -s -- <APP_DIR> <BRANCH> < .woodpecker/scripts/server-preflight.sh
# Prints key=value lines: current_branch, sync_needed, checkout_possible, info=, blocker=
set -e
cd "$1"
BRANCH=$2
git fetch --quiet origin "$BRANCH"
GITDIR=$(git rev-parse --git-dir)
CURRENT=$(git rev-parse --abbrev-ref HEAD)
echo "current_branch=$CURRENT"

if [ "$CURRENT" != "$BRANCH" ]; then
  echo "sync_needed=true"
  echo "info=server is on '$CURRENT', will switch to '$BRANCH'"
elif [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
  echo "sync_needed=true"
  echo "info=new commits ($(git rev-list --count "HEAD..origin/$BRANCH")):"
  git log --oneline --no-decorate "HEAD..origin/$BRANCH" | sed 's/^/info=  /'
else
  echo "sync_needed=false"
  echo "info=already at origin/$BRANCH: $(git log -1 --oneline --no-decorate)"
fi

blockers=()
[ -f "$GITDIR/MERGE_HEAD" ] && blockers+=("merge in progress")
[ -f "$GITDIR/CHERRY_PICK_HEAD" ] && blockers+=("cherry-pick in progress")
{ [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ]; } && blockers+=("rebase in progress")

while read -r line; do
  [ -n "$line" ] && blockers+=("uncommitted change: $line")
done < <(git status --porcelain --untracked-files=no)

while read -r f; do
  [ -n "$f" ] && git cat-file -e "origin/$BRANCH:$f" 2>/dev/null \
    && blockers+=("untracked file would be overwritten: $f")
done < <(git ls-files --others --exclude-standard)

if git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
   && ! git merge-base --is-ancestor "$BRANCH" "origin/$BRANCH"; then
  blockers+=("local $BRANCH has commits not on origin:")
  while read -r c; do blockers+=("  $c"); done \
    < <(git log --oneline --no-decorate "origin/$BRANCH..$BRANCH")
fi

if [ ${#blockers[@]} -eq 0 ]; then
  echo "checkout_possible=true"
else
  echo "checkout_possible=false"
  printf 'blocker=%s\n' "${blockers[@]}"
fi