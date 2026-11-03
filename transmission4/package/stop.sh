#!/bin/sh
# stop.sh <app folder> — Run App OFF; also right before start.sh at boot,
# twice during shutdown, and before an upgrade or uninstall of a running app.
#
# The daemon always stops cleanly (resume data is saved). During an upgrade
# should-run is kept, so the new version's init.sh starts it again.

. "$(dirname "$0")/lib.sh"

if tr_upgrade_in_progress; then
    tr_log "upgrade in progress; stopping Transmission but keeping should-run"
else
    rm -f "$TR_SHOULD_RUN"
fi

if [ -z "$(tr_our_pids)" ]; then
    tr_log "no transmission-daemon of this app running; nothing to stop"
    exit 0
fi
tr_stop_daemon
exit 0
