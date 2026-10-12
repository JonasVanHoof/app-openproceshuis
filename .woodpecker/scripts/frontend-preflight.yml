#!/usr/bin/env bash
# Runs ON the server. Pulls the frontend image (download only, the running
# container is not touched) and compares it with the running container.
#   ssh deploy bash -s -- <APP_DIR> < deploy/frontend-preflight.sh
# Prints key=value lines: image, changed=true|false, reason
set -e
cd "$1"

docker compose pull --quiet frontend

IMAGE=$(docker compose config --images frontend)
WANT_IMG=$(docker image inspect -f '{{.Id}}' "$IMAGE")
CID=$(docker compose ps -a -q frontend)
echo "image=$IMAGE"

if [ -z "$CID" ]; then
  echo "changed=true"
  echo "reason=no frontend container yet"
elif [ "$WANT_IMG" != "$(docker inspect -f '{{.Image}}' "$CID")" ]; then
  echo "changed=true"
  echo "reason=new image available for $IMAGE"
elif [ "$(docker compose config --hash frontend | awk '{print $2}')" \
     != "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$CID")" ]; then
  echo "changed=true"
  echo "reason=frontend config changed in docker-compose"
else
  echo "changed=false"
fi