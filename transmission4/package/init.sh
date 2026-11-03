#!/bin/sh
# init.sh <app folder> — runs after install and upgrade, and at every boot
# for this app whether Run App is ON or OFF.

. "$(dirname "$0")/lib.sh"

tr_prepare_home
tr_link_web

if tr_upgrade_in_progress; then
    rm -f "$TR_UPGRADING"
    if [ -f "$TR_SHOULD_RUN" ]; then
        tr_log "after upgrade: starting Transmission again"
        tr_spawn_ctl start
        tr_spawn_ctl restore-run-app
    else
        tr_log "after upgrade: Run App was OFF; not starting"
    fi
elif [ -f "$TR_SHOULD_RUN" ] && ! tr_wd_enabled; then
    # An upgrade left Run App OFF (before 4.1.4-6, or WD dropped the
    # restore), so WD won't call start.sh and the app's own flag decides.
    # With Run App ON, start.sh follows instead.
    tr_log "boot: Run App shows OFF after an upgrade, but should-run is set; starting"
    tr_spawn_ctl start
    tr_spawn_ctl dashboard-on
fi
exit 0
