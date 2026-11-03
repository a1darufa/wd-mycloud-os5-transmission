# shellcheck shell=sh
# web-sim-transmission4.sh — Transmission 4's checks for web-sim.sh, which
# sources this file once the app is installed and ON, and the web server
# runs. The helpers and $code and $body (the last reply) come from there.
# shellcheck disable=SC2154

TR_CONFIG=$TR_HOME/config

setting() { sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\(.*\)/\1/p" "$TR_CONFIG/settings.json" | sed 's/,$//'; }
tr_cmdline() {
    for proc in /proc/[0-9]*; do
        case "$(tr '\0' ' ' 2> /dev/null < "$proc/cmdline")" in
            *"transmission-daemon"*"--config-dir $TR_CONFIG "*) tr '\0' ' ' < "$proc/cmdline" ;;
        esac
    done
}

# Wait until Transmission's settings change is applied; print its state.
await_apply() {
    wait_for "api transmission4 '{\"action\":\"status\"}'; [ \"\$(field status.apply.state)\" != applying ]" 30
    field status.apply.state
}

section "Transmission: status"
api transmission4 '{"action":"status"}'
expect "[ '$code' = 200 ] && [ \"\$(field ok)\" = true ]" "status answers"
expect "[ \"\$(field status.daemon)\" = running ] && [ \"\$(field status.port)\" = 9091 ]" "the daemon runs on 9091"
expect "[ \"\$(field status.username)\" = transmission ] && [ \"\$(field status.password_set)\" = true ]" "with the login, but no password"
expect "[ \"\$(field status.initial_password)\" = true ]" "and a generated initial password (no WD app here)"
expect "field status.allowed | grep -qxF '192.168.*.*'" "the default allowed addresses"
expect "! echo \"\$body\" | grep -qF \"\$(cat '$TR_HOME/initial-password')\"" "the password isn't in the reply"

section "Transmission: bad values are refused, and nothing changes"
settings_md5=$(md5sum < "$TR_CONFIG/settings.json")
api transmission4 '{"action":"save","username":"bad name","password":"short","port":"80","allowed":["192.168.1.0/24"]}'
expect "[ '$code' = 422 ]" "refused"
expect "[ \"\$(field fields.username)\" != null ] && [ \"\$(field fields.password)\" != null ] && [ \"\$(field fields.port)\" != null ] && [ \"\$(field fields.allowed)\" != null ]" "with a message for each field"
expect "[ \"\$(md5sum < '$TR_CONFIG/settings.json')\" = '$settings_md5' ] && [ ! -e '$TR_HOME/pending-settings' ]" "settings untouched"
api transmission4 '{"action":"save","username":"alice","password":"","port":"8080","allowed":["192.168.1.*"]}'
expect "[ '$code' = 409 ] && field error | grep -q 'already in use'" "a port another program listens on is refused"

section "Transmission: saving restarts it with the new settings"
password='correct horse battery'
api transmission4 "{\"action\":\"save\",\"username\":\"alice\",\"password\":\"$password\",\"port\":\"9092\",\"allowed\":[\"192.168.1.*\",\"10.*.*.*\"]}"
expect "[ '$code' = 200 ]" "accepted"
expect "[ \"\$(await_apply)\" = done ]" "applied"
api transmission4 '{"action":"status"}'
expect "field status.apply.message | grep -q 'running on port 9092'" "with Transmission running on port 9092"
expect "[ \"\$(setting rpc-username)\" = '\"alice\"' ] && [ \"\$(setting rpc-port)\" = 9092 ]" "user name and port written"
hash=$(setting rpc-password | tr -d '"')
expect "php -r 'echo hash_equals(\"{\" . sha1(\$argv[2] . substr(\$argv[1], 41)) . substr(\$argv[1], 41), \$argv[1]) ? \"yes\" : \"no\";' '$hash' '$password' | grep -q yes" "the password is stored as Transmission's salted hash"
expect "! grep -rqF '$password' /mnt /var/www /var/run /tmp" "the password itself isn't stored anywhere"
expect "[ ! -e '$TR_HOME/initial-password' ]" "the generated initial password is deleted"
expect "listening 9092 && ! listening 9091" "Transmission listens on 9092 now"
expect "tr_cmdline | grep -qF -- '--allowed 127.0.0.1,192.168.1.*,10.*.*.* '" "with the new allowed addresses"
expect "[ \"\$(stat -c %U:%G '$TR_CONFIG/settings.json')\" = nobody:share ]" "settings.json still belongs to nobody:share"
api transmission4 '{"action":"status"}'
expect "[ \"\$(field status.port)\" = 9092 ] && [ \"\$(field status.username)\" = alice ] && [ \"\$(field status.initial_password)\" = false ]" "status shows the change"

section "Transmission: saving without a password keeps it"
api transmission4 '{"action":"save","username":"alice","password":"","port":"9091","allowed":["192.168.*.*"]}'
expect "[ '$code' = 200 ] && [ \"\$(await_apply)\" = done ]" "applied"
expect "[ \"\$(setting rpc-password | tr -d '\"')\" = '$hash' ] && listening 9091" "same password hash, back on 9091"
