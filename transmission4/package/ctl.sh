#!/bin/sh
# ctl.sh <command> — the app's longer operations. The lifecycle scripts run
# it detached (tr_spawn_ctl), so neither the web UI nor WD's app manager
# waits for it.
#
#   start           take over WD's settings once, then start the daemon
#   log-keeper      cap transmission.log while the daemon runs
#   apply-settings  write the Configure page's changes, restarting the daemon
#   restore-run-app after an upgrade, put WD's Run App switch back ON, and
#                   end WD's "Updating" dialog if it's stuck
#   dashboard-on    at boot, ask WD to show Run App ON if should-run says so
#
# The Configure page's api.php runs these and reads their key=value output:
#
#   web-status      the app's state, for the page
#   web-apply       check changes (key=value lines on stdin), then hand them
#                   to a detached apply-settings
#
# Output values come from this script or from checked settings, never with
# line breaks; errors are "error=<message>" with exit status 1.

. "$(dirname "$0")/lib.sh"
TR_LOG_TAG="ctl $1"

# One-time copy of WD's config into $TR_CONFIG_DIR. WD's copy is never
# modified, so it stays as the way back.
migrate() {
    mkdir -p "$TR_CONFIG_DIR"
    if [ -f "$TR_WD_CONFIG_DIR/settings.json" ]; then
        cp -a "$TR_WD_CONFIG_DIR/." "$TR_CONFIG_DIR/"
        # WD's pidfile points at the file WD's stop.sh kills.
        tr_remove_setting pidfile
        tr_log "took over WD's settings and torrents from $TR_WD_CONFIG_DIR"
    else
        tr_write_fresh_settings
        tr_log "no WD settings found; created fresh ones (RPC password in $TR_INITIAL_PASSWORD)"
    fi
    # Files the share group can read and write; access by the NAS's names.
    tr_set_setting umask 2
    tr_set_setting rpc-host-whitelist "\"$(tr_host_names)\""
    tr_set_setting rpc-host-whitelist-enabled true
    tr_set_setting rpc-port "$TR_DEFAULT_RPC_PORT"

    chown -R "$TR_USER:$TR_GROUP" "$TR_CONFIG_DIR"
    chmod 750 "$TR_CONFIG_DIR"
    date '+%Y-%m-%d %H:%M:%S' > "$TR_MIGRATED"
}

cmd_start() {
    if [ -n "$(tr_our_pids)" ]; then
        tr_log "transmission-daemon already running (pid $(tr_our_pids))"
        return 0
    fi
    wd_pids=$(tr_wd_pids)
    if [ -n "$wd_pids" ]; then
        tr_log "WD's Transmission is running (pid $wd_pids); switch it OFF in Apps first. Not starting."
        return 1
    fi
    [ -f "$TR_MIGRATED" ] || migrate

    tr_ensure_allowed_file
    allowed=$(tr_allowed_list)
    port=$(tr_rpc_port)
    pid=$(tr_spawn_daemon "$allowed")
    tr_log "started transmission-daemon (pid $pid) as $TR_USER:$TR_GROUP, allowing $allowed; waiting for RPC on port $port"
    tr_await_listening "$pid"
    case $? in
        0)
            tr_log "transmission-daemon is serving RPC on port $port"
            tr_spawn_ctl log-keeper
            ;;
        2) tr_log "transmission-daemon exited; see $TR_DAEMON_LOG" ;;
        *) tr_log "no RPC on port $port after ${TR_START_TIMEOUT}s; leaving the daemon running; see $TR_DAEMON_LOG" ;;
    esac
}

# WD's re-install stores the new package's apkg.xml, which says Run App OFF,
# although init.sh starts Transmission again: should-run kept the old state
# through the upgrade. Once WD's installer has exited, store the switch the
# way it was. The dashboard page rebuilds its app list from apkg.xml when it
# loads, so the page shown after "App installed" already says ON.
#
# WD's "Updating" dialog sometimes never hears that the installer finished;
# then it gets WD's result from here.
cmd_restore_run_app() {
    tr_wait_for_wd_installer
    if [ ! -f "$TR_SHOULD_RUN" ]; then
        tr_log "Run App was switched OFF meanwhile; leaving it OFF"
    elif ! tr_wd_enabled; then
        tr_set_wd_enabled
        tr_log "after upgrade: Run App back ON, as it was before"
    fi
    # Only now, so the page that the dialog's OK reloads shows Run App ON.
    if tr_wd_dialog_stuck; then
        tr_finish_wd_dialog
        tr_log "WD's installer had finished, but its Updating dialog still said installing; passed WD's result on"
    fi
    if [ -f "$TR_SHOULD_RUN" ]; then
        make_dashboard_agree
    fi
}

# A boot found should-run set but Run App OFF (an upgrade before 4.1.4-6
# left it so). Let the boot settle first.
cmd_dashboard_on() {
    sleep "$TR_BOOT_DASHBOARD_DELAY"
    make_dashboard_agree
}

# Until the dashboard's app list shows Run App ON, ask WD for it the way the
# dashboard's own switch does; WD then runs start.sh, which finds the daemon
# running. WD drops such a request while it's busy, so check and retry.
make_dashboard_agree() {
    for attempt in 1 2 3; do
        sleep "$TR_DASHBOARD_DELAY"
        if [ ! -f "$TR_SHOULD_RUN" ]; then
            tr_log "Run App was switched OFF meanwhile; leaving it OFF"
            return 0
        fi
        if tr_dashboard_shows_on; then
            tr_log "Run App shows ON in the dashboard again"
            return 0
        fi
        tr_log "asking WD to show Run App ON again (attempt $attempt)"
        curl -s --max-time 20 -d "cmd=cgi_apps_set&f_module_name=$TR_PACKAGE&f_enable=1" \
            "$TR_WD_APPS_CGI" > /dev/null 2>&1
    done
    sleep 2
    if tr_dashboard_shows_on; then
        tr_log "Run App shows ON in the dashboard again"
    else
        tr_log "couldn't switch Run App back ON in the dashboard; Transmission runs anyway, so switch it ON yourself to match"
    fi
}

cmd_log_keeper() {
    exec 8> "$TR_KEEPER_LOCK"
    flock -n 8 || exit 0
    while [ -n "$(tr_our_pids)" ]; do
        tr_truncate_if_large "$TR_DAEMON_LOG"
        sleep "$TR_KEEPER_INTERVAL"
    done
}

# --- the Configure page ----------------------------------------------------------

flag() {
    if [ -e "$1" ]; then echo 1; else echo 0; fi
}

cmd_web_status() {
    if [ -z "$(tr_our_pids)" ]; then
        echo daemon=stopped
    elif tr_rpc_listening; then
        echo daemon=running
    else
        echo daemon=starting
    fi
    echo "should_run=$(flag "$TR_SHOULD_RUN")"
    echo "set_up=$(flag "$TR_MIGRATED")"
    if [ -n "$(tr_wd_pids)" ]; then echo wd_running=1; else echo wd_running=0; fi
    echo "initial_password=$(flag "$TR_INITIAL_PASSWORD")"
    echo "port=$(tr_rpc_port)"
    # The user name as its raw JSON string; api.php decodes it.
    echo "username_json=$(tr_get_setting rpc-username)"
    case $(tr_get_setting rpc-password) in
        "" | '""') echo password_set=0 ;;
        *) echo password_set=1 ;;
    esac
    patterns=$(tr_allowed_patterns)
    printf '%s\n' "${patterns:-$TR_DEFAULT_ALLOWED}" | sed 's/^/allowed=/'
    if [ -f "$TR_APPLY_RESULT" ]; then
        cat "$TR_APPLY_RESULT"
    fi
}

# Read key=value lines from stdin into username, password_hash, port and
# allowed (one pattern per line). Unknown keys are ignored.
read_settings_input() {
    username="" password_hash="" port="" allowed=""
    while IFS= read -r line || [ -n "$line" ]; do
        value=${line#*=}
        case $line in
            username=*) username=$value ;;
            password_hash=*) password_hash=$value ;;
            port=*) port=$value ;;
            allowed=*) allowed="$allowed$value
" ;;
        esac
    done
    allowed=$(printf '%s' "$allowed")
}

# Print "error=..." for the first value that doesn't pass; return 1 then.
check_settings_input() {
    if ! tr_valid_username "$username"; then
        echo "error=The user name must be 1 to 64 letters, digits, dots, dashes, underscores or @."
    elif [ -n "$password_hash" ] && ! tr_valid_password_hash "$password_hash"; then
        echo "error=The password couldn't be stored; nothing was changed."
    elif ! tr_valid_port "$port"; then
        echo "error=The port must be a number from 1024 to 65535."
    elif ! tr_valid_allowed "$allowed"; then
        echo "error=Allowed addresses must be patterns such as 192.168.1.*, one per line."
    else
        return 0
    fi
    return 1
}

# Record <state> (applying, done, failed) and <message> for web-status.
write_apply_result() {
    {
        echo "apply_state=$1"
        echo "apply_message=$2"
        echo "apply_time=$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$TR_APPLY_RESULT"
}

cmd_web_apply() {
    if [ ! -f "$TR_MIGRATED" ]; then
        echo "error=Transmission isn't set up yet: switch the app ON first, with WD's Transmission OFF."
        return 1
    fi
    read_settings_input
    check_settings_input || return 1
    if [ "$port" != "$(tr_rpc_port)" ] && tr_port_in_use "$port"; then
        echo "error=Port $port is already in use on the NAS; choose another."
        return 1
    fi
    # The hash isn't the password, but keep it root's alone all the same.
    (
        umask 077
        {
            echo "username=$username"
            [ -n "$password_hash" ] && echo "password_hash=$password_hash"
            echo "port=$port"
            printf '%s\n' "$allowed" | sed 's/^/allowed=/'
        } > "$TR_PENDING.new"
    ) && mv -f "$TR_PENDING.new" "$TR_PENDING"
    write_apply_result applying "Saving and restarting Transmission..."
    tr_spawn_ctl apply-settings
    echo accepted=1
}

cmd_apply_settings() {
    # On a timeout the pending file stays: it may already hold a newer save,
    # whose own apply-settings is waiting too.
    if ! tr_take_lock_waiting 120; then
        write_apply_result failed "Another operation kept the app busy; nothing was changed. Try again."
        return 1
    fi
    if [ ! -f "$TR_PENDING" ]; then
        tr_log "no pending settings; nothing to do"
        return 0
    fi
    read_settings_input < "$TR_PENDING"
    rm -f "$TR_PENDING"
    if ! reason=$(check_settings_input); then
        write_apply_result failed "${reason#error=}"
        return 1
    fi

    tr_stop_daemon
    tr_set_setting rpc-username "\"$username\""
    tr_set_setting rpc-port "$port"
    tr_set_setting rpc-authentication-required true
    if [ -n "$password_hash" ]; then
        tr_set_setting rpc-password "\"$password_hash\""
        rm -f "$TR_INITIAL_PASSWORD"
    fi
    chown "$TR_USER:$TR_GROUP" "$TR_CONFIG_DIR/settings.json"
    tr_write_allowed_file "$allowed"
    tr_log "Configure page: user $username, port $port${password_hash:+, new password}, allowing $(echo "$allowed" | tr '\n' ' ')"

    if [ ! -f "$TR_SHOULD_RUN" ]; then
        write_apply_result "done" "Saved. Switch the app ON to start Transmission."
        return 0
    fi
    cmd_start
    if [ -n "$(tr_our_pids)" ] && tr_rpc_listening; then
        write_apply_result "done" "Saved. Transmission is running on port $port."
    else
        write_apply_result failed "Saved, but Transmission didn't start on port $port. See $TR_DAEMON_LOG."
    fi
}

case "$1" in
    start)
        tr_take_lock_or_exit
        cmd_start
        ;;
    log-keeper)
        cmd_log_keeper
        ;;
    apply-settings)
        cmd_apply_settings
        ;;
    restore-run-app)
        cmd_restore_run_app
        ;;
    dashboard-on)
        cmd_dashboard_on
        ;;
    web-status)
        cmd_web_status
        ;;
    web-apply)
        cmd_web_apply
        ;;
    *)
        echo "usage: ctl.sh start|log-keeper|apply-settings|restore-run-app|dashboard-on|web-status|web-apply" >&2
        exit 2
        ;;
esac
