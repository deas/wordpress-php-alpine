#!/usr/bin/env bats
# The Xdebug toggle.
#
# This suite exists because the failure it guards against is silent and
# expensive in BOTH directions: a debugger loaded on every production container,
# or a documented switch that quietly does nothing. Neither shows as an error.
#
# It is also the slowest file, and irreducibly so: every case needs a container
# created with different environment, which is exactly what batching cannot help
# and what `bats --jobs` can. One test per case is verbose on purpose — the
# truth table's value is in seeing which specific value broke.

setup() { load test_helper; }

loaded() { php_probe 'extension_loaded("xdebug") ? "yes" : "no"' "$@"; }

@test "the ini is staged outside conf.d" {
    run sh_probe 'test -f /usr/local/etc/php/xdebug.ini.available && echo yes || echo no'
    assert_output yes
}

@test "not loaded with no environment at all" {
    assert_equal "$(loaded)" no
}

# The reason for an allow-list rather than a non-empty test: the consuming
# docker-compose.yml passes PHP_XDEBUG_ENABLED=0 as its DEFAULT. A `[ -n ... ]`
# would load the debugger on every production container. Same family as the
# (bool) getenv() trap in wp-config-template.php, where '0' is true.
@test "PHP_XDEBUG_ENABLED=0 does NOT load xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=0)" no
}
@test "PHP_XDEBUG_ENABLED= (empty) does NOT load xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=)" no
}
@test "PHP_XDEBUG_ENABLED=false does NOT load xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=false)" no
}
@test "PHP_XDEBUG_ENABLED=FALSE does NOT load xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=FALSE)" no
}
@test "PHP_XDEBUG_ENABLED=no does NOT load xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=no)" no
}
@test "PHP_XDEBUG_ENABLED=off does NOT load xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=off)" no
}

@test "PHP_XDEBUG_ENABLED=1 loads xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=1)" yes
}
@test "PHP_XDEBUG_ENABLED=true loads xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=true)" yes
}
@test "PHP_XDEBUG_ENABLED=TRUE loads xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=TRUE)" yes
}
@test "PHP_XDEBUG_ENABLED=yes loads xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=yes)" yes
}
@test "PHP_XDEBUG_ENABLED=YES loads xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=YES)" yes
}
@test "PHP_XDEBUG_ENABLED=on loads xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=on)" yes
}
@test "PHP_XDEBUG_ENABLED=ON loads xdebug" {
    assert_equal "$(loaded -e PHP_XDEBUG_ENABLED=ON)" yes
}

# Loaded must not mean slow. `trigger` keeps it dormant until a request actually
# carries XDEBUG_TRIGGER. 9003 is the Xdebug 3 default and what IDEs expect.
@test "start_with_request defaults to trigger, client_port to 9003" {
    run php_probe 'ini_get("xdebug.start_with_request") . " " . ini_get("xdebug.client_port")' \
        -e PHP_XDEBUG_ENABLED=1
    assert_output "trigger 9003"
}

# The consuming compose files already carry PHP_XDEBUG_REMOTE_PORT, so it has to
# keep meaning something.
@test "PHP_XDEBUG_REMOTE_PORT overrides the port" {
    run php_probe 'ini_get("xdebug.client_port")' \
        -e PHP_XDEBUG_ENABLED=1 -e PHP_XDEBUG_REMOTE_PORT=9100
    assert_output 9100
}

# Mode and host are native Xdebug 3 environment config — we deliberately invent
# no variable for them. Assert that, so nobody adds one back.
@test "XDEBUG_CONFIG sets the client host natively" {
    run php_probe 'ini_get("xdebug.client_host")' \
        -e PHP_XDEBUG_ENABLED=1 -e XDEBUG_CONFIG="client_host=example.test"
    assert_output example.test
}

# XDEBUG_MODE is read by Xdebug itself rather than from php.ini, so ini_get() is
# the WRONG probe — it reports the ini value and would say the override failed.
# Check the behaviour instead: in develop mode Xdebug decorates notices with a
# "Call Stack" block; with the mode off it must not.
frames() {
    docker run --rm -e WP_DB_PASS=probe -e PHP_XDEBUG_ENABLED=1 "$@" "$IMAGE" \
        php -d error_reporting=E_ALL -d display_errors=1 \
        -r 'trigger_error("probe", E_USER_DEPRECATED);' 2>&1 | grep -c 'Call Stack' || true
}

@test "XDEBUG_MODE=develop decorates errors" {
    assert_equal "$(frames -e XDEBUG_MODE=develop)" 1
}

@test "XDEBUG_MODE=off silences the decoration" {
    assert_equal "$(frames -e XDEBUG_MODE=off)" 0
}
