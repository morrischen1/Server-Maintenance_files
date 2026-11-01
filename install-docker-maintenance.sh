#!/usr/bin/env bash
set -Eeuo pipefail

readonly SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DEST="/usr/local/sbin/docker-maintenance"
readonly UNIT_DIR="/etc/systemd/system"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

((EUID == 0)) || fail "Run the installer as root (for example, sudo bash install-docker-maintenance.sh)."
[[ -d /run/systemd/system ]] || fail "systemd is not running on this system."

for required_command in docker install systemctl; do
    command -v "$required_command" >/dev/null 2>&1 || fail "Required command not found: $required_command"
done

for source_file in docker-maintenance.sh docker-maintenance.service docker-maintenance.timer; do
    [[ -f "${SOURCE_DIR}/${source_file}" ]] || fail "Missing source file: ${SOURCE_DIR}/${source_file}"
done

install -D -m 0755 "${SOURCE_DIR}/docker-maintenance.sh" "$SCRIPT_DEST"
install -D -m 0644 "${SOURCE_DIR}/docker-maintenance.service" "${UNIT_DIR}/docker-maintenance.service"
install -D -m 0644 "${SOURCE_DIR}/docker-maintenance.timer" "${UNIT_DIR}/docker-maintenance.timer"

systemctl daemon-reload
systemctl enable --now docker-maintenance.timer

printf 'Docker maintenance timer installed and enabled.\n'
systemctl list-timers --all --no-pager docker-maintenance.timer
