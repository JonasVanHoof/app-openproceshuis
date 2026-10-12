#!/usr/bin/env bash
# Runs ON the server. Read-only: checks that the base services are running
# (and healthy, if they have a healthcheck).
#   ssh deploy bash -s -- <APP_DIR> <SERVICE>... < .woodpecker/scripts/base-services.sh
# Prints a table and a base_ok=true|false line.
cd "$1"
shift
down=0
printf '%-20s %-10s %-10s %s\n' SERVICE STATE HEALTH STATUS
for svc in "$@"; do
  CID=$(docker compose ps -a -q "$svc" 2>/dev/null | head -1)
  if [ -z "$CID" ]; then
    printf '%-20s %-10s %-10s %s\n' "$svc" missing - "no container"
    down=1
    continue
  fi
  STATE=$(docker inspect -f '{{.State.Status}}' "$CID")
  HEALTH=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$CID")
  STATUS=$(docker ps -a --filter "id=$CID" --format '{{.Status}}')
  printf '%-20s %-10s %-10s %s\n' "$svc" "$STATE" "$HEALTH" "$STATUS"
  if [ "$STATE" != running ] || { [ "$HEALTH" != - ] && [ "$HEALTH" != healthy ]; }; then
    down=1
  fi
done
echo
echo "base_ok=$([ $down -eq 0 ] && echo true || echo false)"
