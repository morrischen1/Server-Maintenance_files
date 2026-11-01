# Maintenance scripts for Debian and Ubuntu home lab servers

This directory contains independent system and Docker maintenance bundles for single-administrator home lab servers. Install either one or both; their scripts, systemd units, locks, and schedules are separate.

## Security context and external access

These scripts assume one administrative user who already has root access. They are not intended to isolate mutually untrusted local users. Issues involving inherited environment variables, `sudo` configuration, or locally pre-created lock or state files require local access or an unsafe administrative configuration; they do not by themselves give an external attacker access.

The scripts do **not** open listening ports, change firewall or router settings, enable SSH, or expose the Docker daemon. Their systemd services run locally as root and make outbound connections using the existing APT, Snap, Flatpak, and Docker configuration. A static review found no direct unauthenticated remote-command execution path in these scripts. This does not assess the security of other software running on the server.

For protection against unauthorized external access:

- Secure SSH, exposed applications, reverse proxies, VPNs, and remote-management services independently of these scripts. Use firewalls and router port-forwarding rules to limit which services are reachable from untrusted networks.
- Do not expose the Docker daemon or its Unix socket to untrusted users or networks. Docker access is effectively root access. In particular, an unauthenticated Docker TCP API, commonly on port 2375, can allow immediate system compromise. These installers do not enable such an API.
- Keep exposed host services and applications updated. Pulling a new Docker image does not recreate or patch an existing container; recreate containers through the normal deployment process after reviewing updates.
- Use trusted package repositories and container registries, and protect private-registry credentials. Package and image downloads rely on the security of those configured sources and their network connections.
- Keep the installed scripts and systemd units owned by root, and avoid running them through wrappers that preserve untrusted environment variables.

## System maintenance

The system bundle updates installed packages and performs APT cleanup every day at **02:00 local time** on Debian and Ubuntu. It does not require Docker and operates independently of the Docker maintenance bundle.

### Important behavior and warnings

- **The system reboots automatically after successful maintenance when `/var/run/reboot-required` exists.** This can interrupt users, services, containers, and other workloads. The same behavior applies to manual runs and scheduled catch-up runs.
- The installer runs `apt-get update`, `apt-get install unattended-upgrades`, and `dpkg-reconfigure -plow unattended-upgrades` before enabling the timer. This enables APT's automatic update policy for unattended security upgrades. The configured unattended-upgrades origins determine which repositories are used.
- The maintenance script runs `apt-get update`, `apt-get full-upgrade`, `apt-get autoremove`, and `apt-get autoclean`, in that order. A failed step stops the run and prevents the automatic reboot.
- `full-upgrade` installs available security and non-security upgrades immediately. Unlike `upgrade`, it may install or remove packages to resolve changed dependencies; review the maintenance logs for package changes.
- `autoremove` deletes packages that APT considers no longer required. `autoclean` deletes obsolete downloaded package archives.
- Upgrades run noninteractively. Modified package configuration files are preserved when replacing them would otherwise cause a prompt; review any resulting `.dpkg-dist` files for upstream configuration changes.
- After APT maintenance, the script runs `snap refresh` if Snap is installed and `flatpak update -y` if Flatpak is installed. Because the script runs as root, Flatpak updates cover the system installation, not per-user installations.
- A dedicated lock prevents overlapping system maintenance runs. APT waits up to five minutes for another package manager to release its locks.

### Files

- `system-maintenance.sh`: package updates, Snap/Flatpak updates, cleanup, locking, logging, and required reboots.
- `system-maintenance.service`: systemd service that runs the script.
- `system-maintenance.timer`: systemd timer for the daily 02:00 schedule.
- `install-system-maintenance.sh`: installs and configures `unattended-upgrades`, installs only the system maintenance files, and enables only its timer.

### Requirements

- Debian or Ubuntu using APT and systemd.
- `sudo`/root access and network access to the configured package repositories, plus any configured Snap or Flatpak remotes.
- `flock`, normally installed on Debian and Ubuntu as part of `util-linux`.

### Install system maintenance

Copy the system maintenance files and their installer to the Debian or Ubuntu server, then run:

```bash
cd /path/to/these/files
sudo bash install-system-maintenance.sh
```

The installer installs and configures `unattended-upgrades`, places the script at `/usr/local/sbin/system-maintenance`, installs the service and timer in `/etc/systemd/system`, reloads systemd, and enables the timer. It does not explicitly start a manual maintenance run; the first manual or scheduled run performs package upgrades and cleanup.

### Schedule

The timer runs every day at 02:00 local time. `Persistent=true` allows systemd to catch up after downtime, so maintenance and a required reboot can also occur immediately after startup if a scheduled run was missed.

### Check system maintenance status and logs

```bash
systemctl status system-maintenance.timer
systemctl list-timers --all system-maintenance.timer
sudo journalctl -u system-maintenance.service -n 100 --no-pager
```

### Run system maintenance manually

**A manual run performs the same updates, cleanup, and required automatic reboot described above:**

```bash
sudo /usr/local/sbin/system-maintenance
```

### Uninstall system maintenance

First make sure no system maintenance run is active:

```bash
systemctl is-active system-maintenance.service
```

If it prints `inactive`, run:

```bash
sudo systemctl disable --now system-maintenance.timer
sudo rm /etc/systemd/system/system-maintenance.service \
    /etc/systemd/system/system-maintenance.timer \
    /usr/local/sbin/system-maintenance
sudo systemctl daemon-reload
sudo rm -f /run/lock/system-maintenance.lock
```

These commands do not remove or change any Docker maintenance files. They also do not remove `unattended-upgrades` or disable its APT configuration.

## Docker maintenance

The Docker bundle pulls updates for locally tagged Docker images, removes old stopped containers and unused images, and runs automatically at **03:00 every three calendar days**. It uses systemd, which is included with Debian and Ubuntu Server.

### Important behavior and warnings

- **Stopped containers are deleted** when they were created before the cleanup cutoff (default: 72 hours ago). This includes intentionally stopped containers. Data stored only in a removed container's writable layer is lost.
- **Unused images are deleted** when they were created before the cutoff. Cleanup uses `docker image prune --all`, so this includes tagged and locally built images, not just dangling images. An image is unused when no running or stopped container references it.
- **Running containers are not stopped, removed, or recreated.** They continue using the image from which they were originally started.
- **Volumes are not pruned.** The script does not run `docker volume prune` or `docker system prune`.
- Docker's `until` cutoff is based on resource creation time, not the time when a container was stopped.
- Pull failures for individual images are logged, but the script continues with the remaining images and cleanup. It exits with an error if any pull or cleanup step fails.

Pulling a new image does **not** upgrade an existing container. Recreate containers through your normal deployment process to apply updates. For example, from a Docker Compose project directory:

```bash
docker compose pull
docker compose up -d
```

Do this only after reviewing the new images and your application's upgrade requirements.

### Files

- `docker-maintenance.sh`: update, cleanup, locking, logging, and three-day schedule guard.
- `docker-maintenance.service`: systemd service that runs the script.
- `docker-maintenance.timer`: systemd timer for the 03:00 schedule.
- `install-docker-maintenance.sh`: installs the files and enables the timer.

### Requirements

- Debian or Ubuntu Server using systemd.
- Docker Engine installed and the Docker daemon configured to run.
- `sudo`/root access and network access to your image registries.
- `flock`, normally installed on Debian and Ubuntu as part of `util-linux`.

For private registries, authenticate as the root user because the scheduled service runs as root:

```bash
sudo docker login your-registry.example.com
```

Use the registry authentication method appropriate for your environment.

### Install on the server

Copy all files in this directory to the Debian or Ubuntu server, then run:

```bash
cd /path/to/these/files
sudo bash install-docker-maintenance.sh
```

The installer:

1. Installs the script as `/usr/local/sbin/docker-maintenance`.
2. Installs the service and timer in `/etc/systemd/system`.
3. Reloads systemd and enables the timer.
4. Does not explicitly start a manual maintenance run.

No cron entry is needed.

### Schedule

The timer checks the schedule at 03:00 every night. The script immediately exits unless at least three calendar days have passed since the last recorded attempt. This produces an every-three-days schedule without the month-boundary reset caused by a cron day-of-month expression such as `*/3`.

The last attempt date is stored in:

```text
/var/lib/docker-maintenance/last-run
```

The first scheduled check performs maintenance because no previous attempt exists. `Persistent=true` allows systemd to catch up after downtime; the three-day guard prevents duplicate runs. A completed attempt, including one with pull or cleanup errors, schedules the next automatic attempt three calendar days later.

### Check status and logs

```bash
systemctl status docker-maintenance.timer
systemctl list-timers --all docker-maintenance.timer
sudo journalctl -u docker-maintenance.service -n 100 --no-pager
```

`list-timers` shows the nightly 03:00 check, not a separate timer entry for each actual maintenance run. Check the journal to see whether maintenance ran or the schedule guard skipped it.

To follow log output during a run:

```bash
sudo journalctl -u docker-maintenance.service -f
```

### Run manually

**A manual run performs the same pulls and destructive cleanup described above:**

```bash
sudo /usr/local/sbin/docker-maintenance
```

A manual run also records the attempt date, so the next automatic run is three calendar days later. Only tagged images can be pulled; untagged/dangling entries are skipped during the update phase.

### Change the cleanup age

The default cutoff is `72h`. For example, to retain stopped containers and unused images for at least seven days, create a systemd override:

```bash
sudo systemctl edit docker-maintenance.service
```

Add:

```ini
[Service]
Environment=PRUNE_AGE=168h
```

Then reload systemd:

```bash
sudo systemctl daemon-reload
```

Use a value accepted by Docker's `until` filter, such as `72h` or `168h`. Increasing this value does not protect resources from cleanup once they pass the new cutoff.

### Uninstall

First make sure no maintenance run is active:

```bash
systemctl is-active docker-maintenance.service
```

If it prints `inactive`, run:

```bash
sudo systemctl disable --now docker-maintenance.timer
sudo rm /etc/systemd/system/docker-maintenance.service \
    /etc/systemd/system/docker-maintenance.timer \
    /usr/local/sbin/docker-maintenance
sudo systemctl daemon-reload
```

To remove the small schedule-state and lock files as well:

```bash
sudo rm -f /var/lib/docker-maintenance/last-run \
    /run/lock/docker-maintenance.lock
sudo rmdir /var/lib/docker-maintenance 2>/dev/null || true
```
