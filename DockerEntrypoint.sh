#!/bin/sh
set -eu

# Map the platform PORT to XUI_PORT (Railway injects PORT). Default to 8080.
if [ -n "${PORT:-}" ] && [ -z "${XUI_PORT:-}" ]; then
  export XUI_PORT="${PORT}"
fi
: "${XUI_PORT:=8080}"

# Ensure we have a sane default for runtime folders
export XUI_MAIN_FOLDER="${XUI_MAIN_FOLDER:-/app}"
export XUI_LOG_FOLDER="${XUI_LOG_FOLDER:-/var/log/x-ui}"
export XUI_BIN_FOLDER="${XUI_BIN_FOLDER:-/app/bin}"

# Gracefully disable fail2ban when kernel capabilities or tools are not present
if [ "${XUI_ENABLE_FAIL2BAN:-true}" = "true" ]; then
  if ! command -v iptables >/dev/null 2>&1 || ! command -v fail2ban-client >/dev/null 2>&1; then
    echo "Entrypoint: fail2ban requested but iptables/fail2ban-client not available; disabling fail2ban"
    export XUI_ENABLE_FAIL2BAN=false
  fi
fi

# Wait for Postgres (if configured) before starting the app. This makes the
# container 'self-healing' on initial deploys where the DB may come up slightly
# later than the app.
wait_for_postgres() {
  if [ "${XUI_DB_TYPE:-sqlite}" = "postgres" ] || [ "${XUI_DB_TYPE:-postgresql}" = "postgresql" ]; then
    if [ -z "${XUI_DB_DSN:-}" ]; then
      echo "Entrypoint: XUI_DB_TYPE=postgres set but XUI_DB_DSN is empty — continuing and letting app handle it"
      return
    fi

    # Extract host[:port] from DSN of the form postgres://user:pass@host:port/db?params
    HOSTPORT=$(echo "$XUI_DB_DSN" | sed -n 's|.*@\([^/?]*\).*|\1|p' || true)
    HOST=$(echo "$HOSTPORT" | cut -d: -f1)
    PORT_DSN=$(echo "$HOSTPORT" | cut -s -d: -f2)
    if [ -z "$HOST" ] || [ "$HOST" = "$XUI_DB_DSN" ]; then
      echo "Entrypoint: could not parse host from XUI_DB_DSN ($XUI_DB_DSN); continuing"
      return
    fi
    : "${PORT_DSN:=5432}"

    # Use nc to probe the TCP port (netcat should be available in the image)
    echo "Entrypoint: waiting for Postgres at ${HOST}:${PORT_DSN}"
    tries=0
    max_tries=60
    until nc -z "$HOST" "$PORT_DSN"; do
      tries=$((tries+1))
      if [ "$tries" -ge "$max_tries" ]; then
        echo "Entrypoint: Postgres did not respond after ${max_tries} tries — proceeding and allowing the app to retry internally"
        break
      fi
      sleep 2
    done
    echo "Entrypoint: Postgres appears reachable (or attempts exhausted) — continuing"
  fi
}

# Run optional migrations / setup steps. Keep idempotent & tolerant of failure.
run_migrations() {
  # If XUI_DB_TYPE=postgres and migrate options are present, prefer app-managed init.
  if [ "${XUI_DB_TYPE:-sqlite}" = "postgres" ] || [ "${XUI_DB_TYPE:-postgresql}" = "postgresql" ]; then
    if [ -n "${XUI_DB_DSN:-}" ]; then
      echo "Entrypoint: attempting a no-op migration check (safe)"
      # The migrate-db command supports --dsn to migrate sqlite -> postgres, but
      # calling migrate-db with only --dsn when no sqlite source exists is safe
      # (the app will report nothing to do) — capture errors but don't fail.
      if /app/x-ui migrate-db --dsn "${XUI_DB_DSN}" >/dev/null 2>&1; then
        echo "Entrypoint: migrate-db ran (or no-op) successfully"
      else
        echo "Entrypoint: migrate-db returned a non-fatal error; continuing"
      fi
    fi
  fi
}

# Forward signals to child and wait
_child_pid=0
_forward_signal() {
  sig="$1"
  echo "Entrypoint: received signal $sig -> forwarding to pid $_child_pid"
  if [ "$_child_pid" -ne 0 ]; then
    kill -"$sig" "$_child_pid" 2>/dev/null || true
  fi
}

trap ' _forward_signal TERM; exit 0' TERM
trap ' _forward_signal INT; exit 0' INT

# Start the application in a supervised loop so it auto-restarts on crashes.
# Also perform a basic port check to ensure the app opened its listening socket.
supervise_app() {
  while true; do
    echo "Entrypoint: starting x-ui (XUI_PORT=${XUI_PORT})"
    /app/x-ui &
    _child_pid=$!

    # Wait up to N seconds for the app to listen on XUI_PORT
    listen_tries=0
    max_listen_tries=30
    until nc -z 127.0.0.1 "$XUI_PORT"; do
      listen_tries=$((listen_tries+1))
      if [ "$listen_tries" -ge "$max_listen_tries" ]; then
        echo "Entrypoint: app did not open port ${XUI_PORT} after ${max_listen_tries}s"
        break
      fi
      sleep 1
    done

    # Tail logs of the process; when it exits the wait returns and we restart
    wait "$_child_pid" || true
    exit_code=$?
    echo "Entrypoint: x-ui exited with code ${exit_code}; restarting in 5s"
    _child_pid=0
    sleep 5
  done
}

# Main startup flow
# 1) Ensure netcat exists
if ! command -v nc >/dev/null 2>&1; then
  echo "Entrypoint: netcat (nc) missing — installing fallback busybox nc is expected but may not exist"
  # If nc missing, continue — healthcheck might not work as expected
fi

# 2) Wait for Postgres if configured
wait_for_postgres

# 3) Run any safe migrations (idempotent)
run_migrations

# 4) Start supervised app
supervise_app
