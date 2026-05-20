#!/usr/bin/env bash
# Plane log viewer
#
# Usage:
#   ./logs.sh                    — container status + last 50 lines from each
#   ./logs.sh -f                 — follow all containers live
#   ./logs.sh -e                 — errors/warnings only (all containers)
#   ./logs.sh <container>        — last 50 lines from one container
#   ./logs.sh <container> -f     — follow one container live
#   ./logs.sh <container> -e     — errors/warnings from one container
#
# Container names: plane-nginx  plane-aio  plane-db  plane-redis  plane-mq  plane-minio
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
TAIL_LINES=50
ALL_CONTAINERS=(plane-nginx plane-aio plane-db plane-redis plane-mq plane-minio)

# ------------------------------------------------------------------ colours ---
if [[ -t 1 ]]; then
  RED='\033[0;31m' YELLOW='\033[1;33m' GREEN='\033[0;32m'
  CYAN='\033[0;36m' BOLD='\033[1m' NC='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' BOLD='' NC=''
fi

# ------------------------------------------------------------------ runtime ---
detect_runtime() {
  if command -v podman &>/dev/null; then
    echo "podman"
  elif command -v docker &>/dev/null; then
    echo "docker"
  else
    echo "No container runtime found (podman or docker required)." >&2; exit 1
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
    echo "No compose tool found." >&2; exit 1
  fi
}

setup_runtime() {
  RUNTIME=$(detect_runtime)
  COMPOSE=$(detect_compose)

  # Rootless Docker needs an explicit socket path
  if [[ "$RUNTIME" == "docker" && "$EUID" -ne 0 ]]; then
    local sock="${XDG_RUNTIME_DIR:-/run/user/${EUID}}/docker.sock"
    [[ -S "$sock" ]] && export DOCKER_HOST="unix://${sock}" || true
  fi
}

# ------------------------------------------------------------------ status ---
show_status() {
  printf "${CYAN}${BOLD}%-22s %-12s %-10s %s${NC}\n" "SERVICE" "STATE" "HEALTH" "IMAGE"
  printf '%s\n' "------------------------------------------------------------"
  cd "$SCRIPT_DIR"
  for c in "${ALL_CONTAINERS[@]}"; do
    local state image health colour cid
    cid=$($COMPOSE ps -q "$c" 2>/dev/null | head -1)
    if [[ -z "$cid" ]]; then
      printf "${YELLOW}%-22s${NC} %-12s %-10s %s\n" "$c" "not found" "-" "-"
      continue
    fi
    state=$($RUNTIME inspect "$cid" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    image=$($RUNTIME inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null | sed 's|.*/||' || echo "-")
    health=$($RUNTIME inspect "$cid" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' 2>/dev/null || echo "-")

    case "$state" in
      running)           colour="$GREEN"  ;;
      exited|dead|error) colour="$RED"    ;;
      *)                 colour="$YELLOW" ;;
    esac

    printf "${colour}%-22s${NC} %-12s %-10s %s\n" "$c" "$state" "$health" "$image"
  done
  printf '\n'
}

# ------------------------------------------------------------------ logs ---
# Print a section header for a container
header() {
  local c="$1"
  printf "${CYAN}${BOLD}┌─── %s ───${NC}\n" "$c"
}

logs_snapshot() {
  local containers=("$@")
  cd "$SCRIPT_DIR"
  for c in "${containers[@]}"; do
    header "$c"
    $COMPOSE logs --tail "$TAIL_LINES" "$c" 2>&1 || \
      printf "${YELLOW}  (container not found or not running)${NC}\n"
    printf '\n'
  done
}

logs_errors() {
  local containers=("$@")
  cd "$SCRIPT_DIR"
  for c in "${containers[@]}"; do
    local output
    output=$($COMPOSE logs "$c" 2>&1 | \
      grep -iE '\b(error|err|warn|warning|fatal|critical|exception|traceback|panic)\b' || true)
    if [[ -n "$output" ]]; then
      header "$c"
      echo "$output" | while IFS= read -r line; do
        if echo "$line" | grep -qiE '\b(error|fatal|critical|exception|traceback|panic)\b'; then
          printf "${RED}%s${NC}\n" "$line"
        else
          printf "${YELLOW}%s${NC}\n" "$line"
        fi
      done
      printf '\n'
    fi
  done
}

logs_follow() {
  local containers=("$@")
  cd "$SCRIPT_DIR"
  if (( ${#containers[@]} == 1 )); then
    printf "${CYAN}${BOLD}Following: %s  (Ctrl-C to stop)${NC}\n\n" "${containers[0]}"
    $COMPOSE logs -f --tail "$TAIL_LINES" "${containers[0]}" 2>&1
  else
    printf "${CYAN}${BOLD}Following all containers  (Ctrl-C to stop)${NC}\n\n"
    $COMPOSE logs -f --tail 20 "${containers[@]}" 2>&1
  fi
}

# ------------------------------------------------------------------ args ---
setup_runtime

TARGET_CONTAINERS=("${ALL_CONTAINERS[@]}")
MODE="snapshot"

for arg in "$@"; do
  case "$arg" in
    -f|--follow) MODE="follow"   ;;
    -e|--errors) MODE="errors"   ;;
    -h|--help)
      sed -n '2,13p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "Unknown flag: $arg  (use -f, -e, or -h)" >&2; exit 1
      ;;
    *)
      # Treat as a container name — allow short names without the plane- prefix
      if [[ "$arg" != plane-* ]]; then arg="plane-${arg}"; fi
      TARGET_CONTAINERS=("$arg")
      ;;
  esac
done

# ------------------------------------------------------------------ main ---
show_status

case "$MODE" in
  snapshot) logs_snapshot "${TARGET_CONTAINERS[@]}" ;;
  errors)   logs_errors   "${TARGET_CONTAINERS[@]}" ;;
  follow)   logs_follow   "${TARGET_CONTAINERS[@]}" ;;
esac
