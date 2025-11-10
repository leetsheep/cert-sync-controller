#!/bin/bash
# cert-sync-controller - Continuous reconciliation loop
# Watches for certificate changes and syncs to remote (e.g. Edge proxy)

set -e

echo "[INIT] Starting cert-sync-controller..."

# Configuration from environment with defaults
PROXY_IP="${PROXY_IP}"  # Required, no default
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-30}"
REMOTE_USER="${REMOTE_USER:-cert-sync}"
REMOTE_CERT_DIR="${REMOTE_CERT_DIR:-/opt/traefik/certs}"
REMOTE_CONFIG_DIR="${REMOTE_CONFIG_DIR:-/etc/traefik/config}"
SSH_KEY_PATH="${SSH_KEY_PATH:-/secrets/id_rsa}"
SSH_TIMEOUT="${SSH_TIMEOUT:-5}"
DEBUG="${DEBUG:-false}"
SKIP_CONFIG_GENERATION="${SKIP_CONFIG_GENERATION:-false}"

# Validate required configuration
if [ -z "$PROXY_IP" ]; then
  echo "[ERROR] PROXY_IP environment variable is required"
  exit 1
fi

# Private temp directory for sensitive data (not /tmp)
TMPDIR=/home/cert-sync/.cache/cert-sync
HEARTBEAT_FILE=$TMPDIR/heartbeat
METRICS_FILE=$TMPDIR/metrics
CERT_HASH_FILE=$TMPDIR/cert_hashes

# Statistics
TOTAL_SYNCS=0
SUCCESS_SYNCS=0
FAILED_SYNCS=0
LAST_SYNC_TIME=0

# Debug logging
debug_log() {
  if [ "$DEBUG" = "true" ]; then
    echo "[DEBUG] $*"
  fi
}

# Setup environment
setup() {
  echo "[INIT] Configuration:"
  echo "  Proxy: ${REMOTE_USER}@${PROXY_IP}"
  echo "  Remote cert dir: ${REMOTE_CERT_DIR}"
  echo "  Remote config dir: ${REMOTE_CONFIG_DIR}"
  echo "  SSH key: ${SSH_KEY_PATH}"
  echo "  Reconcile interval: ${RECONCILE_INTERVAL}s"
  echo "  Skip config generation: ${SKIP_CONFIG_GENERATION}"

  echo "[INIT] Configuring SSH..."
  mkdir -p ~/.ssh

  if [ -f "$SSH_KEY_PATH" ]; then
    cp "$SSH_KEY_PATH" ~/.ssh/id_rsa
    chmod 600 ~/.ssh/id_rsa
    debug_log "SSH key copied and permissions set"
  else
    echo "[ERROR] SSH key not found at $SSH_KEY_PATH"
    exit 1
  fi

  # Add proxy to known hosts
  echo "[INIT] Adding proxy to known hosts..."
  if ssh-keyscan -H "$PROXY_IP" >> ~/.ssh/known_hosts 2>/dev/null; then
    debug_log "Proxy added to known hosts"
  else
    echo "[WARN] Could not add proxy to known hosts, continuing anyway..."
  fi

  # Initialize hash tracking file
  touch "$CERT_HASH_FILE"

  echo "[INIT] Testing kubectl access..."
  if ! kubectl get nodes >/dev/null 2>&1; then
    echo "[ERROR] Cannot access Kubernetes API"
    exit 1
  fi

  # Test SSH connection
  echo "[INIT] Testing SSH connection to proxy..."
  if ssh -i ~/.ssh/id_rsa -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
     "${REMOTE_USER}@${PROXY_IP}" "echo 'SSH OK'" >/dev/null 2>&1; then
    echo "[INIT] SSH connection successful"
  else
    echo "[WARN] Cannot connect to proxy via SSH - will retry during sync"
  fi

  echo "[INIT] Setup complete"
}

# Write metrics for Prometheus
write_metrics() {
  cat > "$METRICS_FILE" <<EOF
# HELP cert_sync_controller_up Controller status (1=up, 0=down)
# TYPE cert_sync_controller_up gauge
cert_sync_controller_up 1

# HELP cert_sync_total_syncs Total number of sync operations
# TYPE cert_sync_total_syncs counter
cert_sync_total_syncs $TOTAL_SYNCS

# HELP cert_sync_success_syncs Successful sync operations
# TYPE cert_sync_success_syncs counter
cert_sync_success_syncs $SUCCESS_SYNCS

# HELP cert_sync_failed_syncs Failed sync operations
# TYPE cert_sync_failed_syncs counter
cert_sync_failed_syncs $FAILED_SYNCS

# HELP cert_sync_last_sync_timestamp Unix timestamp of last sync
# TYPE cert_sync_last_sync_timestamp gauge
cert_sync_last_sync_timestamp $LAST_SYNC_TIME
EOF
}

# Start metrics server
start_metrics_server() {
  while true; do
    write_metrics
    {
      echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"
      cat "$METRICS_FILE"
    } | nc -l -p 9090 >/dev/null 2>&1
  done &
  echo "[METRICS] Metrics server started on :9090"
}

# Check if certificate has changed
has_cert_changed() {
  local domain=$1
  local current_hash=$2

  # Get stored hash
  local stored_hash=$(grep "^$domain:" "$CERT_HASH_FILE" 2>/dev/null | cut -d: -f2)

  if [ "$stored_hash" = "$current_hash" ]; then
    return 1  # No change
  else
    # Update stored hash
    grep -v "^$domain:" "$CERT_HASH_FILE" > "$CERT_HASH_FILE.tmp" 2>/dev/null || true
    echo "$domain:$current_hash" >> "$CERT_HASH_FILE.tmp"
    mv "$CERT_HASH_FILE.tmp" "$CERT_HASH_FILE"
    return 0  # Changed
  fi
}

# Sync certificate to proxy
sync_certificate() {
  local namespace=$1
  local secret=$2
  local domain=$3

  # Create secure temporary files with random names
  local TMPFILE_CERT=$(mktemp "$TMPDIR/cert.XXXXXX")
  local TMPFILE_KEY=$(mktemp "$TMPDIR/key.XXXXXX")
  local TMPFILE_CONFIG=$(mktemp "$TMPDIR/config.XXXXXX")

  # Set secure permissions immediately
  chmod 600 "$TMPFILE_CERT" "$TMPFILE_KEY" "$TMPFILE_CONFIG"

  # Cleanup trap: guaranteed deletion on function exit
  trap "rm -f '$TMPFILE_CERT' '$TMPFILE_KEY' '$TMPFILE_CONFIG'" RETURN

  TOTAL_SYNCS=$((TOTAL_SYNCS + 1))

  echo "  🔍 Checking $domain (secret: $namespace/$secret)"
  debug_log "Fetching certificate data from secret $namespace/$secret"

  # Get certificate data
  local cert_data=$(kubectl get secret "$secret" -n "$namespace" \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null)

  local key_data=$(kubectl get secret "$secret" -n "$namespace" \
    -o jsonpath='{.data.tls\.key}' 2>/dev/null)

  if [ -z "$cert_data" ] || [ -z "$key_data" ]; then
    echo "    ⚠️  No certificate data found"
    FAILED_SYNCS=$((FAILED_SYNCS + 1))
    return 1  # trap will cleanup
  fi

  # Calculate hash
  local current_hash=$(echo "${cert_data}${key_data}" | sha256sum | cut -d' ' -f1)
  debug_log "Certificate hash: ${current_hash:0:16}..."

  # Check if changed
  if ! has_cert_changed "$domain" "$current_hash"; then
    echo "    ↔️  Unchanged (hash: ${current_hash:0:8}...)"
    SUCCESS_SYNCS=$((SUCCESS_SYNCS + 1))
    return 0
  fi

  echo "    📦 Syncing certificate (hash: ${current_hash:0:8}...)"

  # Decode certificate data to secure temporary files
  echo "$cert_data" | base64 -d > "$TMPFILE_CERT"
  echo "$key_data" | base64 -d > "$TMPFILE_KEY"

  # Validate certificate
  if ! openssl x509 -in "$TMPFILE_CERT" -noout 2>/dev/null; then
    echo "    ❌ Invalid certificate format"
    FAILED_SYNCS=$((FAILED_SYNCS + 1))
    return 1  # trap will cleanup
  fi

  # Get certificate expiry
  local expiry=$(openssl x509 -in "$TMPFILE_CERT" -noout -enddate | cut -d= -f2)
  echo "    📅 Expires: $expiry"

  # Test SSH connection first
  debug_log "Testing SSH connection to ${REMOTE_USER}@${PROXY_IP}"
  if ! ssh -i ~/.ssh/id_rsa -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
       "${REMOTE_USER}@${PROXY_IP}" "echo 'SSH OK'" >/dev/null 2>&1; then
    echo "    ❌ Cannot connect to proxy via SSH"
    FAILED_SYNCS=$((FAILED_SYNCS + 1))
    return 1  # trap will cleanup
  fi

  # Create directory on proxy
  local remote_cert_path="${REMOTE_CERT_DIR}/${domain}"
  debug_log "Creating directory: $remote_cert_path"

  if ! ssh -i ~/.ssh/id_rsa -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
       "${REMOTE_USER}@${PROXY_IP}" "mkdir -p $remote_cert_path" 2>/dev/null; then
    echo "    ❌ Failed to create directory on proxy"
    FAILED_SYNCS=$((FAILED_SYNCS + 1))
    return 1  # trap will cleanup
  fi

  # Copy certificates (rename to tls.crt/tls.key on proxy)
  debug_log "Copying certificates to $remote_cert_path"
  if scp -i ~/.ssh/id_rsa -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
       "$TMPFILE_CERT" "${REMOTE_USER}@${PROXY_IP}:${remote_cert_path}/tls.crt" 2>/dev/null && \
     scp -i ~/.ssh/id_rsa -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
       "$TMPFILE_KEY" "${REMOTE_USER}@${PROXY_IP}:${remote_cert_path}/tls.key" 2>/dev/null; then

    # Set permissions on certificates
    ssh -i ~/.ssh/id_rsa -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
      "${REMOTE_USER}@${PROXY_IP}" \
      "chmod 600 ${remote_cert_path}/*" 2>/dev/null

    # Generate and copy config file (unless skipped)
    if [ "$SKIP_CONFIG_GENERATION" = "false" ]; then
      # Create Traefik config
      cat > "$TMPFILE_CONFIG" <<EOF
tls:
  certificates:
    - certFile: ${remote_cert_path}/tls.crt
      keyFile: ${remote_cert_path}/tls.key
      stores:
        - default
EOF

      # Copy config and set permissions
      debug_log "Copying config to ${REMOTE_CONFIG_DIR}/${domain}.yml"
      if scp -i ~/.ssh/id_rsa -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
           "$TMPFILE_CONFIG" \
           "${REMOTE_USER}@${PROXY_IP}:${REMOTE_CONFIG_DIR}/${domain}.yml" 2>/dev/null; then
        ssh -i ~/.ssh/id_rsa -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
          "${REMOTE_USER}@${PROXY_IP}" \
          "chmod 644 ${REMOTE_CONFIG_DIR}/${domain}.yml" 2>/dev/null
      else
        echo "    ⚠️  Failed to copy config file (continuing anyway)"
      fi
    else
      debug_log "Skipping config generation (SKIP_CONFIG_GENERATION=true)"
    fi

    echo "    ✅ Synced successfully"
    SUCCESS_SYNCS=$((SUCCESS_SYNCS + 1))
    return 0  # trap will cleanup
  fi

  echo "    ❌ Sync failed"
  FAILED_SYNCS=$((FAILED_SYNCS + 1))
  return 1  # trap will cleanup
}

# Reconciliation loop
reconcile() {
  echo ""
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting reconciliation..."

  local found_certs=0

  # Get all ingresses with TLS
  while IFS=: read -r namespace secret domain; do
    if [ -n "$namespace" ] && [ -n "$secret" ] && [ -n "$domain" ]; then
      found_certs=$((found_certs + 1))
      sync_certificate "$namespace" "$secret" "$domain"
    fi
  done < <(kubectl get ingress -A -o json 2>/dev/null | jq -r '.items[] |
    select(.spec.tls != null) |
    .metadata.namespace as $ns |
    .spec.tls[] |
    "\($ns):\(.secretName):\(.hosts[0])"')

  # Also check for standalone Certificate resources
  while IFS=: read -r namespace name domain; do
    if [ -n "$namespace" ] && [ -n "$name" ] && [ -n "$domain" ]; then
      found_certs=$((found_certs + 1))
      sync_certificate "$namespace" "$name" "$domain"
    fi
  done < <(kubectl get certificates -A -o json 2>/dev/null | jq -r '.items[] |
    "\(.metadata.namespace):\(.spec.secretName):\(.spec.dnsNames[0])"')

  LAST_SYNC_TIME=$(date +%s)
  date +%s > "$HEARTBEAT_FILE"

  # Summary
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Reconciliation complete"
  echo "  📊 Found: $found_certs | Total: $TOTAL_SYNCS | ✅ Success: $SUCCESS_SYNCS | ❌ Failed: $FAILED_SYNCS"
}

# Health check endpoint
start_health_server() {
  while true; do
    {
      if [ -f "$HEARTBEAT_FILE" ]; then
        local last_heartbeat=$(cat "$HEARTBEAT_FILE")
        local current_time=$(date +%s)
        local diff=$((current_time - last_heartbeat))

        if [ $diff -lt 120 ]; then
          echo -e "HTTP/1.1 200 OK\r\n\r\nhealthy"
        else
          echo -e "HTTP/1.1 503 Service Unavailable\r\n\r\nstale"
        fi
      else
        echo -e "HTTP/1.1 503 Service Unavailable\r\n\r\nno heartbeat"
      fi
    } | nc -l -p 8080 >/dev/null 2>&1
  done &
  echo "[HEALTH] Health check server started on :8080"
}

# Signal handlers
trap 'echo "[EXIT] Received SIGTERM, shutting down..."; exit 0' TERM
trap 'echo "[EXIT] Received SIGINT, shutting down..."; exit 0' INT

# Main execution
main() {
  setup
  start_metrics_server
  start_health_server

  echo "[MAIN] Starting reconciliation loop (interval: ${RECONCILE_INTERVAL}s)"

  # Initial reconciliation
  reconcile

  # Continuous reconciliation
  while true; do
    sleep "$RECONCILE_INTERVAL"
    reconcile
  done
}

# Start controller
main