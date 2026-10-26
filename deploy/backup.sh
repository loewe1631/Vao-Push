#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${VAO_ROOT:?Set VAO_ROOT to the private deployment directory}"
container=${VAO_POSTGRES_CONTAINER:-vao-push-postgres}
backup="$VAO_ROOT/run/backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup"
docker exec "$container" pg_dump -U vaopush -Fc vaopush > "$backup/database.dump"
cp "$VAO_ROOT/run/config.json" "$backup/config.json"
cp "$VAO_ROOT/run/database.env" "$backup/database.env"
chmod 600 "$backup/"*
# This private backup includes credentials and the encryption master key.
# Copy it to separately encrypted storage under the operator's backup policy.
