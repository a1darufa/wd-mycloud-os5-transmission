#!/bin/sh
# start.sh <app folder> — Run App ON, and at boot when Run App is ON.
# WD already runs it in the background; the work happens in ctl.sh.

. "$(dirname "$0")/lib.sh"

tr_prepare_home

# Refuse here as well as in ctl.sh, so a refused start doesn't leave
# should-run set and bring the daemon up at the next boot.
wd_pids=$(tr_wd_pids)
if [ -n "$wd_pids" ]; then
    tr_log "WD's Transmission is running (pid $wd_pids); switch it OFF in Apps, then switch this app OFF and ON. Not starting."
    exit 0
fi

date '+%Y-%m-%d %H:%M:%S' > "$TR_SHOULD_RUN"
tr_spawn_ctl start
exit 0
