#!/usr/bin/env bats
# `wp db` against MYSQL — which is what the deployed sites actually run.
#
# 40-integration asserts these same subcommands against mariadb:11 and passes.
# This file exists because that is not the same question, and the gap between
# them hid a defect for as long as it existed: the client in this image is
# MariaDB's, MariaDB 11's client verifies the server certificate by default, and
# MySQL auto-generates a self-signed CA at initialization that nothing trusts.
# So every `wp db` subcommand failed in production while the suite was green.
# `mysql-tls-wrapper.sh` is the fix; this file is what holds it in place.
#
# WHY mysql_native_password. All four WordPress users on the live host use it
# (measured 2026-08-19), so this matches production. It is NOT a way around the
# certificate problem — it avoids a SECOND incompatibility this image has and
# does not fix: Alpine's mariadb-client ships an EMPTY /usr/lib/mariadb/plugin,
# so a MySQL 8 DEFAULT user (caching_sha2_password) fails with "Plugin
# caching_sha2_password could not be loaded" regardless of TLS. That limitation
# is recorded in AGENTS.md rather than papered over here.
#
# SKIP_INTEGRATION=1 leaves it out, same as 40.

MY_NET="wp-image-test-my-net"
MY_DB="wp-image-test-my-db"
MY_VOL="wp-image-test-my-vol"

# Same shape as 40-integration's it_run: extra docker flags would be handed to
# the entrypoint if passed through "$@", which is the CONTAINER command.
my_run() {
    docker run --rm --network "$MY_NET" -v "$MY_VOL:/usr/share/wordpress" \
        -e WP_DB_HOST=mydb \
        -e WP_DB_NAME=wordpress \
        -e WP_DB_USER=wordpress \
        -e WP_DB_PASS=wordpress \
        -e WP_ABSPATH=/usr/share/wordpress \
        -e HOME=/tmp \
        "$IMAGE" "$@"
}

my_cleanup() {
    docker rm -f "$MY_DB" >/dev/null 2>&1 || true
    docker volume rm -f "$MY_VOL" >/dev/null 2>&1 || true
    docker network rm "$MY_NET" >/dev/null 2>&1 || true
}

setup_file() {
    load test_helper
    if [ -n "${SKIP_INTEGRATION:-}" ]; then return 0; fi

    # One database, one volume, tests that build on each other — so they must run
    # in order even under --jobs, same as 40-integration.
    export BATS_NO_PARALLELIZE_WITHIN_FILE=true

    my_cleanup
    docker network create "$MY_NET" >/dev/null
    docker volume create "$MY_VOL" >/dev/null
    docker run -d --name "$MY_DB" --network "$MY_NET" --network-alias mydb \
        -e MYSQL_ROOT_PASSWORD=root \
        -e MYSQL_DATABASE=wordpress \
        -e MYSQL_USER=wordpress \
        -e MYSQL_PASSWORD=wordpress \
        "${MYSQL_IMAGE:-mysql:8.0}" \
        --default-authentication-plugin=mysql_native_password >/dev/null

    # READINESS, AND NOT `mysqladmin ping`. The official entrypoint initializes
    # the data directory against a TEMPORARY server started with
    # --skip-networking, on the same socket. `mysqladmin ping` therefore answers
    # "alive" from that temporary server — measured 3s before the real one
    # accepts a TCP connection, and longer on a runner that has just written a
    # fresh image to disk. Everything below reaches the database over the docker
    # network, so that window broke setup_file in CI.
    #
    # Probe what the tests actually use: TCP, the wordpress user, the wordpress
    # schema. That is false until networking is on AND the entrypoint has
    # created MYSQL_USER/MYSQL_DATABASE.
    local i=0
    while [ "$i" -lt 90 ]; do
        docker exec "$MY_DB" mysql -h127.0.0.1 -uwordpress -pwordpress \
            -e 'SELECT 1' wordpress >/dev/null 2>&1 && break
        i=$((i + 1))
        sleep 1
    done
    if [ "$i" -ge 90 ]; then
        echo "mysql did not come up; last lines of its log:" >&2
        docker logs --tail 20 "$MY_DB" >&2 2>&1 || true
        return 1
    fi

    # wp db needs a schema to talk about, and these subcommands are the point of
    # the file — so install once here rather than spending a test on it.
    #
    # KEEP THE OUTPUT. bats fails setup_file on a non-zero status and then skips
    # every test in the file, so `>/dev/null 2>&1` here bought a CI run that
    # said only "Executed 11 instead of expected 16 tests" and never why.
    local out
    if ! out=$(my_run wp --allow-root core version 2>&1); then
        printf 'setup_file: wp core version failed\n%s\n' "$out" >&2
        return 1
    fi
    if ! out=$(my_run wp --allow-root core install --url=http://localhost --title=CI \
        --admin_user=ci --admin_password=ci --admin_email=ci@example.test \
        --skip-email 2>&1); then
        printf 'setup_file: wp core install failed\n%s\n' "$out" >&2
        return 1
    fi
}

teardown_file() {
    if [ -n "${SKIP_INTEGRATION:-}" ]; then return 0; fi
    my_cleanup
}

setup() {
    load test_helper
    if [ -n "${SKIP_INTEGRATION:-}" ]; then skip "SKIP_INTEGRATION is set"; fi
}

# The precondition, asserted rather than assumed. If a future MySQL stops
# auto-generating certificates, every test below would pass while testing
# nothing — this is what makes a green run mean something.
@test "the MySQL server presents auto-generated (self-signed) certificates" {
    run docker exec "$MY_DB" mysql -uroot -proot -N \
        -e "SHOW VARIABLES LIKE 'auto_generate_certs'"
    assert_success
    assert_output --partial ON
}

# And that the setup actually produced a site, so a later failure is about the
# client and not about a half-installed WordPress.
@test "WordPress is installed on the MySQL database" {
    run my_run wp --allow-root core is-installed
    assert_success
}

# The three that shell OUT to the client binaries. Against MariaDB these pass
# without the wrapper; against MySQL none of them did.
@test "wp db query reaches a MySQL server" {
    run my_run wp --allow-root db query \
        'SELECT option_value FROM wp_options WHERE option_name = "blogname"'
    assert_success
    assert_output --partial CI
}

@test "wp db export produces a dump from MySQL" {
    run my_run wp --allow-root db export -
    assert_success
    assert_output --partial "CREATE TABLE"
    assert_output --partial "wp_options"
}

@test "wp db check runs mysqlcheck against MySQL" {
    run my_run wp --allow-root db check
    assert_success
    assert_output --partial "wordpress.wp_options"
}

# THE ASSERTION WITH TEETH. `--skip-ssl` also makes every test above pass, by
# removing the encryption instead of the verification — this is the one that
# tells the two apart. If someone "simplifies" the wrapper to --skip-ssl, or
# drops it and disables TLS elsewhere, this goes red and the others stay green.
@test "the connection is still encrypted, not merely unverified" {
    run my_run wp --allow-root db query \
        'SHOW SESSION STATUS WHERE Variable_name = "Ssl_cipher"'
    assert_success
    refute_output --regexp 'Ssl_cipher[[:space:]]*$'
    assert_output --partial "TLS_"
}
