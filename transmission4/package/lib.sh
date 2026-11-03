#!/bin/sh
# Constants defined here are used by the scripts that source this file.
# shellcheck disable=SC2034
#
# lib.sh — shared by every script of the Transmission 4 app (sourced; POSIX
# sh, runs under the NAS's busybox).
#
# Design (README.md, docs/os5-app-lifecycle.md):
# - Config, flags and logs live in $TR_HOME, outside the app folder that
#   every upgrade replaces. It's not under .systemfile, which is root-only,
#   because the daemon runs as nobody:share and must reach its config.
# - Downloads in $TR_DOWNLOAD_DIR are the user's data: no script moves,
#   deletes or re-owns anything there.
# - WD's own Transmission app must not run at the same time (same port, same
#   downloads), and its scripts must never match this app's daemon: its
#   remove.sh kills anything matching "transmission-daemon ... port 9091" and
#   its stop.sh kills the PID in /var/run/addon_transmission.pid. So the RPC
#   port comes from settings.json, never from a --port flag, and WD's
#   "pidfile" setting is dropped when its settings are taken over.
# - The Configure page (web/settings.html) changes the login, port and
#   allowed addresses through ctl.sh, which checks every value again before
#   writing it. Transmission rewrites settings.json when it stops, so changes
#   are written while the daemon is stopped, then it starts again.

TR_PACKAGE=transmission4
TR_VOLUME=/mnt/HD/HD_a2
TR_APP_DIR=$TR_VOLUME/Nas_Prog/$TR_PACKAGE
TR_HOME=$TR_VOLUME/.$TR_PACKAGE
TR_CONFIG_DIR=$TR_HOME/config
TR_LOG_DIR=$TR_HOME/log
TR_DAEMON_LOG=$TR_LOG_DIR/transmission.log
TR_SHOULD_RUN=$TR_HOME/should-run
TR_UPGRADING=$TR_HOME/upgrading
TR_MIGRATED=$TR_HOME/migrated
TR_INITIAL_PASSWORD=$TR_HOME/initial-password
TR_ALLOWED_FILE=$TR_HOME/allowed-networks
TR_PENDING=$TR_HOME/pending-settings
TR_APPLY_RESULT=$TR_HOME/apply-result
TR_LOCK=$TR_HOME/lock
TR_KEEPER_LOCK=$TR_HOME/log-keeper.lock
TR_DOWNLOAD_DIR=$TR_VOLUME/Transmission
TR_DEFAULT_RPC_PORT=9091
TR_USER=nobody

# Dashboard pages: /var/www/apps/<package> is the only place behind the
# dashboard login (CenterType 1). Up to 4.1.4-2 they were in the open
# /var/www/<package>, which is cleaned up.
TR_WEB_DIR=/var/www/apps/$TR_PACKAGE
TR_OLD_WEB_DIR=/var/www/$TR_PACKAGE
TR_GROUP=share

# WD's own Transmission app, whose settings are taken over once.
TR_WD_CONFIG_DIR=$TR_VOLUME/Nas_Prog/Transmission/config

# Who may reach RPC and the web UI by default (a login is required as well):
# private LAN ranges and Tailscale's 100.64.0.0/10. Transmission matches these
# as wildcard patterns with [ranges], not CIDR, so 172.16.0.0/12 and
# 100.64.0.0/10 are spelled out. One pattern per line, as in $TR_ALLOWED_FILE.
TR_DEFAULT_ALLOWED='10.*.*.*
172.1[6-9].*.*
172.2[0-9].*.*
172.3[01].*.*
192.168.*.*
100.6[4-9].*.*
100.[7-9][0-9].*.*
100.1[01][0-9].*.*
100.12[0-7].*.*'

# WD's app manager, as the dashboard's Run App switch calls it (Apache, for
# local requests only), and the list of installed apps the dashboard page
# reads. WD rebuilds that list from each app's apkg.xml.
TR_WD_APPS_CGI=http://127.0.0.1:8000/cgi-bin/apkg_mgr.cgi
TR_WD_APP_LIST=${TR_WD_APP_LIST:-/var/www/xml/apkg_all.xml}

# WD's installer records its result here (1: installed), then copies it into
# the install record that the dashboard's "Updating" dialog polls.
TR_WD_INSTALL_RESULT=/tmp/upload_apkg_status
TR_WD_INSTALL_RECORD=/var/www/xml/apkg_state.xml

# Timings in seconds. The environment overrides exist only so tests run fast;
# WD's app manager passes none of these. TR_WD_INSTALL_TIMEOUT caps the wait
# for WD's installer to exit; TR_BOOT_DASHBOARD_DELAY lets a boot settle and
# TR_DASHBOARD_DELAY spaces the checks before WD is asked to show Run App ON.
TR_WD_INSTALL_TIMEOUT=${TR_WD_INSTALL_TIMEOUT:-120}
TR_BOOT_DASHBOARD_DELAY=${TR_BOOT_DASHBOARD_DELAY:-20}
TR_DASHBOARD_DELAY=${TR_DASHBOARD_DELAY:-5}
TR_START_TIMEOUT=${TR_START_TIMEOUT:-60}
TR_STOP_TIMEOUT=${TR_STOP_TIMEOUT:-30}
TR_KEEPER_INTERVAL=${TR_KEEPER_INTERVAL:-60}
TR_UPGRADE_FLAG_MAX_AGE=900
TR_LOG_MAX_BYTES=1048576

TR_LOG_TAG=${TR_LOG_TAG:-$(basename "$0")}

# --- logging ---------------------------------------------------------------

tr_rotate_if_large() {
    [ -f "$1" ] || return 0
    [ "$(wc -c < "$1")" -gt "$TR_LOG_MAX_BYTES" ] || return 0
    mv -f "$1" "$1.1"
}

# For a log the daemon keeps open: copy and truncate rather than rename.
tr_truncate_if_large() {
    [ -f "$1" ] || return 0
    [ "$(wc -c < "$1")" -gt "$TR_LOG_MAX_BYTES" ] || return 0
    cp -f "$1" "$1.1" && : > "$1"
}

tr_log() {
    mkdir -p "$TR_LOG_DIR" 2> /dev/null || return 0
    tr_rotate_if_large "$TR_LOG_DIR/app.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${TR_LOG_TAG}[$$]: $*" >> "$TR_LOG_DIR/app.log"
}

# --- processes ---------------------------------------------------------------

tr_cmdline() {
    tr '\0' ' ' 2> /dev/null < "/proc/$1/cmdline"
}

# PIDs of every transmission-daemon, this app's or WD's. Reads /proc: the
# process name is cut at 15 characters, and a test stub runs as a script.
tr_daemon_pids() {
    for tr_proc in /proc/[0-9]*; do
        tr '\0' '\n' 2> /dev/null < "$tr_proc/cmdline" \
            | awk 'NR <= 2 && /(^|\/)transmission-daemon$/ { found = 1; exit } END { exit !found }' \
            && echo "${tr_proc#/proc/}"
    done
}

# This app's daemon runs on this app's config folder; anything else is WD's.
tr_is_ours() {
    case " $(tr_cmdline "$1") " in
        *" --config-dir $TR_CONFIG_DIR "*) return 0 ;;
    esac
    return 1
}

tr_our_pids() {
    for tr_pid in $(tr_daemon_pids); do
        tr_is_ours "$tr_pid" && echo "$tr_pid"
    done
}

tr_wd_pids() {
    for tr_pid in $(tr_daemon_pids); do
        tr_is_ours "$tr_pid" || echo "$tr_pid"
    done
}

# SIGTERM, then up to TR_STOP_TIMEOUT for Transmission to save resume data,
# then SIGKILL.
tr_stop_pid() {
    kill "$1" 2> /dev/null || return 0
    tr_waited=0
    while kill -0 "$1" 2> /dev/null; do
        if [ "$tr_waited" -ge "$TR_STOP_TIMEOUT" ]; then
            tr_log "pid $1 still running after ${TR_STOP_TIMEOUT}s; sending SIGKILL"
            kill -9 "$1" 2> /dev/null
            return 0
        fi
        sleep 1
        tr_waited=$((tr_waited + 1))
    done
}

tr_stop_daemon() {
    for tr_pid in $(tr_our_pids); do
        tr_log "stopping transmission-daemon (pid $tr_pid)"
        tr_stop_pid "$tr_pid"
    done
}

tr_port_in_use() {
    netstat -ltn 2> /dev/null | grep -q "[:.]$1 "
}

tr_rpc_listening() {
    tr_port_in_use "$(tr_rpc_port)"
}

# --- checking values ---------------------------------------------------------
# The Configure page checks these too; ctl.sh checks again before writing.

tr_valid_username() {
    case $1 in
        "" | *[!A-Za-z0-9._@-]*) return 1 ;;
    esac
    [ "${#1}" -le 64 ]
}

# A port a nobody-owned daemon can open: 1024-65535, no leading zero.
tr_valid_port() {
    case $1 in
        "" | 0* | *[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

# Transmission's salted SHA-1 form: "{", 40 hex digits, an 8-character salt.
# The length check also rules out a second line.
tr_valid_password_hash() {
    [ "${#1}" -eq 49 ] && printf '%s\n' "$1" | grep -qxE '\{[0-9a-f]{40}[0-9A-Za-z./]{8}'
}

# One or more lines of address patterns: digits, dots, * ? and [ranges].
tr_valid_allowed() {
    [ -n "$1" ] && ! printf '%s\n' "$1" | grep -q '[^]0-9.*?[-]'
}

# --- allowed networks --------------------------------------------------------

# Write <patterns> (one per line) to $TR_ALLOWED_FILE, with how to edit it.
tr_write_allowed_file() {
    {
        echo "# Addresses that may reach Transmission's RPC and web UI."
        echo "# A login is required as well, and 127.0.0.1 is always allowed."
        echo "# One pattern per line: * and ? are wildcards, [0-9] is a range; no CIDR."
        echo "# Change it on the app's Configure page, or edit it here and switch the"
        echo "# app OFF and ON in the dashboard."
        echo "$1"
    } > "$TR_ALLOWED_FILE.new" && mv -f "$TR_ALLOWED_FILE.new" "$TR_ALLOWED_FILE"
}

tr_ensure_allowed_file() {
    [ -f "$TR_ALLOWED_FILE" ] || tr_write_allowed_file "$TR_DEFAULT_ALLOWED"
}

# The patterns in $TR_ALLOWED_FILE, one per line. Nothing if the file is
# missing or empty, or holds anything but address patterns: it's ignored as
# a whole then, so a typo can't widen access in some unexpected way.
tr_allowed_patterns() {
    tr_patterns=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$TR_ALLOWED_FILE" 2> /dev/null)
    tr_valid_allowed "$tr_patterns" && echo "$tr_patterns"
}

# The patterns in effect, comma-separated, 127.0.0.1 first.
tr_allowed_list() {
    tr_patterns=$(tr_allowed_patterns)
    if [ -z "$tr_patterns" ]; then
        tr_log "$TR_ALLOWED_FILE is missing, empty or has something other than address patterns; using the defaults"
        tr_patterns=$TR_DEFAULT_ALLOWED
    fi
    # No "name (" anywhere in the awk program: BusyBox 1.30's awk, the NAS's,
    # reads that as a function call.
    printf '127.0.0.1\n%s\n' "$tr_patterns" \
        | awk '!seen[$0]++ { list = list sep $0; sep = "," } END { print list }'
}

# --- the daemon -----------------------------------------------------------------

# Start the daemon as nobody:share, allowing the comma-separated address
# patterns <allowed>, and print its PID. In the foreground it logs to stderr,
# which goes to $TR_DAEMON_LOG. The double fork reparents it to init; fd 9
# (the app lock) is not inherited. No --port flag on purpose (see the header).
tr_spawn_daemon() {
    mkdir -p "$TR_LOG_DIR"
    tr_truncate_if_large "$TR_DAEMON_LOG"
    touch "$TR_DAEMON_LOG"
    chown "$TR_USER:$TR_GROUP" "$TR_DAEMON_LOG"
    (
        cd / || exit 1
        TRANSMISSION_WEB_HOME=$TR_APP_DIR/share/transmission/public_html \
            nohup "$TR_APP_DIR/bin/su-exec" "$TR_USER:$TR_GROUP" \
            "$TR_APP_DIR/bin/transmission-daemon" --foreground \
            --config-dir "$TR_CONFIG_DIR" \
            --download-dir "$TR_DOWNLOAD_DIR" \
            --rpc-bind-address 0.0.0.0 \
            --allowed "$1" \
            --auth --no-portmap \
            >> "$TR_DAEMON_LOG" 2>&1 < /dev/null 9>&- &
        echo $!
    )
}

# Wait until daemon <pid> serves RPC. Returns 0 when listening, 1 on
# timeout, 2 if it exited.
tr_await_listening() {
    tr_waited=0
    while [ "$tr_waited" -lt "$TR_START_TIMEOUT" ]; do
        kill -0 "$1" 2> /dev/null || return 2
        tr_rpc_listening && return 0
        sleep 1
        tr_waited=$((tr_waited + 1))
    done
    return 1
}

tr_spawn_ctl() {
    mkdir -p "$TR_LOG_DIR"
    (nohup sh "$TR_APP_DIR/ctl.sh" "$1" >> "$TR_LOG_DIR/app.log" 2>&1 < /dev/null 9>&- &)
}

# --- settings ------------------------------------------------------------------

# Names the NAS answers to, for rpc-host-whitelist (DNS-rebinding protection):
# its hostname and anything under it, such as .local or the MagicDNS name.
tr_host_names() {
    tr_host=$(hostname | tr '[:upper:]' '[:lower:]')
    echo "$tr_host,$tr_host.*"
}

# The raw JSON value of <key> in settings.json ("text" with its quotes, a
# number, true), or nothing. Transmission writes one key per line.
tr_get_setting() {
    sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\(.*\)/\1/p" "$TR_CONFIG_DIR/settings.json" 2> /dev/null \
        | sed 's/,[[:space:]]*$//' | head -n 1
}

# The RPC port from settings.json (the Configure page can change it), or the
# default before the first start.
tr_rpc_port() {
    tr_port=$(tr_get_setting rpc-port)
    tr_valid_port "$tr_port" || tr_port=$TR_DEFAULT_RPC_PORT
    echo "$tr_port"
}

# Set <key> to the raw JSON <value> in settings.json, keeping the line's
# trailing comma; add the key after the opening brace if it's missing.
# Transmission writes one key per line, so line edits are safe here.
tr_set_setting() {
    tr_settings=$TR_CONFIG_DIR/settings.json
    if grep -q "^[[:space:]]*\"$1\":" "$tr_settings"; then
        # Two plain substitutions (no regex alternation, for busybox): lines
        # that end with a comma keep it, the last key stays without one.
        sed -i \
            -e "s|^\([[:space:]]*\"$1\":\).*,[[:space:]]*\$|\1 $2,|" \
            -e "s|^\([[:space:]]*\"$1\":\).*[^,[:space:]][[:space:]]*\$|\1 $2|" \
            "$tr_settings"
    else
        sed -i "1a\\
    \"$1\": $2," "$tr_settings"
    fi
}

tr_remove_setting() {
    sed -i "/^[[:space:]]*\"$1\":/d" "$TR_CONFIG_DIR/settings.json"
}

# Settings for a NAS without WD's app: a random RPC password, saved for you
# in $TR_INITIAL_PASSWORD. Transmission replaces it in settings.json with its
# hash when it next stops; until then only root and the file's owner (once
# chowned to the daemon's user) can read it.
tr_write_fresh_settings() {
    tr_password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    (umask 077 && echo "$tr_password" > "$TR_INITIAL_PASSWORD")
    (umask 077 && cat > "$TR_CONFIG_DIR/settings.json") << EOF
{
    "download-dir": "$TR_DOWNLOAD_DIR",
    "port-forwarding-enabled": false,
    "rpc-authentication-required": true,
    "rpc-password": "$tr_password",
    "rpc-port": $TR_DEFAULT_RPC_PORT,
    "rpc-username": "transmission",
    "umask": 2
}
EOF
}

# --- flags and WD state --------------------------------------------------------

tr_upgrade_in_progress() {
    [ -f "$TR_UPGRADING" ] || return 1
    tr_flag_age=$(($(date +%s) - $(stat -c %Y "$TR_UPGRADING")))
    [ "$tr_flag_age" -lt "$TR_UPGRADE_FLAG_MAX_AGE" ]
}

# WD's Run App switch, as stored in the installed apkg.xml.
tr_wd_enabled() {
    [ "$(sed -n 's/.*<enable>\(.*\)<\/enable>.*/\1/p' "$TR_APP_DIR/apkg.xml" 2> /dev/null)" = 1 ]
}

# Store Run App ON the way WD itself does, in the installed apkg.xml.
tr_set_wd_enabled() {
    sed -i 's#<enable>0</enable>#<enable>1</enable>#' "$TR_APP_DIR/apkg.xml"
}

# Whether the dashboard's app list shows Run App ON. Without that list, the
# stored switch is all there is.
tr_dashboard_shows_on() {
    if [ ! -f "$TR_WD_APP_LIST" ]; then
        tr_wd_enabled
        return
    fi
    tr_listed=$(awk -v name="<name>$TR_PACKAGE</name>" '
        index($0, name) { found = 1 }
        found && /<enable>/ { gsub(/[^0-9]/, ""); print; exit }' "$TR_WD_APP_LIST")
    [ "$tr_listed" = 1 ]
}

# WD's installer, upload_apkg, runs a whole install or upgrade, init.sh last,
# and stores the new package's apkg.xml along the way. Wait until it exits.
tr_wait_for_wd_installer() {
    tr_waited=0
    while pidof upload_apkg > /dev/null 2>&1 && [ "$tr_waited" -lt "$TR_WD_INSTALL_TIMEOUT" ]; do
        sleep 1
        tr_waited=$((tr_waited + 1))
    done
}

# Whether WD's installer recorded "installed", but the dialog's record for
# this app still says 100 (installing): the copy stayed behind, and the
# dialog would wait for good.
tr_wd_dialog_stuck() {
    [ "$(cat "$TR_WD_INSTALL_RESULT" 2> /dev/null)" = 1 ] \
        && grep -q "<name>$TR_PACKAGE</name>" "$TR_WD_INSTALL_RECORD" 2> /dev/null \
        && grep -q '<install_status>100</install_status>' "$TR_WD_INSTALL_RECORD" 2> /dev/null
}

# Give the dialog WD's own result, as WD's copy would have.
tr_finish_wd_dialog() {
    sed -i 's#<install_status>100</install_status>#<install_status>1</install_status>#' "$TR_WD_INSTALL_RECORD"
}

# $TR_HOME is group "share" (750) so nobody can reach config/; flags and
# app.log stay root's.
tr_prepare_home() {
    mkdir -p "$TR_HOME" "$TR_LOG_DIR"
    chown "root:$TR_GROUP" "$TR_HOME"
    chmod 750 "$TR_HOME"
}

tr_take_lock_or_exit() {
    tr_prepare_home
    exec 9> "$TR_LOCK"
    if ! flock -n 9; then
        tr_log "another operation holds the lock; nothing to do"
        exit 0
    fi
}

# Hold the app lock for the rest of the calling script, waiting up to
# <seconds> for another operation (such as a start) to finish first.
# Returns 1 if it's still busy.
tr_take_lock_waiting() {
    tr_prepare_home
    exec 9> "$TR_LOCK"
    tr_waited=0
    until flock -n 9; do
        [ "$tr_waited" -ge "$1" ] && return 1
        sleep 1
        tr_waited=$((tr_waited + 1))
    done
}

tr_link_web() {
    rm -rf "$TR_OLD_WEB_DIR"
    mkdir -p "$TR_WEB_DIR"
    ln -sf "$TR_APP_DIR"/web/* "$TR_WEB_DIR"/
}

tr_unlink_web() {
    rm -rf "$TR_WEB_DIR" "$TR_OLD_WEB_DIR"
}
