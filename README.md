# Plane AIO — VM Deploy

Deploys [Plane](https://plane.so) All-In-One community edition to a single VM using Podman (or Docker) and Compose. All images are pulled from a configurable private registry.

## Architecture

One AIO container runs all Plane services via `supervisord`:

| Process | Role |
|---|---|
| `proxy` | Caddy reverse proxy (port 80/443 inside container) |
| `api` | Django REST API (internal :3004) |
| `worker` | Celery background worker |
| `beat` | Celery beat scheduler |
| `migrator` | DB migrations (runs once on start, exits 0) |
| `space` | Spaces frontend (internal :3002) |
| `live` | Live collaboration server (internal :3005) |

Four infrastructure containers run alongside it:

| Container | Image | Role |
|---|---|---|
| `plane-db` | postgres:15.7-alpine | Primary database |
| `plane-redis` | valkey/valkey:7.2.11-alpine | Cache & task queue |
| `plane-mq` | rabbitmq:3.13.6-management-alpine | Message broker |
| `plane-minio` | minio/minio:latest | S3-compatible object storage |

## Files

```
deploy_plane_on_vm/
  deploy.sh           # main deploy + first-time setup script
  logs.sh             # log viewer and container status tool
  docker-compose.yml  # AIO + infrastructure services
  .env.example        # environment template — setup wizard fills this in
  .env                # live config — created on first run (git-ignored)
  .previous_release   # written before each deploy for rollback
  deploy.log          # append-only deploy log
```

## Prerequisites

**On the VM:**
- CentOS 8+ / Rocky / Fedora / Ubuntu / Debian (any Linux with systemd)
- `podman` — `dnf install podman` or `apt install podman`
- `podman-compose` — `pip3 install podman-compose`
- `curl`, `openssl` (usually pre-installed)

**Or with Docker instead of Podman:**
- Docker Engine + `docker compose` plugin

The script auto-detects `podman` first, falls back to `docker`.

## First Deploy

```bash
# 1. Copy files to the VM
scp -r deploy_plane_on_vm/ user@vm:/opt/plane/
ssh user@vm

# 2. Run — interactive setup starts automatically when .env is absent
cd /opt/plane
chmod +x deploy.sh logs.sh
./deploy.sh
```

The setup wizard prompts for:

```
Persistent data directory [/opt/plane/data]:  ← where all container data lives on the host
Private registry URL [docker.io]:             ← Enter for Docker Hub, or your private registry
VM IP address [127.0.0.1]:                    ← IP browsers use to reach Plane
PostgreSQL password [Enter to auto-generate]:
RabbitMQ password [Enter to auto-generate]:
MinIO access key [Enter to auto-generate]:
MinIO secret key [Enter to auto-generate]:

Registry username (Enter to skip):            ← credentials for the registry above
Registry password:
```

Passwords left blank are auto-generated via `openssl rand -hex 16`. App secrets (`SECRET_KEY`, `LIVE_SERVER_SECRET_KEY`) are always auto-generated.

After the wizard the script:
1. Creates all data directories under `DATA_DIR`
2. Pulls infrastructure images (skipped if already present)
3. Pulls the AIO image
4. Starts infrastructure, waits for Postgres to be ready
5. Starts the AIO container
6. Runs a 300 s health check — rolls back automatically on failure

**First boot takes ~2 minutes** — the migrator runs all DB migrations before the API becomes ready.

## Rootless Mode Checks (Podman / Docker rootless)

When running without root the deploy script automatically checks and prompts to fix common rootless issues:

### Subordinate UID/GID mappings (Podman only)

Rootless Podman needs entries in `/etc/subuid` and `/etc/subgid` to create user namespaces. The script checks for `^<user>:` in both files and offers to run:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

After adding mappings run `podman system migrate` or log out and back in.

### Linger (containers survive SSH disconnect)

Without linger, systemd kills the user session — and all containers — when you disconnect SSH. The script detects this and offers to enable it:

```bash
loginctl enable-linger $USER
```

Once enabled, containers stay running after logout and restart automatically on VM reboot.

### Unprivileged ports below 1024

If `LISTEN_HTTP_PORT` is set below 1024 the script warns and prints the exact `sysctl` fix:

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
# persist across reboots:
echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-unpriv-ports.conf
```

## Firewall & External Access

The deploy script auto-detects the active firewall and prompts to configure it so Plane is reachable from outside the VM.

### firewalld (RHEL / Rocky / Fedora)

Uses `--add-forward-port` to redirect port 80 → 8080 and opens port 8443. Because firewalld handles the redirect internally, port 8080 does **not** need to be opened separately.

```bash
# what the script applies:
sudo firewall-cmd --add-forward-port=port=80:proto=tcp:toport=8080 --permanent
sudo firewall-cmd --add-port=8443/tcp --permanent
sudo firewall-cmd --reload
```

### ufw (Ubuntu / Debian)

Opens ports 8080 and 8443, then adds an iptables NAT redirect so the app is reachable on port 80 without a port number in the URL.

```bash
sudo ufw allow 8080/tcp
sudo ufw allow 8443/tcp
sudo ufw reload
sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
```

### raw iptables

Same as ufw but without the ufw layer. Rules are persisted automatically via `netfilter-persistent` (Debian/Ubuntu) or `/etc/sysconfig/iptables` (RHEL). If neither is available the script warns that rules will be lost on reboot.

> **Why open 8080 for ufw/iptables but not firewalld?**  
> iptables processes PREROUTING (NAT redirect) before INPUT (filtering). After the 80→8080 redirect, the INPUT chain sees port 8080 — so it must be explicitly allowed. firewalld's `--add-forward-port` is a higher-level abstraction that handles this internally.

### Cloud VMs

If the VM is hosted on AWS, GCP, Azure, or similar, you must also open ports in the **cloud provider's security group / firewall rules** — OS-level rules alone are not enough.

## Accessing Plane

| URL | What |
|---|---|
| `http://<VM_IP>/` | Main app (via port 80 → 8080 redirect) |
| `http://<VM_IP>:8080/` | Main app (direct) |
| `http://<VM_IP>/god-mode/` | Admin panel (trailing slash required) |
| `http://<VM_IP>:9000/` | MinIO API (file upload/download pre-signed URLs) |

> **Why is port 9000 required?** Plane generates pre-signed URLs for file uploads and downloads. These URLs are sent to the browser, which then contacts MinIO directly. The URL is built from `AWS_S3_ENDPOINT_URL`, which must be a browser-reachable address — not the internal `plane-minio:9000` Docker hostname. Port 9000 must be open in both the OS firewall and any cloud security group.

> Always type the full `http://` scheme — browsers may silently upgrade to HTTPS otherwise.

## Log Viewer

`logs.sh` provides a quick overview of all containers and their logs.

```bash
./logs.sh                  # status table + last 50 lines from every container
./logs.sh -f               # live follow all containers
./logs.sh -e               # errors and warnings only (all containers)
./logs.sh aio              # last 50 lines from plane-aio (plane- prefix optional)
./logs.sh aio -f           # follow plane-aio live
./logs.sh aio -e           # errors/warnings from plane-aio only
```

The status table printed at the top of every run shows container state and health at a glance:

```
CONTAINER              STATE        HEALTH     IMAGE
------------------------------------------------------------
plane-aio              running      healthy    plane-aio-community:stable
plane-db               running      healthy    postgres:15.7-alpine
plane-redis            running      healthy    valkey:7.2.11-alpine
plane-mq               running      healthy    rabbitmq:3.13.6-management-alpine
plane-minio            running      -          minio:latest
```

## Persistent Storage

All container data is stored under a single `DATA_DIR` on the host (default `/opt/plane/data`):

```
/opt/plane/data/
  pgdata/       ← Postgres WAL + tables
  redis/        ← Valkey snapshots
  rabbitmq/     ← RabbitMQ queues
  minio/        ← uploaded files
  aio/data/     ← AIO runtime data
  aio/logs/     ← supervisord + per-process logs
```

Backup:
```bash
tar czf plane-backup-$(date +%F).tar.gz /opt/plane/data
```

To move data to a larger disk: stop containers, copy the directory, update `DATA_DIR` in `.env`, redeploy.

## Updating to a New Release

```bash
APP_RELEASE=v0.28.0 ./deploy.sh
```

The script saves the current release tag, pulls the new image, recreates only `plane-aio` (infra is untouched), and rolls back automatically if the health check fails.

## Manual Rollback

```bash
./deploy.sh --rollback
```

Restores the release recorded in `.previous_release` and verifies with a health check.

## Reconfiguring from Scratch

```bash
rm .env && ./deploy.sh
```

The setup wizard runs again. Existing data in `DATA_DIR` is preserved — only the configuration is reset.

## Applying .env Changes Without a Full Redeploy

```bash
# Edit .env, then recreate only the AIO container
podman-compose up -d --force-recreate plane-aio
# or
docker compose up -d --force-recreate plane-aio
```

## Key .env Variables

| Variable | Default | Notes |
|---|---|---|
| `DATA_DIR` | `./data` | Root for all bind-mount volumes |
| `REGISTRY` | `docker.io` | Registry prefix applied to all image pulls |
| `APP_RELEASE` | `stable` | Image tag for `plane-aio-community` |
| `DOMAIN_NAME` / `APP_DOMAIN` | *(VM IP)* | Must match what browsers use to reach Plane |
| `WEB_URL` | `http://<IP>:<PORT>` | Auto-set from IP + port during setup |
| `CORS_ALLOWED_ORIGINS` | `http://<IP>:<PORT>` | Auto-set from IP + port during setup |
| `LISTEN_HTTP_PORT` | `8080` | Host port mapped to container port 80 |
| `LISTEN_HTTPS_PORT` | `8443` | Host port mapped to container port 443 |
| `MINIO_PORT` | `9000` | Host port for MinIO API; must match `AWS_S3_ENDPOINT_URL` |
| `AWS_S3_ENDPOINT_URL` | `http://<IP>:9000` | Public MinIO URL sent to browsers in pre-signed links |
| `POSTGRES_PASSWORD` | *(generated)* | Also embedded in `DATABASE_URL` |
| `RABBITMQ_PASSWORD` | *(generated)* | Also embedded in `AMQP_URL` |
| `SECRET_KEY` | *(generated)* | Django secret — do not change after first deploy |

## Troubleshooting

**Nothing responds after deploy:**
```bash
# Quick status and recent errors
./logs.sh
./logs.sh -e

# Test directly from the VM (bypasses browser HTTPS upgrade)
curl -v http://localhost:8080/

# Check AIO startup — migrator takes ~90s on first boot
./logs.sh aio -f
```

**Plane stops after SSH disconnect:**  
Linger is not enabled. The deploy script prompts for this automatically; to fix manually:
```bash
loginctl enable-linger $USER
podman-compose up -d   # restart containers
```

**Health check loops forever:**  
The health check URL is derived from `LISTEN_HTTP_PORT`. If it loops, the port in `.env` doesn't match what the container is actually bound to. Check with `podman-compose ps` and verify `LISTEN_HTTP_PORT`.

**`/god-mode` shows a React Router error:**  
Navigate to `/god-mode/` with a trailing slash. Caddy's `handle_path` strips the prefix before React Router sees the URL — without the trailing slash, `basename="/god-mode/"` can't match.

**Rootless Podman fails with namespace error:**  
Subuid/subgid mappings are missing. The deploy script prompts for this automatically; to fix manually:
```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
podman system migrate
```

**Port 80 redirect not working after reboot:**  
iptables rules were not persisted. Install the persistence package and save:
```bash
# Debian/Ubuntu
sudo apt install iptables-persistent && sudo netfilter-persistent save

# RHEL/Rocky
sudo dnf install iptables-services && sudo iptables-save | sudo tee /etc/sysconfig/iptables
```

**Postgres out of disk space:**
```bash
df -h                        # check overall disk
podman system df             # check container storage usage
podman image prune -f        # remove dangling images
```

**Setup interrupted — `.env` removed on next run:**  
Intentional. The EXIT trap checks for `SETUP_COMPLETE=1` and removes the partial file so the next run starts clean.

**File uploads fail / browser requests go to `http://plane-minio:9000`:**  
`AWS_S3_ENDPOINT_URL` is set to the internal Docker hostname. Plane embeds this URL in pre-signed upload/download links sent to the browser — the browser can't resolve `plane-minio`. Fix: ensure `AWS_S3_ENDPOINT_URL=http://<VM_IP>:9000` in `.env` and that port 9000 is open in the firewall and cloud security group. Re-run `setup_env` or edit `.env` and recreate the AIO container:
```bash
# Edit .env: set AWS_S3_ENDPOINT_URL=http://<VM_IP>:9000
podman-compose up -d --force-recreate plane-aio
```

**Stale lock file:**
```bash
rm /tmp/plane-deploy.lock
```

**Pull fails repeatedly:**
```bash
podman login <registry>
podman pull <registry>/makeplane/plane-aio-community:stable
```
