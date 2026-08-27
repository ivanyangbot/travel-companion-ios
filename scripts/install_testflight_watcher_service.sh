#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LABEL="com.ivanyangbot.travelcompanion.testflight-watch"
DOMAIN="gui/$(id -u)"
TEMPLATE="$SCRIPT_DIR/launchd/$LABEL.plist.in"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$LABEL.plist"
ACTION="${1:-install}"

usage() {
    /bin/cat <<'EOF'
Usage: scripts/install_testflight_watcher_service.sh [install|uninstall|status]

install     Install and immediately start the macOS LaunchAgent (default).
uninstall   Stop the service and remove its installed plist.
status      Print the current launchd service state.
EOF
}

service_status() {
    launchctl print "$DOMAIN/$LABEL"
}

case "$ACTION" in
    install)
        if [[ ! -f "$TEMPLATE" ]]; then
            echo "Missing LaunchAgent template: $TEMPLATE" >&2
            exit 1
        fi
        if [[ ! -x "$SCRIPT_DIR/watch_main_testflight.sh" ]]; then
            echo "Watcher is missing or not executable: $SCRIPT_DIR/watch_main_testflight.sh" >&2
            exit 1
        fi

        mkdir -p "$LAUNCH_AGENTS_DIR" "$REPO_ROOT/build"

        escaped_repo_root="$(/usr/bin/printf '%s' "$REPO_ROOT" | /usr/bin/sed 's/[\&/]/\\&/g')"
        temporary_plist="$PLIST_PATH.$$"
        /usr/bin/sed "s/__REPO_ROOT__/$escaped_repo_root/g" "$TEMPLATE" > "$temporary_plist"
        /usr/bin/plutil -lint "$temporary_plist" >/dev/null
        /bin/mv -f "$temporary_plist" "$PLIST_PATH"

        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
        launchctl enable "$DOMAIN/$LABEL"
        launchctl kickstart -k "$DOMAIN/$LABEL"

        echo "Installed and started $LABEL"
        echo "Plist: $PLIST_PATH"
        echo "Monitor log: $REPO_ROOT/build/main-testflight-watch.log"
        echo "launchd stdout: $REPO_ROOT/build/testflight-watch-launchd.stdout.log"
        echo "launchd stderr: $REPO_ROOT/build/testflight-watch-launchd.stderr.log"
        ;;
    uninstall)
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        /bin/rm -f "$PLIST_PATH"
        echo "Stopped and removed $LABEL"
        ;;
    status)
        service_status
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown action: $ACTION" >&2
        usage >&2
        exit 2
        ;;
esac
