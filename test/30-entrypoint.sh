#!/bin/sh
# entrypoint.sh behaviour. Still no database — everything here is observable
# before WordPress is involved.

suite "entrypoint: required configuration"

out=$(docker run --rm "$IMAGE" php -v 2>&1 || true)
assert_contains "$out" "missing required WP_DB_PASS" "refuses to start without WP_DB_PASS"

if docker run --rm "$IMAGE" php -v >/dev/null 2>&1; then code=0; else code=$?; fi
assert_eq "1" "$code" "exits 1 without WP_DB_PASS"

suite "entrypoint: www-data uid remap"

# The remap is what lets php write a bind-mounted tree without a chown. It is
# also the subject of the most recent fix before this suite existed
# (usermod -o, plus skipping the call when it would be a no-op) and had no test.

uid=$(ep_probe 'id -u www-data' -e WWW_UID=1234)
assert_eq "1234" "$uid" "WWW_UID=1234 remaps www-data"

gid=$(ep_probe 'id -g www-data' -e WWW_UID=1234 -e WWW_GID=1234)
assert_eq "1234" "$gid" "WWW_GID=1234 remaps the group"

# WWW_UID=0 is what ROOTLESS docker needs: there the only container uid mapping
# back to the host user who owns the mount is 0, and root already holds it. A
# plain `usermod -u 0` exits "UID '0' already exists" and, under set -e, kills
# the container before php starts. -o permits the duplicate.
uid=$(ep_probe 'id -u www-data' -e WWW_UID=0)
assert_eq "0" "$uid" "WWW_UID=0 works (rootless docker needs it)"

# Production passes 82, which www-data already holds — the guard must make that
# a no-op rather than an error.
out=$(docker run --rm -e WP_DB_PASS=probe -e WWW_UID=82 "$IMAGE" \
    php -r 'echo "__STARTED__\n";' 2>&1 || true)
assert_contains "$out" "__STARTED__" "WWW_UID=82 is a no-op, not a failure"

# Default: no remap requested at all.
uid=$(ep_probe 'id -u www-data')
assert_eq "82" "$uid" "www-data stays 82 when WWW_UID is unset"

suite "entrypoint: salts it does not own"

# contentreich-wordpress ships a wp-config.php with NO salt defines at all, so
# WordPress falls back to the salts in wp_options — stable, and the tracked file
# never churns. That only works while this entrypoint leaves such a file alone,
# which makes it a cross-repo contract rather than an implementation detail.
it_tmp=$(mktemp -d)
mkdir -p "$it_tmp/wp-includes"
printf '<?php // present so the entrypoint does not download WordPress\n' >"$it_tmp/index.php"
printf '<?php $wp_version = "7.0";\n' >"$it_tmp/wp-includes/version.php"
cat >"$it_tmp/wp-config.php" <<'NOSALTS'
<?php
define('DB_NAME', getenv('WP_DB_NAME'));
require_once('wp-settings.php');
NOSALTS
before=$(md5sum "$it_tmp/wp-config.php" | cut -d' ' -f1)
docker run --rm -e WP_DB_PASS=probe -v "$it_tmp:/usr/share/wordpress" "$IMAGE" true >/dev/null 2>&1 || true
after=$(md5sum "$it_tmp/wp-config.php" | cut -d' ' -f1)
assert_eq "$before" "$after" "a wp-config.php with no salt defines is left untouched"
rm -rf "$it_tmp"

suite "entrypoint: ssmtp"

# mailhub is hardcoded to the host `smtp`, which the consuming compose file
# supplies via extra_hosts. Consumers route mail by overriding this file, so its
# shape is a contract, not an implementation detail.
conf=$(ep_probe 'cat /etc/ssmtp/ssmtp.conf | tr "\n" " "' -e SMTP_DOMAIN=example.test)
assert_contains "$conf" "mailhub=smtp" "ssmtp points at the smtp host"
assert_contains "$conf" "rewriteDomain=example.test" "SMTP_DOMAIN sets rewriteDomain"
