#!/bin/sh
# before_apkg.sh — run by WD's upload step from the NEW package, before any
# other script, on install and upgrade (no arguments, CGI context).
#
# On an upgrade it marks "upgrade in progress", so the old stop.sh keeps the
# should-run flag and the new init.sh starts Transmission again afterwards
# (WD itself leaves an upgraded app switched OFF).

. "$(dirname "$0")/lib.sh"

if [ -d "$TR_APP_DIR" ]; then
    tr_prepare_home
    date '+%Y-%m-%d %H:%M:%S' > "$TR_UPGRADING"
    tr_log "upgrade starting"
fi
exit 0
