#!/usr/bin/env bash
set -euo pipefail
: "${1:?Pass a private database.dump file}"
container=${VAO_POSTGRES_CONTAINER:-vao-push-postgres}
restore_db="vao_restore_check_$(date +%s)"
cleanup() { docker exec "$container" dropdb -U vaopush --if-exists "$restore_db" >/dev/null; }
trap cleanup EXIT
docker exec "$container" createdb -U vaopush "$restore_db"
docker exec -i "$container" pg_restore -U vaopush -d "$restore_db" --no-owner < "$1"
docker exec "$container" psql -U vaopush -d "$restore_db" -Atc 'SELECT count(*) AS restored_messages FROM messages'
