#!/usr/bin/env bash
# Plane AIO deploy script — Podman + private registry
#
# First deploy:    ./deploy.sh
# Update release:  APP_RELEASE=v0.28.0 ./deploy.sh
# Manual rollback: ./deploy.sh --rollback
set -euo pipefail

# ------------------------------------------------------------------ config ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
LOCK_FILE="/tmp/plane-deploy.lock"
LOG_FILE="${SCRIPT_DIR}/deploy.log"
PREV_RELEASE_FILE="${SCRIPT_DIR}/.previous_release"

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
HEALTH_INTERVAL=5

# BSD sed (macOS) needs -i ''; GNU sed (Linux) needs -i
if sed --version &>/dev/null 2>&1; then
  SED_I=(sed -i)
else
  SED_I=(sed -i '')
fi

# ------------------------------------------------------------------ helpers ---
log() {
  local level="$1"; shift
  printf '[%s] [%-5s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}

die() { log ERROR "$*"; exit 1; }

detect_runtime() {
  if command -v podman &>/dev/null; then
    echo "podman"
  elif command -v docker &>/dev/null; then
    echo "docker"
  else
    die "No container runtime found. Install podman or docker."
  fi
}

check_rootless() {
  local runtime="$1"
  [[ "$EUID" -eq 0 ]] && return 0  # running as root — no special handling needed

  log INFO "Rootless mode detected (UID=${EUID})."

  # Docker rootless uses a per-user socket
  if [[ "$runtime" == "docker" ]]; then
    local docker_sock="${XDG_RUNTIME_DIR:-/run/user/${EUID}}/docker.sock"
    if [[ -S "$docker_sock" ]]; then
      export DOCKER_HOST="unix://${docker_sock}"
      log INFO "Set DOCKER_HOST=${DOCKER_HOST}"
    else
      log WARN "Docker rootless socket not found at ${docker_sock}. Is dockerd --rootless running?"
    fi
  fi

  # Rootless Podman requires subuid/subgid mappings — without them containers can't
  # create user namespaces and will fail immediately
  if [[ "$runtime" == "podman" ]]; then
    local missing=()
    grep -q "^${USER}:" /etc/subuid 2>/dev/null || missing+=("/etc/subuid")
    grep -q "^${USER}:" /etc/subgid 2>/dev/null || missing+=("/etc/subgid")
    if (( ${#missing[@]} > 0 )); then
      log WARN "User '${USER}' has no entries in: ${missing[*]}"
      log WARN "Rootless Podman needs subordinate UID/GID mappings to run containers."
      local answer
      read -rp "  Run 'usermod --add-subuids/subgids 100000-165535' for '${USER}' now? [Y/n]: " answer
      answer="${answer:-Y}"
      if [[ "$answer" =~ ^[Yy] ]]; then
        sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
        log INFO "Subordinate UID/GID mappings added for ${USER}."
        log WARN "Run 'podman system migrate' or log out/in for the mapping to take effect."
      else
        log WARN "Skipping. Rootless Podman will likely fail without subuid/subgid mappings."
      fi
    fi
  fi

  # Ports < 1024 are blocked for unprivileged users
  local http_port="${LISTEN_HTTP_PORT:-8080}"
  if (( http_port < 1024 )); then
    local unpriv
    unpriv=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo "1024")
    if (( http_port < unpriv )); then
      log WARN "Port ${http_port} requires root or lowering net.ipv4.ip_unprivileged_port_start."
      log WARN "Run: sudo sysctl -w net.ipv4.ip_unprivileged_port_start=${http_port}"
      log WARN "Or set LISTEN_HTTP_PORT=8080 in .env to use an unprivileged port."
    fi
  fi

  # Containers stop when the SSH session ends unless linger is enabled
  if command -v loginctl &>/dev/null; then
    if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
      log WARN "Linger is not enabled — containers will stop when you disconnect SSH."
      local answer
      read -rp "  Enable linger for '${USER}' now (keeps containers alive after logout)? [Y/n]: " answer
      answer="${answer:-Y}"
      if [[ "$answer" =~ ^[Yy] ]]; then
        loginctl enable-linger "$USER"
        log INFO "Linger enabled for ${USER}. Containers will survive SSH disconnects."
      else
        log WARN "Skipping. Plane will stop when you disconnect SSH."
      fi
    fi
  fi
}

detect_compose() {
  if command -v podman-compose &>/dev/null; then
    echo "podman-compose"
  elif command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    die "No compose tool found. Install podman-compose: pip3 install podman-compose"
  fi
}

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid; pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      die "Deploy already in progress (PID $pid). Aborting."
    fi
    log WARN "Removing stale lock (PID $pid was not running)."
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"; grep -q "^SETUP_COMPLETE=1" "$ENV_FILE" 2>/dev/null || { log WARN "Removing incomplete .env"; rm -f "$ENV_FILE"; }' EXIT
}

set_env_var() {
  local key="$1" val="$2"
  local esc; esc=$(printf '%s' "$val" | sed 's/[|&\]/\\&/g')
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    "${SED_I[@]}" "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

prompt_secret() {
  local prompt="$1"
  local val
  read -rsp "  ${prompt} [Enter to auto-generate]: " val; printf '\n' >&2
  if [[ -z "$val" ]]; then
    val=$(openssl rand -hex 16)
    printf '  -> generated\n' >&2
  fi
  printf '%s' "$val"
}

setup_env() {
  [[ -f "${SCRIPT_DIR}/.env.example" ]] || die ".env.example not found at ${SCRIPT_DIR}/.env.example"
  log INFO "First-time setup — creating .env from .env.example"
  cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE"

  # Data directory
  local data_dir
  read -rp "  Persistent data directory [${SCRIPT_DIR}/data]: " data_dir
  data_dir="${data_dir:-${SCRIPT_DIR}/data}"
  data_dir="${data_dir/#\~/$HOME}"
  [[ "$data_dir" != /* ]] && data_dir="${SCRIPT_DIR}/${data_dir}"
  set_env_var "DATA_DIR" "$data_dir"

  # Registry
  local registry
  read -rp "  Private registry URL [docker.io]: " registry
  registry="${registry:-docker.io}"
  set_env_var "REGISTRY" "$registry"

  # VM IP
  local vm_ip
  read -rp "  VM IP address [127.0.0.1]: " vm_ip
  vm_ip="${vm_ip:-127.0.0.1}"
  set_env_var "DOMAIN_NAME"          "$vm_ip"
  set_env_var "APP_DOMAIN"           "$vm_ip"
  local http_port="${LISTEN_HTTP_PORT:-8080}"
  set_env_var "WEB_URL"              "http://${vm_ip}:${http_port}"
  set_env_var "CORS_ALLOWED_ORIGINS" "http://${vm_ip}:${http_port}"
  set_env_var "API_BASE_URL"         "http://${vm_ip}:3004"

  # Passwords — prompt with auto-generate fallback
  local pg_pass mq_pass minio_key minio_secret
  pg_pass=$(prompt_secret "PostgreSQL password")
  set_env_var "POSTGRES_PASSWORD" "$pg_pass"
  set_env_var "DATABASE_URL"      "postgresql://plane:${pg_pass}@plane-db/plane"

  mq_pass=$(prompt_secret "RabbitMQ password")
  set_env_var "RABBITMQ_PASSWORD" "$mq_pass"
  set_env_var "AMQP_URL"         "amqp://plane:${mq_pass}@plane-mq:5672/plane"

  minio_key=$(prompt_secret "MinIO access key")
  set_env_var "AWS_ACCESS_KEY_ID" "$minio_key"

  minio_secret=$(prompt_secret "MinIO secret key")
  set_env_var "AWS_SECRET_ACCESS_KEY" "$minio_secret"

  # MinIO must be reachable by the browser — pre-signed upload/download URLs embed
  # this address. Using the VM's public IP on port 9000 (exposed in docker-compose).
  local minio_port="${MINIO_PORT:-9000}"
  set_env_var "AWS_S3_ENDPOINT_URL" "http://${vm_ip}:${minio_port}"

  # Crypto secrets — always auto-generated, no reason to choose manually
  set_env_var "SECRET_KEY"             "$(openssl rand -hex 32)"
  set_env_var "LIVE_SERVER_SECRET_KEY" "$(openssl rand -hex 16)"

  echo "SETUP_COMPLETE=1" >> "$ENV_FILE"
  log INFO ".env written to ${ENV_FILE}"
}

load_env() {
  [[ -f "$COMPOSE_FILE" ]] || die "docker-compose.yml not found at ${COMPOSE_FILE}"
  if [[ -f "$ENV_FILE" ]] && ! grep -q "^SETUP_COMPLETE=1" "$ENV_FILE" 2>/dev/null; then
    log WARN ".env exists but setup was incomplete. Removing and restarting."
    rm -f "$ENV_FILE"
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    setup_env
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# ------------------------------------------------------------------ registry login ---
registry_login() {
  log INFO "Registry login: ${REGISTRY}"
  local reg_user reg_pass
  read -rp "  Registry username (Enter to skip): " reg_user
  if [[ -z "$reg_user" ]]; then
    log INFO "Skipping registry login."
    return 0
  fi
  read -rsp "  Registry password: " reg_pass
  printf '\n'
  $RUNTIME login "${REGISTRY}" \
    --username "$reg_user" \
    --password "$reg_pass" \
    2>&1 | tee -a "$LOG_FILE" \
    || die "Registry login failed."
}

# ------------------------------------------------------------------ compose image parsing ---
# Reads image names from docker-compose.yml and substitutes env vars.
# Avoids duplicating image tags between this script and the compose file.
parse_compose_images() {
  grep '^\s*image:' "$COMPOSE_FILE" \
    | awk '{print $2}' \
    | sed \
        -e "s|\${REGISTRY}|${REGISTRY}|g" \
        -e "s|\${APP_RELEASE:-stable}|${APP_RELEASE:-stable}|g"
}

# ------------------------------------------------------------------ image pull with retry ---
pull_image() {
  local image="$1"
  local attempts=3 delay=15
  for (( i=1; i<=attempts; i++ )); do
    log INFO "Pulling ${image} (attempt ${i}/${attempts})..."
    if $RUNTIME pull "$image" 2>&1 | tee -a "$LOG_FILE"; then
      return 0
    fi
    if (( i < attempts )); then
      log WARN "Pull failed. Retrying in ${delay}s..."
      sleep "$delay"
    fi
  done
  die "Failed to pull ${image} after ${attempts} attempts."
}

pull_infra_images() {
  local img
  while IFS= read -r img; do
    [[ "$img" == *"plane-aio-community"* ]] && continue
    if $RUNTIME image inspect "$img" &>/dev/null; then
      log INFO "Infra image already present, skipping pull: ${img}"
    else
      pull_image "$img"
    fi
  done < <(parse_compose_images)
}

# ------------------------------------------------------------------ health check ---
wait_healthy() {
  log INFO "Health check: ${HEALTH_URL} (timeout ${HEALTH_TIMEOUT}s)"
  local elapsed=0
  while (( elapsed < HEALTH_TIMEOUT )); do
    if curl -sf --max-time 5 "${HEALTH_URL}" &>/dev/null; then
      log INFO "Health check passed after ${elapsed}s."
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
    (( elapsed += HEALTH_INTERVAL ))
    log INFO "  still waiting... ${elapsed}s"
  done
  log ERROR "Health check timed out after ${HEALTH_TIMEOUT}s."
  return 1
}

# ------------------------------------------------------------------ rollback ---
do_rollback() {
  [[ -f "$PREV_RELEASE_FILE" ]] || die "No previous release recorded at ${PREV_RELEASE_FILE}. Cannot roll back."
  local prev; prev=$(cat "$PREV_RELEASE_FILE")
  log WARN "Rolling back to: ${prev}"

  export APP_RELEASE="$prev"
  cd "$SCRIPT_DIR"
  $COMPOSE up -d plane-aio

  if wait_healthy; then
    log INFO "Rollback to ${prev} succeeded."
  else
    die "Rollback health check FAILED. Manual intervention required. Logs: ${LOG_FILE}"
  fi
}

# ------------------------------------------------------------------ firewall ---
configure_firewall() {
  local http_port="${LISTEN_HTTP_PORT:-8080}"
  local https_port="${LISTEN_HTTPS_PORT:-8443}"
  local minio_port="${MINIO_PORT:-9000}"

  # Detect active firewall
  local fw_type="none"
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
    fw_type="firewalld"
  elif command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    fw_type="ufw"
  elif command -v iptables &>/dev/null; then
    fw_type="iptables"
  fi

  if [[ "$fw_type" == "none" ]]; then
    log INFO "No active firewall detected — skipping firewall configuration."
    return 0
  fi
  log INFO "Detected firewall: ${fw_type}"

  # firewalld: --add-forward-port opens port 80 and redirects to http_port in one
  # rule — no need to open http_port separately (firewalld handles this internally)
  if [[ "$fw_type" == "firewalld" ]]; then
    local fwd_set=false https_open=false minio_open=false
    if sudo firewall-cmd --query-forward-port="port=80:proto=tcp:toport=${http_port}" &>/dev/null 2>&1; then
      fwd_set=true
    fi
    if sudo firewall-cmd --query-port="${https_port}/tcp" &>/dev/null 2>&1; then
      https_open=true
    fi
    if sudo firewall-cmd --query-port="${minio_port}/tcp" &>/dev/null 2>&1; then
      minio_open=true
    fi

    if $fwd_set && $https_open && $minio_open; then
      log INFO "firewalld already configured (80→${http_port} forward + ${https_port} + ${minio_port} open). Nothing to do."
      return 0
    fi

    printf '\n'
    log INFO "Firewall changes needed (firewalld):"
    $fwd_set    || log INFO "  - Add forward-port: 80 → ${http_port} (access without port in URL)"
    $https_open || log INFO "  - Open port ${https_port}/tcp"
    $minio_open || log INFO "  - Open port ${minio_port}/tcp (MinIO — required for file uploads)"
    local answer
    read -rp "  Apply firewall changes now (requires sudo)? [Y/n]: " answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Nn] ]]; then
      log WARN "Skipping firewall configuration. The app may not be reachable externally."
      return 0
    fi

    $fwd_set    || sudo firewall-cmd --add-forward-port="port=80:proto=tcp:toport=${http_port}" --permanent
    $https_open || sudo firewall-cmd --add-port="${https_port}/tcp" --permanent
    $minio_open || sudo firewall-cmd --add-port="${minio_port}/tcp" --permanent
    sudo firewall-cmd --reload
    log INFO "Firewall configuration complete."
    return 0
  fi

  # ufw / raw iptables: INPUT chain runs after PREROUTING, so it sees the post-NAT
  # port (http_port), not 80 — http_port must be explicitly opened in addition to
  # the 80→http_port redirect.
  local ports_open=false redirect_set=false

  case "$fw_type" in
    ufw)
      local ufw_status; ufw_status=$(sudo ufw status 2>/dev/null)
      if echo "$ufw_status" | grep -q "${http_port}" && \
         echo "$ufw_status" | grep -q "${https_port}" && \
         echo "$ufw_status" | grep -q "${minio_port}"; then
        ports_open=true
      fi
      ;;
    iptables)
      if sudo iptables -C INPUT -p tcp --dport "$http_port" -j ACCEPT &>/dev/null && \
         sudo iptables -C INPUT -p tcp --dport "$https_port" -j ACCEPT &>/dev/null && \
         sudo iptables -C INPUT -p tcp --dport "$minio_port" -j ACCEPT &>/dev/null; then
        ports_open=true
      fi
      ;;
  esac

  if sudo iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT \
       --to-port "$http_port" &>/dev/null 2>&1; then
    redirect_set=true
  fi

  if $ports_open && $redirect_set; then
    log INFO "Firewall already configured (ports open + 80→${http_port} redirect). Nothing to do."
    return 0
  fi

  printf '\n'
  log INFO "Firewall changes needed (${fw_type}):"
  $ports_open   || log INFO "  - Open ports ${http_port}/tcp, ${https_port}/tcp, and ${minio_port}/tcp (MinIO)"
  $redirect_set || log INFO "  - Add iptables NAT redirect: 80 → ${http_port} (access without port in URL)"
  local answer
  read -rp "  Apply firewall changes now (requires sudo)? [Y/n]: " answer
  answer="${answer:-Y}"
  if [[ "$answer" =~ ^[Nn] ]]; then
    log WARN "Skipping firewall configuration. The app may not be reachable externally."
    return 0
  fi

  if ! $ports_open; then
    log INFO "Opening ports ${http_port}, ${https_port}, and ${minio_port}..."
    case "$fw_type" in
      ufw)
        sudo ufw allow "${http_port}/tcp"
        sudo ufw allow "${https_port}/tcp"
        sudo ufw allow "${minio_port}/tcp"
        sudo ufw reload
        ;;
      iptables)
        sudo iptables -A INPUT -p tcp --dport "$http_port" -j ACCEPT
        sudo iptables -A INPUT -p tcp --dport "$https_port" -j ACCEPT
        sudo iptables -A INPUT -p tcp --dport "$minio_port" -j ACCEPT
        ;;
    esac
    log INFO "Ports ${http_port}, ${https_port}, and ${minio_port} opened."
  fi

  if ! $redirect_set; then
    log INFO "Adding iptables NAT redirect: 80 → ${http_port}..."
    sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port "$http_port"
    log INFO "Redirect 80 → ${http_port} added."

    if command -v netfilter-persistent &>/dev/null; then
      sudo netfilter-persistent save
      log INFO "iptables rules persisted via netfilter-persistent."
    elif command -v iptables-save &>/dev/null && [[ -d /etc/sysconfig ]]; then
      sudo iptables-save | sudo tee /etc/sysconfig/iptables > /dev/null
      log INFO "iptables rules persisted to /etc/sysconfig/iptables."
    else
      log WARN "Could not auto-persist iptables rules — they will be lost on reboot."
      log WARN "To persist: install 'iptables-persistent' (Debian/Ubuntu) or 'iptables-services' (RHEL)."
    fi
  fi

  log INFO "Firewall configuration complete."
}

# ------------------------------------------------------------------ deploy ---
do_deploy() {
  local COMPOSE; COMPOSE=$(detect_compose)
  local RUNTIME; RUNTIME=$(detect_runtime)
  log INFO "Using compose: ${COMPOSE}, runtime: ${RUNTIME}"
  check_rootless "$RUNTIME"

  load_env
  configure_firewall
  local HEALTH_URL="http://localhost:${LISTEN_HTTP_PORT:-8080}/"
  registry_login

  local aio_image
  aio_image=$(parse_compose_images | grep "plane-aio-community")

  # Record current running release before we change anything
  local current_release
  current_release=$($RUNTIME inspect plane-aio \
    --format '{{.Config.Image}}' 2>/dev/null \
    | sed 's/.*://') || true
  if [[ -n "$current_release" ]]; then
    echo "$current_release" > "$PREV_RELEASE_FILE"
    log INFO "Saved current release for rollback: ${current_release}"
  fi

  log INFO "=== Deploying ${aio_image} ==="

  pull_infra_images
  pull_image "$aio_image"

  cd "$SCRIPT_DIR"

  # Create bind-mount directories (Podman/Docker won't do this automatically)
  log INFO "Creating data directories under ${DATA_DIR}..."
  mkdir -p \
    "${DATA_DIR}/pgdata" \
    "${DATA_DIR}/redis" \
    "${DATA_DIR}/rabbitmq" \
    "${DATA_DIR}/minio" \
    "${DATA_DIR}/aio/data" \
    "${DATA_DIR}/aio/logs/access" \
    "${DATA_DIR}/aio/logs/error"

  # Start infra services (idempotent — skips already-running containers)
  log INFO "Starting infrastructure services..."
  $COMPOSE up -d plane-db plane-redis plane-mq plane-minio

  # Wait for DB to be connectable before bringing up AIO
  log INFO "Waiting for postgres to accept connections..."
  local db_wait=90 elapsed=0
  until $COMPOSE exec -T plane-db pg_isready \
        -U "${POSTGRES_USER:-plane}" \
        -d "${POSTGRES_DB:-plane}" &>/dev/null; do
    sleep 5; (( elapsed += 5 ))
    (( elapsed >= db_wait )) && die "Postgres did not become ready within ${db_wait}s."
    log INFO "  postgres not ready yet... ${elapsed}s"
  done
  log INFO "Postgres ready."

  # Deploy AIO (compose handles depends_on conditions for redis, mq, minio)
  log INFO "Starting plane-aio..."
  $COMPOSE up -d plane-aio

  # Application health check with auto-rollback
  if ! wait_healthy; then
    log ERROR "Deployment failed health check. Initiating rollback..."
    do_rollback
    exit 1
  fi

  # Clean up dangling images to reclaim disk space
  log INFO "Pruning dangling images..."
  $RUNTIME image prune -f >> "$LOG_FILE" 2>&1 || true

  log INFO "=== Deploy complete: ${aio_image} ==="
  log INFO "Plane is up at http://${APP_DOMAIN:-localhost}:${LISTEN_HTTP_PORT:-8080}/"
}

# ------------------------------------------------------------------ entry ---
acquire_lock

case "${1:-}" in
  --rollback)
    load_env
    COMPOSE=$(detect_compose)
    RUNTIME=$(detect_runtime)
    check_rootless "$RUNTIME"
    cd "$SCRIPT_DIR"
    do_rollback
    ;;
  *)
    do_deploy
    ;;
esac
