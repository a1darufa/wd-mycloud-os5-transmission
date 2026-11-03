#!/bin/sh
# remove.sh <app folder> — run from the OLD version on upgrade, and on
# uninstall. Deletes the app folder only: config, logs and downloads are
# always kept.

. "$(dirname "$0")/lib.sh"

app_dir=$1

tr_unlink_web
tr_stop_daemon

if tr_upgrade_in_progress; then
    tr_log "upgrade: removing the old app folder"
else
    rm -f "$TR_SHOULD_RUN"
    tr_log "uninstalled; config and logs are kept in $TR_HOME, downloads in $TR_DOWNLOAD_DIR"
fi

if [ "$app_dir" = "$TR_APP_DIR" ]; then
    rm -rf "$app_dir"
else
    tr_log "refusing to delete unexpected path: $app_dir"
    exit 1
fi
exit 0
