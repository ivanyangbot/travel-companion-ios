#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/release_testflight.sh"
STATE_DIR="$REPO_ROOT/.git/travel-companion-testflight-watch"
STATE_FILE="$STATE_DIR/last_handled_main_sha"
LOCK_DIR="$STATE_DIR/run.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"
LOG_FILE="$REPO_ROOT/build/main-testflight-watch.log"

REMOTE_NAME="${REMOTE_NAME:-origin}"
REMOTE_BRANCH="${REMOTE_BRANCH:-main}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
RUN_ONCE=0

# LaunchAgents and scheduled jobs have a smaller PATH than interactive shells.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.5.app/Contents/Developer}"

usage() {
    /bin/cat <<'EOF'
Usage: scripts/watch_main_testflight.sh [--once]

Checks origin/main every minute. When a new remote commit appears, it runs
scripts/release_testflight.sh. The release script synchronizes main, increments
the build number, tests, archives, uploads to TestFlight, and assigns the build
to Internal Testers.

Options:
  --once       Check once and exit. Intended for schedulers and smoke tests.
  -h, --help   Show this help.

Environment overrides:
  INTERVAL_SECONDS, REMOTE_NAME, REMOTE_BRANCH, DEVELOPER_DIR.
EOF
}

while (($#)); do
    case "$1" in
        --once)
            RUN_ONCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "INTERVAL_SECONDS must be a positive integer." >&2
    exit 2
fi

mkdir -p "$STATE_DIR" "$REPO_ROOT/build"

log() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $message" | tee -a "$LOG_FILE"
}

release_lock() {
    /bin/rm -f "$LOCK_PID_FILE"
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_PID_FILE"
        trap release_lock EXIT INT TERM
        return 0
    fi

    local lock_pid=""
    if [[ -f "$LOCK_PID_FILE" ]]; then
        lock_pid="$(/bin/cat "$LOCK_PID_FILE" 2>/dev/null || true)"
    fi

    if [[ "$lock_pid" == "$$" ]]; then
        return 0
    fi

    if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
        log "Another monitor process is active (pid $lock_pid); skipping this check."
        return 1
    fi

    log "Removing a stale monitor lock."
    /bin/rm -f "$LOCK_PID_FILE"
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || return 1
    /bin/mkdir "$LOCK_DIR" || return 1
    echo "$$" > "$LOCK_PID_FILE"
    trap release_lock EXIT INT TERM
}

write_state() {
    local sha="$1"
    local temporary_state="$STATE_FILE.$$"
    echo "$sha" > "$temporary_state"
    /bin/mv -f "$temporary_state" "$STATE_FILE"
}

check_main_once() {
    if ! acquire_lock; then
        return 0
    fi

    cd "$REPO_ROOT" || return 1

    if [[ ! -x "$RELEASE_SCRIPT" ]]; then
        log "Release script is missing or not executable: $RELEASE_SCRIPT"
        return 1
    fi

    if ! git fetch --quiet "$REMOTE_NAME" "$REMOTE_BRANCH"; then
        log "git fetch failed; the next scheduled check will try again."
        return 1
    fi

    local remote_ref="$REMOTE_NAME/$REMOTE_BRANCH"
    local remote_sha
    remote_sha="$(git rev-parse --verify "$remote_ref" 2>/dev/null)" || {
        log "Could not resolve $remote_ref."
        return 1
    }

    local handled_sha=""
    if [[ -f "$STATE_FILE" ]]; then
        handled_sha="$(/bin/cat "$STATE_FILE" 2>/dev/null || true)"
    fi

    if [[ -z "$handled_sha" ]]; then
        local local_sha
        local_sha="$(git rev-parse --verify "refs/heads/$REMOTE_BRANCH" 2>/dev/null || true)"

        if [[ "$local_sha" == "$remote_sha" ]]; then
            write_state "$remote_sha"
            log "Monitor initialized at ${remote_sha:0:12}; waiting for the next main commit."
            return 0
        fi

        handled_sha="$local_sha"
        log "Monitor initialized with remote updates pending; preparing a release."
    fi

    if [[ "$handled_sha" == "$remote_sha" ]]; then
        log "No new commit on $remote_ref (${remote_sha:0:12})."
        return 0
    fi

    if [[ -n "$handled_sha" ]] && ! git merge-base --is-ancestor "$handled_sha" "$remote_sha"; then
        log "$remote_ref is not a fast-forward from ${handled_sha:0:12}; refusing an automatic release."
        return 1
    fi

    log "New $remote_ref commit detected: ${handled_sha:0:12} -> ${remote_sha:0:12}."
    log "Starting the one-click TestFlight release."

    "$RELEASE_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    local release_status=${PIPESTATUS[0]}

    # The release script pushes its version commit before building. Mark the
    # checked-out commit handled even after a later build/upload failure so the
    # monitor does not create a new build every minute for the same source change.
    local handled_after_run
    handled_after_run="$(git rev-parse --verify "refs/heads/$REMOTE_BRANCH" 2>/dev/null || true)"
    if [[ -n "$handled_after_run" ]]; then
        write_state "$handled_after_run"
    else
        write_state "$remote_sha"
    fi

    if ((release_status != 0)); then
        log "TestFlight release failed with status $release_status; see $LOG_FILE."
        return "$release_status"
    fi

    log "TestFlight release completed for source commit ${remote_sha:0:12}."
    return 0
}

if ((RUN_ONCE == 1)); then
    check_main_once
    exit $?
fi

log "Watching $REMOTE_NAME/$REMOTE_BRANCH every $INTERVAL_SECONDS seconds."
while true; do
    check_main_once || true
    sleep "$INTERVAL_SECONDS"
done
