#!/usr/bin/env bats
# End-to-end: an empty volume and a database in, a working WordPress out.
#
# The only suite that needs a network and a database, and the one that reaches
# the paths nothing else does — the WordPress download, the wp-config template
# copy, and the salt rewrite. AGENTS.md's "verification means building the image
# and running it against a MySQL container" is exactly this, written down.
#
# SKIP_INTEGRATION=1 leaves it out (offline, or iterating on the fast suites).

IT_NET="wp-image-test-net"
IT_DB="wp-image-test-db"
IT_VOL="wp-image-test-vol"

# Extra docker flags go in IT_ENV, because "$@" here is the CONTAINER command —
# passing -e through it would hand the flag to the entrypoint instead.
it_run() {
    # shellcheck disable=SC2086 -- IT_ENV is deliberately word-split
    docker run --rm --network "$IT_NET" -v "$IT_VOL:/usr/share/wordpress" \
        $IT_ENV \
        -e WP_DB_HOST=itdb \
        -e WP_DB_NAME=wordpress \
        -e WP_DB_USER=wordpress \
        -e WP_DB_PASS=wordpress \
        -e WP_ABSPATH=/usr/share/wordpress \
        -e HOME=/tmp \
        "$IMAGE" "$@"
}
# stderr is deliberately NOT merged here. The entrypoint's `set -x` trace goes
# to stderr and includes the command being exec'd — so with 2>&1 a probe's own
# printf format ("__P__%s__E__") appears in the trace BEFORE the real output,
# and marker extraction returns the literal "%s".
#
# That is worse than a plain failure: "salts are stable across a restart"
# compared two probes that had both degraded to "%s" and passed for the wrong
# reason. bats' own `run` still captures stderr, so tests that assert on
# entrypoint messages keep working.

# Same marker discipline as the other suites, and for the same reason: the
# entrypoint's `set -x` trace shares stdout with the result, so a bare
# `assert_output --partial 8` matches an 8 in a trace line rather than the value
# under test. That is precisely how the first version of the salt-count
# assertion failed.
# NOTE: keep probe commands free of DOUBLE quotes. The command is interpolated
# into a double-quoted `sh -c` string, so a nested `"` closes it early and the
# probe silently returns the format string instead of a value.
it_probe() {
    it_run sh -c "printf '__P__%s__E__\n' \"\$($1)\"" |
        sed -n 's/.*__P__\(.*\)__E__.*/\1/p' | head -1
}

it_cleanup() {
    docker rm -f "$IT_DB" >/dev/null 2>&1 || true
    docker volume rm -f "$IT_VOL" >/dev/null 2>&1 || true
    docker network rm "$IT_NET" >/dev/null 2>&1 || true
}

setup_file() {
    load test_helper
    # `[ ... ] && return` would FAIL setup_file when the guard is false:
    # bats runs these under set -e, so the non-zero test is the last status.
    if [ -n "${SKIP_INTEGRATION:-}" ]; then return 0; fi

    # These tests share one volume and one database and build on each other, so
    # they must run IN ORDER even under --jobs. bats parallelises within a file
    # by default; this turns that off for this file only.
    export BATS_NO_PARALLELIZE_WITHIN_FILE=true

    it_cleanup
    docker network create "$IT_NET" >/dev/null
    docker volume create "$IT_VOL" >/dev/null
    docker run -d --name "$IT_DB" --network "$IT_NET" --network-alias itdb \
        -e MARIADB_ROOT_PASSWORD=root \
        -e MARIADB_DATABASE=wordpress \
        -e MARIADB_USER=wordpress \
        -e MARIADB_PASSWORD=wordpress \
        "${DB_IMAGE:-mariadb:11}" >/dev/null

    local i=0
    while [ "$i" -lt 60 ]; do
        docker exec "$IT_DB" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && return 0
        i=$((i + 1))
        sleep 1
    done
    echo "database did not come up" >&2
    return 1
}

teardown_file() {
    if [ -n "${SKIP_INTEGRATION:-}" ]; then return 0; fi
    it_cleanup
}

setup() {
    load test_helper
    if [ -n "${SKIP_INTEGRATION:-}" ]; then skip "SKIP_INTEGRATION is set"; fi
}

@test "first boot on an empty volume downloads WordPress" {
    run it_run wp --allow-root core version
    assert_output --partial "Initializing vanilla Wordpress"
}

@test "core version reads back" {
    run it_run wp --allow-root core version
    assert_regex "$output" '[0-9]+\.[0-9]+'
}

@test "wp-config.php was created from the template" {
    assert_equal "$(it_probe 'test -f /usr/share/wordpress/wp-config.php && echo yes || echo no')" yes
}

# Leaving the placeholders means every site installed from this image signs its
# auth cookies and nonces with a publicly known constant.
@test "salt placeholders were rewritten" {
    assert_equal "$(it_probe 'grep -c "put your unique phrase here" /usr/share/wordpress/wp-config.php || true')" 0
}

# The assertion with teeth. The loop runs on every container start, and a salt
# is the key every auth cookie is signed with — rewriting a live one logs every
# user out, which is what the deployed sites actually suffered. Read the same
# key twice, across two separate boots.
@test "salts are stable across a restart" {
    local a b
    a=$(it_probe 'grep -m1 AUTH_KEY /usr/share/wordpress/wp-config.php')
    b=$(it_probe 'grep -m1 AUTH_KEY /usr/share/wordpress/wp-config.php')
    # Prove we actually READ something first. Without this, two empty or
    # degraded probes compare equal and the test passes having checked nothing —
    # which is exactly what happened when a stderr trace poisoned the marker.
    assert_regex "$a" "define\('AUTH_KEY'"
    assert_equal "$a" "$b"
    refute_regex "$a" 'put your unique phrase here'
}

# An explicitly pinned value must win on every boot — the whole point of the
# WORDPRESS_<KEY> contract, which was silently broken too.
@test "WORDPRESS_AUTH_KEY is applied, and persists once written" {
    IT_ENV="-e WORDPRESS_AUTH_KEY=pinned-by-the-test"
    local pinned
    pinned=$(it_probe 'grep -m1 AUTH_KEY /usr/share/wordpress/wp-config.php')
    IT_ENV=""
    assert_regex "$pinned" 'pinned-by-the-test'

    # ...and an unpinned boot must not disturb it.
    assert_regex "$(it_probe 'grep -m1 AUTH_KEY /usr/share/wordpress/wp-config.php')" 'pinned-by-the-test'
}

@test "wp core install succeeds and reports installed" {
    run it_run wp --allow-root core install \
        --url=http://localhost --title=CI \
        --admin_user=ci --admin_password=ci --admin_email=ci@example.test \
        --skip-email
    assert_output --partial Success

    run it_run wp --allow-root core is-installed
    assert_success
}
