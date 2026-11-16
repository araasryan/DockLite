# DockLite

A small native macOS app (SwiftUI) for everyday Docker work, without Docker Desktop.
It talks straight to the Docker Engine API over a unix socket, with Colima as the default engine.

## Features
- **Containers**: grouped by compose project, start/stop/restart/pause/remove, start/stop a whole compose project,
  clickable published ports (`localhost:PORT`), live updates through the Docker events stream
- **Logs**: live streaming (follow), stdout/stderr colouring, filter, copy
- **Shell**: opens Terminal.app with `docker exec -it … bash|sh`
- **Images**: sortable table, usage counts, pull with progress, remove, prune dangling/unused
- **Menu bar**: running count, per-container start/stop/shell/open port, start/stop Colima
- **Colima**: detects when the engine is down and offers "Start Colima"

## Settings (⌘,)
- **General**: open at login, auto-start Colima, menu bar icon, Docker socket, log lines to load
- **Resources**: Colima CPUs, memory, disk (grow only), Kubernetes; Docker disk usage
- **Docker Engine**: registry mirrors, insecure registries, log rotation, BuildKit, debug, raw `daemon.json`
  overrides, and the live config from the VM
- **Updates**: Docker Engine in the VM (`colima update`), Colima and Lima (`brew upgrade`), Docker CLI/Compose
  (Homebrew-managed only)

Resources and Engine edit `~/.colima/default/colima.yaml` in place (comments preserved) and restart Colima.
If Docker doesn't come back up, the previous file is restored and Colima is restarted with it.

## Requirements
- macOS 14+, Swift toolchain (Xcode Command Line Tools is enough)
- `brew install colima docker docker-compose`

## Build
```bash
scripts/build-app.sh            # -> build/DockLite.app
scripts/build-app.sh --install  # also copies to /Applications
```
For development: `swift run`.

## Socket lookup order
`$DOCKER_HOST` (unix) → `~/.colima/default/docker.sock` → `~/.colima/docker.sock` → OrbStack →
Docker Desktop → `/var/run/docker.sock`. You can switch sockets from the gear menu in the sidebar.

## Not included (yet)
Private-registry auth for pulls, volumes/networks views, run-container form, CPU/memory stats,
an embedded terminal.
