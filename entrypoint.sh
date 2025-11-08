#!/usr/bin/env bash
set -euo pipefail

# Defaults are set in Dockerfile ENV and can be overridden at runtime.
: "${VARNISH_VCL:=/etc/varnish/default.vcl}"
: "${VARNISH_LISTEN:=:80}"
: "${VARNISH_MGMT:=:6082}"
: "${VARNISH_STORAGE:=malloc,512m}"
: "${HAPROXY_CFG:=/etc/haproxy/haproxy.cfg}"

# Render templates with envsubst (simple ${VAR} placeholders)
render() {
  local in="$1" out="$2"
  if [[ -f "$in" ]]; then
    envsubst <"$in" >"$out"
    echo "[entrypoint] Rendered $out from $(basename "$in")"
  else
    echo "[entrypoint] WARNING: Template $in not found; skipping"
  fi
}

# Render configs
render /templates/default.vcl.tmpl "$VARNISH_VCL"
render /templates/haproxy.cfg.tmpl "$HAPROXY_CFG"

# Validate configs
echo "[entrypoint] Validating Varnish VCL..."
if ! varnishd -C -f "$VARNISH_VCL" >/dev/null 2>&1; then
  echo "[entrypoint] ERROR: Varnish VCL validation failed"
  varnishd -C -f "$VARNISH_VCL" || true
  exit 1
fi
echo "[entrypoint] Validating HAProxy config..."
if ! haproxy -c -f "$HAPROXY_CFG"; then
  echo "[entrypoint] ERROR: HAProxy config validation failed"
  exit 1
fi

# Start Varnish (background)
echo "[entrypoint] Starting Varnish..."
varnishd \
  -a "$VARNISH_LISTEN" \
  -T "$VARNISH_MGMT" \
  -s "$VARNISH_STORAGE" \
  -f "$VARNISH_VCL"

# Trap clean shutdown
_term() {
  echo "[entrypoint] Caught SIGTERM, stopping services..."
  # Try to gracefully stop Varnish
  if command -v varnishadm >/dev/null 2>&1; then
    varnishadm -T localhost${VARNISH_MGMT#:} stop || true
  fi
  # Ask HAProxy to stop (if in foreground, it will exit on SIGTERM)
  if command -v socat >/dev/null 2>&1; then
    socat - "exec:haproxy -D -f $HAPROXY_CFG -st $(cat /run/haproxy.pid 2>/dev/null || echo 0)" || true
  fi
  exit 0
}
trap _term TERM INT

# Start HAProxy in foreground so the container lifecycle is tied to it.
# -db keeps it in the foreground, logs to stdout if configured in haproxy.cfg
# If you prefer HAProxy in background and Varnish in foreground, flip the two.
echo "[entrypoint] Starting HAProxy (foreground)..."
exec haproxy -db -f "$HAPROXY_CFG"
