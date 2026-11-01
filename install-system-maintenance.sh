#!/usr/bin/env bash
set -Eeuo pipefail

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DEST="/usr/local/sbin/system-maintenance"
readonly UNIT_DIR="/etc/systemd/system"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

((EUID == 0)) || fail "Run the installer as root (for example, sudo bash install-system-maintenance.sh)."
[[ -d /run/systemd/system ]] || fail "systemd is not running on this system."
[[ -r /etc/os-release ]] || fail "Cannot identify the operating system: /etc/os-release is not readable."

. /etc/os-release
case "${ID:-}" in
    debian|ubuntu)
        ;;
    *)
        fail "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}}. This installer supports Debian and Ubuntu."
        ;;
esac

for required_command in apt-get date dpkg-reconfigure flock install systemctl; do
    command -v "$required_command" >/dev/null 2>&1 || fail "Required command not found: $required_command"
done

for source_file in system-maintenance.sh system-maintenance.service system-maintenance.timer; do
    [[ -f "${SOURCE_DIR}/${source_file}" ]] || fail "Missing source file: ${SOURCE_DIR}/${source_file}"
done

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

apt_options=(
    -y
    -o "DPkg::Lock::Timeout=300"
    -o "Dpkg::Options::=--force-confdef"
    -o "Dpkg::Options::=--force-confold"
)

printf 'Updating package lists.\n'
apt-get "${apt_options[@]}" update

printf 'Installing unattended-upgrades.\n'
apt-get "${apt_options[@]}" install unattended-upgrades

printf 'Configuring automatic security updates.\n'
dpkg-reconfigure -plow unattended-upgrades

install -D -m 0755 "${SOURCE_DIR}/system-maintenance.sh" "$SCRIPT_DEST"
install -D -m 0644 "${SOURCE_DIR}/system-maintenance.service" "${UNIT_DIR}/system-maintenance.service"
install -D -m 0644 "${SOURCE_DIR}/system-maintenance.timer" "${UNIT_DIR}/system-maintenance.timer"

systemctl daemon-reload
systemctl enable --now system-maintenance.timer

printf 'System maintenance timer installed and enabled.\n'
systemctl list-timers --all --no-pager system-maintenance.timer
