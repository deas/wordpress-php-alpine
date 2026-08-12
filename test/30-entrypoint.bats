#!/usr/bin/env bats
# entrypoint.sh behaviour. No database — everything here is observable before
# WordPress is involved.
#
# Like the xdebug matrix, most of this cannot be batched: each case needs a
# container created with different environment.

setup() { load test_helper; }

@test "refuses to start without WP_DB_PASS, and exits 1" {
    run docker run --rm "$IMAGE" php -v
    assert_failure 1
    assert_output --partial "missing required WP_DB_PASS"
}

# The remap is what lets php write a bind-mounted tree without a chown.
@test "WWW_UID=1234 remaps www-data" {
    assert_equal "$(ep_probe 'id -u www-data' -e WWW_UID=1234)" 1234
}

@test "WWW_GID=1234 remaps the group" {
    assert_equal "$(ep_probe 'id -g www-data' -e WWW_UID=1234 -e WWW_GID=1234)" 1234
}

# WWW_UID=0 is what ROOTLESS docker needs: there the only container uid mapping
# back to the host user who owns the mount is 0, and root already holds it. A
# plain `usermod -u 0` exits "UID '0' already exists" and, under set -e, kills
# the container before php starts. -o permits the duplicate.
@test "WWW_UID=0 works (rootless docker needs it)" {
    assert_equal "$(ep_probe 'id -u www-data' -e WWW_UID=0)" 0
}

# Production passes 82, which www-data already holds — the guard must make that
# a no-op rather than an error.
@test "WWW_UID=82 is a no-op, not a failure" {
    run docker run --rm -e WP_DB_PASS=probe -e WWW_UID=82 "$IMAGE" php -r 'echo "STARTED";'
    assert_success
    assert_output --partial STARTED
}

@test "www-data stays 82 when WWW_UID is unset" {
    assert_equal "$(ep_probe 'id -u www-data')" 82
}

# contentreich-wordpress ships a wp-config.php with NO salt defines at all, so
# WordPress falls back to the salts in wp_options — stable, and the tracked file
# never churns. That only works while this entrypoint leaves such a file alone,
# which makes it a cross-repo contract rather than an implementation detail.
@test "a wp-config.php with no salt defines is left untouched" {
    local tmp
    tmp="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$tmp/wp-includes"
    printf '<?php // present so the entrypoint does not download WordPress\n' >"$tmp/index.php"
    printf '<?php $wp_version = "7.0";\n' >"$tmp/wp-includes/version.php"
    cat >"$tmp/wp-config.php" <<'NOSALTS'
<?php
define('DB_NAME', getenv('WP_DB_NAME'));
require_once('wp-settings.php');
NOSALTS

    local before after
    before=$(md5sum "$tmp/wp-config.php" | cut -d' ' -f1)
    docker run --rm -e WP_DB_PASS=probe -v "$tmp:/usr/share/wordpress" "$IMAGE" true >/dev/null 2>&1 || true
    after=$(md5sum "$tmp/wp-config.php" | cut -d' ' -f1)
    assert_equal "$before" "$after"
}

# mailhub is hardcoded to the host `smtp`, which the consuming compose file
# supplies via extra_hosts. Consumers route mail by overriding this file, so its
# shape is a contract, not an implementation detail.
@test "ssmtp.conf is generated with SMTP_DOMAIN as the rewrite domain" {
    local conf
    conf=$(ep_probe 'tr "\n" " " </etc/ssmtp/ssmtp.conf' -e SMTP_DOMAIN=example.test)
    assert_regex "$conf" 'mailhub=smtp'
    assert_regex "$conf" 'rewriteDomain=example.test'
}
