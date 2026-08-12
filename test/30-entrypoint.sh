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

suite "entrypoint: ssmtp"

# mailhub is hardcoded to the host `smtp`, which the consuming compose file
# supplies via extra_hosts. Consumers route mail by overriding this file, so its
# shape is a contract, not an implementation detail.
conf=$(ep_probe 'cat /etc/ssmtp/ssmtp.conf | tr "\n" " "' -e SMTP_DOMAIN=example.test)
assert_contains "$conf" "mailhub=smtp" "ssmtp points at the smtp host"
assert_contains "$conf" "rewriteDomain=example.test" "SMTP_DOMAIN sets rewriteDomain"
