# Plane AIO — VM Deploy

Deploys [Plane](https://plane.so) All-In-One community edition to a single VM over SSH using Podman (or Docker) and Compose. All images are pulled from a configurable private registry.

## Architecture

One AIO container runs all Plane services via `supervisord`:

| Process | Role |
|---|---|
| `proxy` | Caddy reverse proxy (port 80/443) |
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
  deploy.sh           # main deploy script
  docker-compose.yml  # AIO + infrastructure services
  .env.example        # environment template (copy to .env)
  .env                # live config — created on first run (git-ignored)
  .previous_release   # written before each deploy for rollback
  deploy.log          # append-only deploy log
```

## Prerequisites

**On the VM:**
- CentOS 8+ (or any Linux with systemd)
- `podman` — `dnf install podman`
- `podman-compose` — `pip3 install podman-compose`
- `curl`, `openssl` (usually pre-installed)

**Or with Docker instead of Podman:**
- Docker Engine + `docker compose` plugin

The script auto-detects `podman` first, falls back to `docker`.

## First Deploy

```bash
# 1. SSH into the VM and clone / copy these files
scp -r deploy_plane_on_vm/ user@vm:/opt/plane/
ssh user@vm

# 2. Run — interactive setup runs automatically when .env is absent
cd /opt/plane
chmod +x deploy.sh
./deploy.sh
```

The setup wizard prompts for:

```
Private registry URL [docker.io]:       ← Enter for Docker Hub, or your registry
VM IP address [127.0.0.1]:              ← IP that browsers will use to reach Plane
PostgreSQL password [Enter to auto-generate]:
RabbitMQ password [Enter to auto-generate]:
MinIO access key [Enter to auto-generate]:
MinIO secret key [Enter to auto-generate]:

Registry username (Enter to skip):      ← credentials for the registry above
Registry password:
```

Passwords left blank are auto-generated via `openssl rand -hex 16`. App secrets (`SECRET_KEY`, `LIVE_SERVER_SECRET_KEY`) are always auto-generated.

After setup the script pulls images, starts infrastructure, waits for Postgres, brings up the AIO container, and runs a 300 s health check against `http://localhost/`.

**First boot takes ~2 minutes** — the migrator runs all DB migrations before the API becomes ready.

## Accessing Plane

| URL | What |
|---|---|
| `http://<VM_IP>/` | Main app |
| `http://<VM_IP>/god-mode/` | Admin panel (trailing slash required) |

> Always use the explicit `http://` scheme in your browser — browsers may auto-upgrade to HTTPS.

## Updating to a New Release

```bash
APP_RELEASE=v0.28.0 ./deploy.sh
```

The script:
1. Saves the current release tag to `.previous_release`
2. Pulls the new image
3. Recreates only the `plane-aio` container (infra is untouched)
4. Runs a health check — rolls back automatically if it fails

## Manual Rollback

```bash
./deploy.sh --rollback
```

Restores the release recorded in `.previous_release` and verifies with a health check.

## Reconfiguring from Scratch

```bash
rm .env
./deploy.sh
```

The setup wizard runs again. Existing data volumes are preserved — only the configuration changes.

## Applying an Updated .env Without Redeploying

```bash
# Edit .env, then recreate only the AIO container
docker compose up -d --force-recreate plane-aio
# or
podman-compose up -d --force-recreate plane-aio
```

## Key .env Variables

| Variable | Default | Notes |
|---|---|---|
| `REGISTRY` | `docker.io` | Registry prefix for all image pulls |
| `APP_RELEASE` | `stable` | Image tag for `plane-aio-community` |
| `DOMAIN_NAME` / `APP_DOMAIN` | *(VM IP)* | Must match the IP/hostname browsers use |
| `WEB_URL` | `http://<IP>` | Must use `http://` for IP-based deploys |
| `LISTEN_HTTP_PORT` | `80` | Host port for HTTP |
| `POSTGRES_PASSWORD` | *(generated)* | Also embedded in `DATABASE_URL` |
| `RABBITMQ_PASSWORD` | *(generated)* | Also embedded in `AMQP_URL` |
| `SECRET_KEY` | *(generated)* | Django secret key — do not change after first deploy |

## Troubleshooting

**Nothing responds on the IP after deploy:**
```bash
# Verify all containers are up
docker compose ps

# Check AIO startup logs
docker compose logs plane-aio --tail=50

# Check Caddy proxy logs
docker exec <plane-aio-container> cat /app/logs/error/proxy.err.log

# Test from the VM itself (bypasses browser HTTPS upgrade)
curl -v http://127.0.0.1/
```

**`/god-mode` shows a React Router error:**
Navigate to `/god-mode/` with a trailing slash. Without it, Caddy's `handle_path` stripping causes a basename mismatch in React Router.

**Setup interrupted — `.env` removed on next run:**
This is intentional. The EXIT trap detects the missing `SETUP_COMPLETE=1` flag and removes the partial file so the next run starts setup cleanly.

**Deploy already in progress:**
If the lock file is stale (previous run crashed): `rm /tmp/plane-deploy.lock`

**Pull fails repeatedly:**
Check registry credentials and that the image tag exists:
```bash
podman login <registry>
podman pull <registry>/makeplane/plane-aio-community:stable
```
