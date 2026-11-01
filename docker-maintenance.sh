#!/usr/bin/env bash
set -Eeuo pipefail

readonly PRUNE_AGE="${PRUNE_AGE:-72h}"
readonly STATE_DIR="${DOCKER_MAINTENANCE_STATE_DIR:-/var/lib/docker-maintenance}"
readonly LAST_RUN_FILE="${STATE_DIR}/last-run"
readonly LOCK_FILE="${DOCKER_MAINTENANCE_LOCK_FILE:-/run/lock/docker-maintenance.lock}"

scheduled=false

usage() {
    cat <<'EOF'
Usage: docker-maintenance [--scheduled]

Without arguments, pull all locally tagged images and prune old resources now.
  --scheduled  Run only when no previous attempt is recorded, or at least
               three calendar days have passed since the previous attempt.
  -h, --help   Show this help text.

Set PRUNE_AGE to change the Docker cleanup cutoff (default: 72h).
EOF
}

log() {
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

skip_if_not_due() {
    [[ "$scheduled" == true && -f "$LAST_RUN_FILE" ]] || return 0

    local today last_run next_run
    today="$(date +%F)"
    last_run="$(<"$LAST_RUN_FILE")"

    if [[ ! "$last_run" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || [[ "$last_run" > "$today" ]]; then
        log "Ignoring invalid last-run date '$last_run'."
        return 0
    fi

    if ! next_run="$(date --date="$last_run 12:00:00 + 3 days" +%F)"; then
        log "Ignoring unreadable last-run date '$last_run'."
        return 0
    fi

    if [[ "$today" < "$next_run" ]]; then
        log "Skipping maintenance; the next scheduled attempt is $next_run at 03:00."
        exit 0
    fi
}

while (($#)); do
    case "$1" in
        --scheduled)
            scheduled=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

((EUID == 0)) || fail "Run this script as root (for example, with sudo)."

for required_command in docker flock date; do
    command -v "$required_command" >/dev/null 2>&1 || fail "Required command not found: $required_command"
done

skip_if_not_due

exec 9>"$LOCK_FILE" || fail "Cannot open lock file: $LOCK_FILE"
if ! flock -n 9; then
    log "Another Docker maintenance run is already active; exiting."
    exit 0
fi

mkdir -p -- "$STATE_DIR"

if ! docker info >/dev/null; then
    fail "Cannot communicate with the Docker daemon. No attempt date was recorded."
fi

today="$(date +%F)"
printf '%s\n' "$today" > "${LAST_RUN_FILE}.tmp"
mv -- "${LAST_RUN_FILE}.tmp" "$LAST_RUN_FILE"

log "Starting Docker maintenance; cleanup cutoff is $PRUNE_AGE."

if ! image_list="$(docker image ls --format '{{.Repository}}:{{.Tag}}')"; then
    fail "Could not list Docker images."
fi

attempted=0
pulled=0
pull_failures=0

while IFS= read -r image; do
    [[ -n "$image" && "$image" != *"<none>"* ]] || continue

    ((attempted += 1))
    log "Pulling $image"
    if docker pull "$image"; then
        ((pulled += 1))
    else
        ((pull_failures += 1))
        log "ERROR: Failed to pull $image; continuing." >&2
    fi
done <<< "$image_list"

log "Image pulls finished: $pulled succeeded, $pull_failures failed, $attempted attempted."

cleanup_failed=0

log "Pruning stopped containers created before the $PRUNE_AGE cutoff."
if ! docker container prune --force --filter "until=$PRUNE_AGE"; then
    cleanup_failed=1
    log "ERROR: Container cleanup failed." >&2
fi

log "Pruning unused images created before the $PRUNE_AGE cutoff."
if ! docker image prune --all --force --filter "until=$PRUNE_AGE"; then
    cleanup_failed=1
    log "ERROR: Image cleanup failed." >&2
fi

if ((pull_failures > 0 || cleanup_failed > 0)); then
    log "Docker maintenance finished with errors; review the output above." >&2
    exit 1
fi

log "Docker maintenance completed successfully."
