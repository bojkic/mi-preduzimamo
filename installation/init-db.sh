#!/usr/bin/env bash
set -euo pipefail
# This file runs only during initialization of this project's empty PG volume.
[[ "${POSTGRES_DB:-}" == mi_platform && "${POSTGRES_USER:-}" == postgres ]]
[[ "${MI_APP_DATABASE_PASSWORD:-}" =~ ^[0-9a-f]{64}$ ]]
psql -X --username postgres --dbname mi_platform -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE mi_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE EXTENSION IF NOT EXISTS ltree;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
ALTER DATABASE mi_platform OWNER TO mi_app;
SQL
# psql's password command encrypts the password before sending it. The secret
# travels over stdin, never argv or a printed SQL literal.
printf '%s\n%s\n' "$MI_APP_DATABASE_PASSWORD" "$MI_APP_DATABASE_PASSWORD" | psql -X --username postgres --dbname mi_platform -v ON_ERROR_STOP=1 -c '\password mi_app'
unset MI_APP_DATABASE_PASSWORD
