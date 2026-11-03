#!/bin/sh
# transmission-sim.sh <stub .bin> — runs inside a busybox container.
#
# Drives the Transmission 4 app through WD's measured script sequences
# (docs/os5-app-lifecycle.md) on a NAS-like tree: WD's Transmission app with
# its config (shaped like the real one, including the "pidfile" setting) and
# a running WD daemon, plus a download whose checksum must never change.
# Stubs (tests/stubs) stand in for transmission-daemon and su-exec.
#
# Usage (from WSL, repo root):
#   transmission4/build.sh --stub
#   docker run --rm --init --network none -v "$PWD:/work:ro" busybox:1.30.1 \
#       sh /work/tests/transmission-sim.sh /work/dist/MyCloudEX2Ultra_transmission4_<version>-stub.bin
#
# --init matters: daemons are reparented to PID 1, which must reap them.

set -u

BIN=$1
STUBS=/work/tests/stubs
NAS_PROG=/mnt/HD/HD_a2/Nas_Prog
STAGED=$NAS_PROG/_install/transmission4
APP=$NAS_PROG/transmission4
APP_HOME=/mnt/HD/HD_a2/.transmission4
CONFIG=$APP_HOME/config
WD_CONFIG=$NAS_PROG/Transmission/config
DOWNLOADS=/mnt/HD/HD_a2/Transmission
HEADER_BYTES=204

export TR_START_TIMEOUT=10 TR_STOP_TIMEOUT=3 TR_KEEPER_INTERVAL=1 TR_DASHBOARD_DELAY=1 TR_BOOT_DASHBOARD_DELAY=1

# The --allowed value the app's defaults produce.
DEFAULT_ALLOWED='127.0.0.1,10.*.*.*,172.1[6-9].*.*,172.2[0-9].*.*,172.3[01].*.*,192.168.*.*,100.6[4-9].*.*,100.[7-9][0-9].*.*,100.1[01][0-9].*.*,100.12[0-7].*.*'

failures=0

# --- helpers -------------------------------------------------------------------

section() { printf '\n=== %s\n' "$*"; }

expect() {
    if eval "$1"; then
        echo "ok:   $2"
    else
        echo "FAIL: $2"
        failures=$((failures + 1))
    fi
}

wait_for() { # <condition> <seconds>
    remaining=$2
    until eval "$1"; do
        [ "$remaining" -le 0 ] && return 1
        sleep 1
        remaining=$((remaining - 1))
    done
}

daemons() {
    for proc in /proc/[0-9]*; do
        cmd=$(tr '\0' ' ' 2> /dev/null < "$proc/cmdline")
        case "$cmd" in
            *transmission-daemon*) echo "${proc#/proc/} $cmd" ;;
        esac
    done
}
ours_running() { daemons | grep -q -- "--config-dir $CONFIG "; }
wd_running() { daemons | grep -q -- "--config-dir $WD_CONFIG "; }
our_pid() { daemons | grep -- "--config-dir $CONFIG " | awk '{ print $1 }' | head -n 1; }
our_cmdline() { daemons | grep -- "--config-dir $CONFIG " | head -n 1; }
listening() { netstat -ltn 2> /dev/null | grep -q ':9091 '; }

ctl_busy() {
    for proc in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2> /dev/null < "$proc/cmdline")" in
            *"ctl.sh start"* | *"ctl.sh restore-run-app"* | *"ctl.sh dashboard-on"*) return 0 ;;
        esac
    done
    return 1
}
wait_idle() { wait_for "! ctl_busy" 30; }

mark_log() { log_mark=$(wc -l < "$APP_HOME/log/app.log" 2> /dev/null || echo 0); }
logged() { tail -n +$((log_mark + 1)) "$APP_HOME/log/app.log" 2> /dev/null | grep -q -- "$1"; }

enabled() { grep -q '<enable>1</enable>' "$APP/apkg.xml"; }
set_enable() { sed -i "s#<enable>[0-9]*</enable>#<enable>$1</enable>#" "$APP/apkg.xml"; }
setting() { sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\(.*\)/\1/p" "$CONFIG/settings.json" | sed 's/,$//'; }
# As the Configure page's api.php runs it: as root, input on stdin.
ctl() { sh "$APP/ctl.sh" "$@"; }

# Flat JSON, one key per line: braces on the first and last lines, and every
# key line ends with a comma except the last one.
json_well_formed() {
    json=$CONFIG/settings.json
    lines=$(wc -l < "$json")
    [ "$(head -n 1 "$json")" = "{" ] && [ "$(tail -n 1 "$json")" = "}" ] \
        && [ "$(grep -c ',$' "$json")" -eq $((lines - 3)) ] \
        && ! tail -n 2 "$json" | head -n 1 | grep -q ',$'
}

start_wd_daemon() {
    (nohup transmission-daemon -M --port 9091 --config-dir "$WD_CONFIG" --download-dir "$DOWNLOADS" \
        --pid-file /var/run/addon_transmission.pid > /dev/null 2>&1 < /dev/null &)
}
stop_wd_daemon() {
    for pid in $(daemons | grep -- "--config-dir $WD_CONFIG " | awk '{ print $1 }'); do kill "$pid"; done
    wait_for "! wd_running" 10
    sleep 1
}

stage_package() {
    rm -rf "$NAS_PROG/_install"
    mkdir -p "$NAS_PROG/_install"
    tail -c +$((HEADER_BYTES + 1)) "$BIN" | tar -xzf - -C "$NAS_PROG/_install"
}

# --- WD's sequences, as measured ---------------------------------------------

wd_install() {
    stage_package
    "$STAGED/before_apkg.sh"
    mkdir -p "$APP"
    "$STAGED/install.sh" "$STAGED" "$NAS_PROG"
    "$APP/init.sh" "$APP"
    set_enable 0
}
wd_switch_on() { set_enable 1; "$APP/start.sh" "$APP"; }
wd_switch_off() { set_enable 0; "$APP/stop.sh" "$APP"; }
wd_upgrade_begin() {
    stage_package
    "$STAGED/before_apkg.sh"
    enabled && "$APP/stop.sh" "$APP"
    "$APP/clean.sh" "$APP"
    "$APP/preinst.sh" "$APP"
    "$APP/remove.sh" "$APP"
}
# WD's installer process runs throughout; it stores the new package's switch
# (OFF) last, after init.sh, the worst case for the app's restore. Then it
# records its result and copies it into the dialog's install record, which
# OK has set to 100 (installing). <outcome>: "installed" (the default) or
# "lost-copy" (the record stays at 100, as in WD's dialog hangs).
wd_upgrade_finish() {
    write_install_record 100 transmission4
    echo 100 > /tmp/upload_apkg_status
    touch /tmp/wd-installing
    (upload_apkg &)
    mkdir -p "$APP"
    "$STAGED/install.sh" "$STAGED" "$NAS_PROG"
    "$APP/init.sh" "$APP"
    sleep 1
    set_enable 0
    case ${1:-installed} in
        installed) echo 1 > /tmp/upload_apkg_status && write_install_record 1 transmission4 ;;
        lost-copy) echo 1 > /tmp/upload_apkg_status ;;
    esac
    rm -f /tmp/wd-installing
}
# The install record the "Updating" dialog polls, as WD writes it: <status>, <app>.
write_install_record() {
    mkdir -p /var/www/xml
    printf '<?xml version="1.0" encoding="UTF-8" ?>\n<config>\n<install_type>1</install_type>\n<install_status>%s</install_status>\n<install_filename>MyCloudEX2Ultra_%s.bin</install_filename>\n<name>%s</name>\n<dep_apps></dep_apps>\n</config>\n' \
        "$1" "$2" "$2" > /var/www/xml/apkg_state.xml
    chmod 666 /var/www/xml/apkg_state.xml
}
dialog_status() { sed -n 's#<install_status>\(.*\)</install_status>#\1#p' /var/www/xml/apkg_state.xml; }
power_off() {
    for proc in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2> /dev/null < "$proc/cmdline")" in
            *transmission-daemon* | *ctl.sh* | *httpd*) kill -9 "${proc#/proc/}" 2> /dev/null ;;
        esac
    done
    sleep 1
}
wd_shutdown() {
    for round in 1 2; do
        enabled && "$APP/stop.sh" "$APP"
        "$APP/clean.sh" "$APP"
        : "$round"
    done
    power_off
}
wd_boot() {
    "$APP/init.sh" "$APP"
    if enabled; then
        "$APP/stop.sh" "$APP"
        "$APP/start.sh" "$APP"
    fi
}
wd_uninstall() {
    enabled && "$APP/stop.sh" "$APP"
    "$APP/clean.sh" "$APP"
    "$APP/remove.sh" "$APP"
}

# Uninstalling WD's own Transmission app, reproduced from its scripts: its
# stop.sh kills the PID in its pid file; its remove.sh kills every daemon
# whose ps line has "port 9091", then deletes its app folder (config
# included), its daemon in PATH and its web folders.
wd_transmission_uninstall() {
    wd_pid_file=/var/run/addon_transmission.pid
    [ -s "$wd_pid_file" ] && kill "$(cat "$wd_pid_file")" 2> /dev/null
    # shellcheck disable=SC2009  # WD's exact ps | grep match is what's being tested
    for pid in $(ps | grep transmission-daemon | grep 'port 9091' | awk '{ print $1 }'); do kill "$pid"; done
    rm -rf "$NAS_PROG/Transmission" /var/www/Transmission /var/www/apps/Transmission \
        /usr/local/bin/transmission-daemon
    sleep 1
}

# --- setup: WD's Transmission app running, as on the NAS ----------------------

mkdir -p "$NAS_PROG" "$DOWNLOADS" /var/www "$WD_CONFIG/torrents" "$WD_CONFIG/resume" "$WD_CONFIG/blocklists"
grep -q '^share:' /etc/group || echo 'share:x:1000:nobody' >> /etc/group
# WD starts its daemon by name from PATH (/usr/bin on the NAS).
mkdir -p /usr/local/bin
cp "$STUBS/transmission-daemon" /usr/local/bin/transmission-daemon
# WD's Run App switch, as the app calls it after an upgrade, and WD's
# installer process, which the app waits for.
cp "$STUBS/curl" "$STUBS/upload_apkg" /usr/local/bin/
chmod 755 /usr/local/bin/curl /usr/local/bin/upload_apkg
chmod 755 /usr/local/bin/transmission-daemon
cat > "$WD_CONFIG/settings.json" << 'EOF'
{
    "download-dir": "/mnt/HD/HD_a2/Transmission",
    "peer-port": 62460,
    "pidfile": "/var/run/addon_transmission.pid",
    "port-forwarding-enabled": false,
    "ratio-limit": 2,
    "rpc-authentication-required": true,
    "rpc-bind-address": "127.0.0.1",
    "rpc-host-whitelist": "",
    "rpc-host-whitelist-enabled": true,
    "rpc-password": "{0123456789abcdef0123456789abcdef01234567Abcdefgh",
    "rpc-port": 9091,
    "rpc-username": "transmission",
    "rpc-whitelist": "*.*.*.*",
    "umask": 0,
    "utp-enabled": true
}
EOF
echo dht > "$WD_CONFIG/dht.dat"
wd_md5=$(cat "$WD_CONFIG/settings.json" "$WD_CONFIG/dht.dat" | md5sum | cut -d' ' -f1)
echo "finished download" > "$DOWNLOADS/existing.iso"
chmod 666 "$DOWNLOADS/existing.iso"
downloads_md5=$(md5sum < "$DOWNLOADS/existing.iso")
start_wd_daemon
wait_for listening 10

section "1. Fresh install, Run App OFF"
# Where 4.1.4-2 and earlier linked the page, outside the dashboard login.
mkdir -p /var/www/transmission4 && touch /var/www/transmission4/index.html
wd_install
expect wd_running "WD's daemon is untouched"
expect "! ours_running" "install starts nothing"
expect "[ -f /var/www/apps/transmission4/index.html ] && [ -f /var/www/apps/transmission4/api.php ]" "dashboard pages linked into /var/www/apps/transmission4"
expect "[ ! -e /var/www/transmission4 ]" "the old open page folder is gone"
expect "[ \"\$(stat -c %G '$APP_HOME')\" = share ] && [ \"\$(stat -c %a '$APP_HOME')\" = 750 ]" "app home is root:share 750"

section "2. Run App ON while WD's Transmission runs: refused"
mark_log
wd_switch_on
sleep 2
expect "logged 'switch it OFF in Apps'" "the refusal is logged"
expect "! ours_running" "no second daemon"
expect "[ ! -f '$APP_HOME/should-run' ]" "should-run not set, so no surprise start at boot"
expect "[ ! -d '$CONFIG' ]" "nothing taken over yet"

section "3. WD's app OFF, then Run App ON: takeover and start"
stop_wd_daemon
wd_switch_off
mark_log
wd_switch_on
wait_for "ours_running && listening" 15
wait_idle
expect "ours_running && listening" "the daemon runs and serves RPC on 9091"
expect "[ -f '$APP_HOME/migrated' ] && logged \"took over WD's settings\"" "WD's settings were taken over"
expect "[ -d '$CONFIG/torrents' ] && [ -d '$CONFIG/resume' ] && [ -f '$CONFIG/dht.dat' ]" "torrents, resume and DHT state copied"
expect "! grep -q '\"pidfile\"' '$CONFIG/settings.json'" "WD's pidfile setting dropped"
expect "[ \"\$(setting umask)\" = 2 ] && [ \"\$(setting rpc-port)\" = 9091 ]" "umask 2, rpc-port 9091 in settings.json"
expect "setting rpc-host-whitelist | grep -q \"\$(hostname | tr '[:upper:]' '[:lower:]'),\"" "host whitelist has the NAS's name"
expect "[ \"\$(setting peer-port)\" = 62460 ] && [ \"\$(setting rpc-username)\" = '\"transmission\"' ]" "peer port and login carried over"
expect json_well_formed "settings.json is still well-formed"
expect "[ \"\$(cat '$WD_CONFIG/settings.json' '$WD_CONFIG/dht.dat' | md5sum | cut -d' ' -f1)\" = '$wd_md5' ]" "WD's config is untouched"
expect "[ \"\$(cat /tmp/su-exec.last)\" = nobody:share ]" "started through su-exec as nobody:share"
expect "[ \"\$(stat -c %U:%G '$CONFIG/settings.json')\" = nobody:share ]" "config owned by nobody:share"
expect "our_cmdline | grep -q -- '--no-portmap' && our_cmdline | grep -q -- '--auth' && our_cmdline | grep -q -- '--rpc-bind-address 0.0.0.0'" "flags: no port mapping, auth, all interfaces"
expect "our_cmdline | grep -qF -- '--allowed $DEFAULT_ALLOWED '" "flags: localhost, private LANs and Tailscale's range allowed"
expect "[ -f '$APP_HOME/allowed-networks' ] && grep -qxF '172.1[6-9].*.*' '$APP_HOME/allowed-networks'" "allowed-networks created with the defaults"

section "4. WD's own scripts can't match this daemon"
expect "! ps | grep transmission-daemon | grep -q 'port 9091'" "WD's remove.sh pattern ('port 9091') finds nothing"
expect "! our_cmdline | grep -q 'addon_transmission.pid'" "no WD pid file in use"

section "5. Run App OFF"
wd_switch_off
expect "! ours_running && ! listening" "the daemon stopped"
expect "[ ! -f '$APP_HOME/should-run' ]" "should-run cleared"

section "6. Run App ON again: no second takeover"
sed -i 's/"ratio-limit": 2/"ratio-limit": 5/' "$CONFIG/settings.json"
mark_log
wd_switch_on
wait_for "ours_running && listening" 15
wait_idle
expect "[ \"\$(setting ratio-limit)\" = 5 ]" "your changed settings survive"
expect "! logged \"took over WD's settings\"" "no second takeover"

section "7. Your own allowed networks"
printf '# only my LAN\n192.168.1.*\n\n' > "$APP_HOME/allowed-networks"
wd_switch_off
wd_switch_on
wait_for "ours_running && listening" 15
wait_idle
expect "our_cmdline | grep -qF -- '--allowed 127.0.0.1,192.168.1.* '" "the edited list is used, with 127.0.0.1 added"
printf '192.168.1.* ; rm -rf /\n' > "$APP_HOME/allowed-networks"
mark_log
wd_switch_off
wd_switch_on
wait_for "ours_running && listening" 15
wait_idle
expect "logged 'using the defaults' && our_cmdline | grep -qF -- '--allowed $DEFAULT_ALLOWED '" "a file with anything but patterns falls back to the defaults"
rm -f "$APP_HOME/allowed-networks"

section "8. The Configure page's commands, as api.php runs them"
# shellcheck disable=SC2034 # read in expect's eval
status=$(ctl web-status)
expect "echo \"\$status\" | grep -qx daemon=running && echo \"\$status\" | grep -qx port=9091 && echo \"\$status\" | grep -qx 'username_json=\"transmission\"'" "web-status reports the daemon, its port and the user name"
expect "echo \"\$status\" | grep -qx password_set=1 && ! echo \"\$status\" | grep -q 0123456789abcdef" "and that a password is set, without its hash"
refused=$(printf 'username=bad name\nport=9092\nallowed=192.168.1.*\n' | ctl web-apply)
expect "echo \"\$refused\" | grep -q '^error=The user name' && [ ! -f '$APP_HOME/pending-settings' ]" "web-apply refuses a bad user name and keeps nothing"
nc -l -p 9099 > /dev/null 2>&1 &
blocker=$!
wait_for "netstat -ltn | grep -q ':9099 '" 5
# shellcheck disable=SC2034 # read in expect's eval
refused=$(printf 'username=alice\nport=9099\nallowed=192.168.1.*\n' | ctl web-apply)
expect "echo \"\$refused\" | grep -q 'already in use'" "and a port another program listens on"
kill "$blocker" 2> /dev/null
# Transmission's form: "{", 40 hex digits, an 8-character salt.
hash='{0123456789abcdef0123456789abcdef01234567Salt./AB'
mark_log
# shellcheck disable=SC2034 # read in expect's eval
accepted=$(printf 'username=alice\npassword_hash=%s\nport=9092\nallowed=192.168.1.*\nallowed=10.*.*.*\n' "$hash" | ctl web-apply)
expect "[ \"\$accepted\" = accepted=1 ]" "web-apply accepts good values"
wait_for "grep -q apply_state=done '$APP_HOME/apply-result'" 20
expect "grep -q apply_state=done '$APP_HOME/apply-result' && netstat -ltn | grep -q ':9092 '" "apply-settings restarted Transmission on port 9092"
expect "[ \"\$(setting rpc-username)\" = '\"alice\"' ] && [ \"\$(setting rpc-password)\" = '\"$hash\"' ] && [ \"\$(setting rpc-port)\" = 9092 ]" "login and port written to settings.json"
expect json_well_formed "settings.json is still well-formed"
expect "[ \"\$(stat -c %U:%G '$CONFIG/settings.json')\" = nobody:share ]" "and still owned by nobody:share"
expect "our_cmdline | grep -qF -- '--allowed 127.0.0.1,192.168.1.*,10.*.*.* '" "the new allowed addresses are in use"
expect "logged 'Configure page: user alice, port 9092, new password' && ! grep -qF '$hash' '$APP_HOME/log/app.log'" "the change is logged, the hash isn't"
wd_switch_off
printf 'username=transmission\nport=9091\nallowed=192.168.*.*\n' | ctl web-apply > /dev/null
wait_for "grep -q apply_state=done '$APP_HOME/apply-result'" 20
expect "grep -q 'Switch the app ON' '$APP_HOME/apply-result' && ! ours_running" "saved while OFF: written, but not started"
wd_switch_on
wait_for "ours_running && listening" 15
wait_idle
expect "ours_running && listening && [ \"\$(setting rpc-port)\" = 9091 ]" "the next switch-on starts it on port 9091"
rm -f "$APP_HOME/allowed-networks"

section "9. Upgrade while ON: Transmission comes back, Run App stays ON"
old_pid=$(our_pid)
mark_log
: > /tmp/curl.log
wd_upgrade_begin
expect "! ours_running" "stopped cleanly during the upgrade"
wd_upgrade_finish
wait_for "ours_running && listening" 15
wait_idle
expect "ours_running && [ \"\$(our_pid)\" != '$old_pid' ]" "started again by the new init.sh"
expect "[ ! -f '$APP_HOME/upgrading' ] && [ -f '$APP_HOME/should-run' ]" "upgrade flag cleared, should-run kept"
expect "enabled && logged 'Run App back ON, as it was before'" "WD's switch is put back ON after WD's installer stored OFF"
expect "[ \"\$(stat -c %a:%U '$APP/apkg.xml')\" = \"\$(stat -c %a:%U '$STAGED/apkg.xml')\" ]" "apkg.xml keeps its mode and owner"
expect "[ ! -s /tmp/curl.log ] && logged 'shows ON in the dashboard again'" "nothing to ask WD for: the dashboard's list follows apkg.xml"
expect "[ \"\$(dialog_status)\" = 1 ] && ! logged 'Updating dialog'" "WD's dialog got WD's result; the app left it alone"

# WD records "installed", but the dialog's copy stays at 100.
mark_log
wd_upgrade_begin
wd_upgrade_finish lost-copy
wait_for "ours_running && listening" 15
wait_idle
expect "[ \"\$(dialog_status)\" = 1 ] && logged 'passed WD.s result on'" "a dialog stuck on installing gets WD's result once the installer exits"
expect "[ \"\$(stat -c %a /var/www/xml/apkg_state.xml)\" = 666 ]" "the record keeps WD's mode"
expect "enabled" "Run App is back ON as well"

# The app never reports a result WD didn't record, nor touches another app's record.
write_install_record 100 transmission4
echo 100 > /tmp/upload_apkg_status
ctl restore-run-app
expect "[ \"\$(dialog_status)\" = 100 ]" "no result recorded by WD: the dialog is left as it is"
write_install_record 100 tailscale
echo 1 > /tmp/upload_apkg_status
ctl restore-run-app
expect "[ \"\$(dialog_status)\" = 100 ]" "another app's install record is left alone"

# The dashboard's list, as its page reads it, still says OFF: the app asks WD.
mkdir -p /var/www/xml
printf '<config>\n<item>\n<name>transmission4</name>\n<enable>0</enable>\n</item>\n</config>\n' \
    > /var/www/xml/apkg_all.xml
mark_log
wd_upgrade_begin
wd_upgrade_finish
wait_for "ours_running && listening" 15
wait_idle
expect "logged 'asking WD to show Run App ON' && grep -q '<enable>1</enable>' /var/www/xml/apkg_all.xml" "a list that still says OFF: it asks WD, and the list agrees"
rm -f /var/www/xml/apkg_all.xml

section "10. Reboot after an upgrade left Run App OFF"
# As if WD had dropped the request to switch it back ON.
set_enable 0
mark_log
wd_shutdown
wd_boot
wait_for "ours_running && listening" 15
wait_idle
expect "logged 'should-run is set'" "init.sh started it from the app's own flag"
expect "enabled" "and switched WD's Run App back ON"

section "11. Reboot with Run App ON"
wd_switch_on
wait_idle
wd_shutdown
wd_boot
wait_for "ours_running && listening" 15
wait_idle
expect "ours_running && listening" "running after boot"

section "12. WD's Transmission uninstalled while this app runs"
expect "[ \"\$(cat '$WD_CONFIG/settings.json' '$WD_CONFIG/dht.dat' | md5sum | cut -d' ' -f1)\" = '$wd_md5' ]" "WD's config untouched until its uninstall"
old_pid=$(our_pid)
wd_transmission_uninstall
expect "ours_running && listening && [ \"\$(our_pid)\" = '$old_pid' ]" "the daemon kept running, untouched"
expect "[ ! -d '$NAS_PROG/Transmission' ]" "WD's app folder is gone"
expect "[ \"\$(setting peer-port)\" = 62460 ] && [ -f '$CONFIG/dht.dat' ]" "the taken-over settings are kept"
expect "[ -f /var/www/apps/transmission4/index.html ]" "dashboard page still linked"
wd_shutdown
wd_boot
wait_for "ours_running && listening" 15
wait_idle
expect "ours_running && listening" "a reboot without WD's app starts it"

section "13. Uninstall while ON"
wd_switch_on
wait_idle
wd_uninstall
expect "[ ! -d '$APP' ] && [ ! -d /var/www/apps/transmission4 ]" "app folder and page removed"
expect "! ours_running" "the daemon is stopped"
expect "[ -f '$CONFIG/settings.json' ]" "config kept"

section "14. A NAS without WD's app: fresh settings"
rm -rf "$APP_HOME" "$NAS_PROG/Transmission"
wd_install
mark_log
wd_switch_on
wait_for "ours_running && listening" 15
wait_idle
expect "[ -s '$APP_HOME/initial-password' ] && [ \"\$(stat -c %a '$APP_HOME/initial-password')\" = 600 ]" "random password saved, readable by root only"
expect "grep -q \"\$(cat '$APP_HOME/initial-password')\" '$CONFIG/settings.json'" "and set as the RPC password"
expect "[ \"\$(stat -c %a:%U '$CONFIG/settings.json')\" = 600:nobody ]" "which only the daemon's user can read until Transmission hashes it"
expect "ours_running && listening" "the daemon runs"
wd_uninstall

section "Downloads"
expect "[ \"\$(md5sum < '$DOWNLOADS/existing.iso')\" = '$downloads_md5' ]" "the existing download is unchanged"

if [ "$failures" -ne 0 ]; then
    section "app.log (last 40 lines)"
    tail -n 40 "$APP_HOME/log/app.log"
fi
section "$failures failure(s)"
[ "$failures" -eq 0 ]
