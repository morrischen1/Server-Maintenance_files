#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOCK_FILE="${SYSTEM_MAINTENANCE_LOCK_FILE:-/run/lock/system-maintenance.lock}"
readonly REBOOT_REQUIRED_FILE="/var/run/reboot-required"

usage() {
    cat <<'EOF'
Usage: system-maintenance

Update package lists, install all available upgrades, remove unused packages,
and clean obsolete package archives. Refresh Snap and Flatpak packages when
available. Reboot automatically if Debian or Ubuntu requires it.

  -h, --help  Show this help text.
EOF
}

log() {
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

((EUID == 0)) || fail "Run this script as root (for example, with sudo)."
[[ -r /etc/os-release ]] || fail "Cannot identify the operating system: /etc/os-release is not readable."

. /etc/os-release
case "${ID:-}" in
    debian|ubuntu)
        ;;
    *)
        fail "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}}. This script supports Debian and Ubuntu."
        ;;
esac

for required_command in apt-get flock date systemctl; do
    command -v "$required_command" >/dev/null 2>&1 || fail "Required command not found: $required_command"
done

exec 9>"$LOCK_FILE" || fail "Cannot open lock file: $LOCK_FILE"
if ! flock -n 9; then
    log "Another system maintenance run is already active; exiting."
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

apt_options=(
    -y
    -o "DPkg::Lock::Timeout=300"
    -o "Dpkg::Options::=--force-confdef"
    -o "Dpkg::Options::=--force-confold"
)

log "Updating package lists."
apt-get "${apt_options[@]}" update

log "Installing available package upgrades, including dependency changes."
apt-get "${apt_options[@]}" full-upgrade

log "Removing packages that are no longer required."
apt-get "${apt_options[@]}" autoremove

log "Cleaning obsolete package archives."
apt-get "${apt_options[@]}" autoclean

if command -v snap >/dev/null 2>&1; then
    log "Refreshing Snap packages."
    snap refresh
fi

if command -v flatpak >/dev/null 2>&1; then
    log "Updating Flatpak packages."
    flatpak update -y
fi

if [[ -f "$REBOOT_REQUIRED_FILE" ]]; then
    log "System maintenance completed successfully; a reboot is required. Rebooting now."
    systemctl reboot || fail "Could not initiate the required system reboot."
else
    log "System maintenance completed successfully; no reboot is required."
fi
