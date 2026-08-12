#!/bin/sh
# The Xdebug toggle.
#
# This suite exists because the failure it guards against is silent and
# expensive in BOTH directions: a debugger loaded on every production container,
# or a documented switch that quietly does nothing. Neither shows up as an
# error anywhere.

suite "xdebug: not loaded unless asked"

staged=$(sh_probe 'test -f /usr/local/etc/php/xdebug.ini.available && echo yes || echo no')
assert_eq "yes" "$staged" "the ini is staged outside conf.d"

loaded() {
    php_probe 'extension_loaded("xdebug") ? "yes" : "no"' "$@"
}

assert_eq "no" "$(loaded)" "not loaded with no environment at all"

# The whole reason for an allow-list rather than a non-empty test: the consuming
# docker-compose.yml passes PHP_XDEBUG_ENABLED=0 as its DEFAULT. A `[ -n ... ]`
# here would load the debugger on every production container. Same family as the
# (bool) getenv() trap in wp-config-template.php, where '0' is true.
for falsy in 0 '' false FALSE no off; do
    assert_eq "no" "$(loaded -e "PHP_XDEBUG_ENABLED=$falsy")" \
        "PHP_XDEBUG_ENABLED=[$falsy] does NOT load xdebug"
done

suite "xdebug: loaded when asked"

for truthy in 1 true TRUE yes YES on ON; do
    assert_eq "yes" "$(loaded -e "PHP_XDEBUG_ENABLED=$truthy")" \
        "PHP_XDEBUG_ENABLED=[$truthy] loads xdebug"
done

suite "xdebug: configuration"

# Loaded must not mean slow. `trigger` keeps it dormant until a request actually
# carries XDEBUG_TRIGGER.
start=$(php_probe 'ini_get("xdebug.start_with_request")' -e PHP_XDEBUG_ENABLED=1)
assert_eq "trigger" "$start" "start_with_request defaults to trigger"

# 9003 is the Xdebug 3 default and what IDEs expect out of the box.
port=$(php_probe 'ini_get("xdebug.client_port")' -e PHP_XDEBUG_ENABLED=1)
assert_eq "9003" "$port" "client_port defaults to 9003"

# The consuming compose files already carry PHP_XDEBUG_REMOTE_PORT, so it has to
# keep meaning something.
port=$(php_probe 'ini_get("xdebug.client_port")' \
    -e PHP_XDEBUG_ENABLED=1 -e PHP_XDEBUG_REMOTE_PORT=9100)
assert_eq "9100" "$port" "PHP_XDEBUG_REMOTE_PORT overrides the port"

# Mode and host are native Xdebug 3 environment config — we deliberately invent
# no variable for them. Assert that, so nobody adds one back.
host=$(php_probe 'ini_get("xdebug.client_host")' \
    -e PHP_XDEBUG_ENABLED=1 -e XDEBUG_CONFIG="client_host=example.test")
assert_eq "example.test" "$host" "XDEBUG_CONFIG sets the client host natively"

# XDEBUG_MODE is read by Xdebug itself, not from php.ini, so ini_get() is the
# wrong probe — check the behaviour instead. In develop mode Xdebug decorates
# notices with a "Call Stack" block; with the mode off it must not.
frames() {
    docker run --rm -e WP_DB_PASS=probe -e PHP_XDEBUG_ENABLED=1 "$@" "$IMAGE" \
        php -d error_reporting=E_ALL -d display_errors=1 \
        -r 'trigger_error("probe", E_USER_DEPRECATED);' 2>&1 | grep -c 'Call Stack' || true
}
assert_eq "1" "$(frames -e XDEBUG_MODE=develop)" "XDEBUG_MODE=develop decorates errors"
assert_eq "0" "$(frames -e XDEBUG_MODE=off)" "XDEBUG_MODE=off silences the decoration"
