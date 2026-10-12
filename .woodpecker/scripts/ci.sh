#!/bin/sh
# Runs IN the Woodpecker step container (alpine). One subcommand per step, so
# each step in deploy.yml is a single command and the UI log stays readable:
#   sh .woodpecker/scripts/ci.sh <step> [args]
# The work on the server is done by the other scripts in this folder, piped over ssh.
set -eu
DIR=.woodpecker/scripts

ssh_tools() {
  command -v ssh >/dev/null 2>&1 || apk add -q --no-cache openssh-client >/dev/null
}

# on_server <script> <args...>: run a script from $DIR on the server
on_server() {
  script=$1; shift
  ssh -F .ssh/config target bash -s -- "$@" < "$DIR/$script"
}

# capture <outfile> <script> <args...>: run on the server, keep the key=value
# output in <outfile> for later steps, print it readable, keep the exit code
capture() {
  out=$1; shift
  rc=0
  on_server "$@" > "$out" 2>&1 || rc=$?
  sed -e 's/^info=//' -e 's/^blocker=/blocker: /' -e 's/^warning=/WARNING: /' "$out"
  return "$rc"
}

# guard against moving the repo when checkout is blocked
require_checkout() {
  . ./preflight.env
  if [ "$sync_needed" = true ] && [ "$checkout_possible" != true ]; then
    echo "ERROR: cannot switch to $BRANCH on the server, manual intervention needed (see server-preflight)."
    exit 1
  fi
}

step=$1; shift
case "$step" in
  ssh-setup)
    ssh_tools
    mkdir -p .ssh && chmod 700 .ssh
    printf '%s\n' "$DEPLOY_SSH_KEY" > .ssh/id_ed25519
    printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > .ssh/known_hosts
    chmod 600 .ssh/id_ed25519 .ssh/known_hosts
    cat > .ssh/config <<CFG
Host target
  HostName $DEPLOY_HOST
  User $DEPLOY_USER
  IdentityFile $CI_WORKSPACE/.ssh/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $CI_WORKSPACE/.ssh/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
CFG
    ssh -F .ssh/config target 'echo "connected to $(hostname)"'
    ;;

  server-preflight)
    ssh_tools
    capture preflight.txt server-preflight.sh "$APP_DIR" "$BRANCH"
    grep -E '^(current_branch|checkout_possible|sync_needed)=' preflight.txt > preflight.env
    if grep -q '^checkout_possible=false' preflight.txt; then
      echo "WARNING: checkout of $BRANCH not possible on the server (see blockers above)."
    fi
    ;;

  base-services)
    ssh_tools
    . ./preflight.env
    if [ "$sync_needed" = true ] && [ "$checkout_possible" = true ]; then
      echo "== repo pull =="
      on_server repo-pull.sh "$APP_DIR" "$BRANCH" $MARKER_SERVICES
    else
      echo "== repo pull: skipped (sync_needed=$sync_needed, checkout_possible=$checkout_possible) =="
    fi
    echo
    echo "== base services =="
    capture base.txt base-services.sh "$APP_DIR" $BASE_SERVICES
    if ! grep -q '^base_ok=true' base.txt; then
      echo "ERROR: one or more base services are not running/healthy (see table above)."
      exit 1
    fi
    ;;

  frontend-preflight)
    ssh_tools
    capture frontend.txt frontend-preflight.sh "$APP_DIR"
    grep '^changed=' frontend.txt > frontend.env
    ;;

  # service-preflight <service> <watch-folder> <added|any>
  service-preflight)
    require_checkout
    ssh_tools
    capture "$1.txt" service-preflight.sh "$APP_DIR" "$BRANCH" "$1" "$2" "$3"
    grep '^changed=' "$1.txt" > "$1.env"
    ;;

  # release <service> [marker]: only on the button / manual runs, only when selected and changed
  release)
    svc=$1; mode=${2:-}
    case "$CI_PIPELINE_EVENT" in
      manual|deployment) ;;
      *) echo "Preflight only ($CI_PIPELINE_EVENT run): $svc not rolled out."
         echo "To roll out: press the button at the top of this pipeline, target: development."
         exit 0 ;;
    esac
    case ",${SERVICES:-all}," in
      *,all,*|*,"$svc",*) ;;
      *) echo "$svc not selected (SERVICES=${SERVICES:-}), skipped."; exit 0 ;;
    esac
    . "./$svc.env"
    if [ "$changed" != true ]; then
      echo "$svc is up to date, nothing to roll out."
      exit 0
    fi
    ssh_tools
    on_server deploy-service.sh "$APP_DIR" "$svc" $mode
    touch ".rolled-out-$svc"
    ;;

  restart-cache)
    if [ ! -e .rolled-out-migrations ] && [ ! -e .rolled-out-resource ]; then
      echo "No migrations or resource rollout, cache untouched."
      exit 0
    fi
    ssh_tools
    ssh -F .ssh/config target "cd '$APP_DIR' && docker compose restart cache && docker compose ps cache"
    ;;

  *)
    echo "unknown step: $step" >&2
    exit 2
    ;;
esac