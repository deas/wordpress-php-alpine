#!/bin/sh
# End-to-end: an empty volume and a database in, a working WordPress out.
#
# This is the only suite that needs a network and a database, and it is the one
# that exercises the paths nothing else reaches — the WordPress download, the
# wp-config template copy, and the salt rewrite. AGENTS.md's "verification means
# building the image and running it against a MySQL container" is exactly this,
# written down.
#
# Set SKIP_INTEGRATION=1 to leave it out (offline, or iterating on the fast
# suites).

suite "integration: install WordPress against MariaDB"

if [ -n "${SKIP_INTEGRATION:-}" ]; then
    printf '  \033[33mskip\033[0m SKIP_INTEGRATION is set\n'
    return 0 2>/dev/null || exit 0
fi

IT_NET="wp-image-test-net"
IT_DB="wp-image-test-db"
IT_VOL="wp-image-test-vol"

it_cleanup() {
    docker rm -f "$IT_DB" >/dev/null 2>&1 || true
    docker volume rm -f "$IT_VOL" >/dev/null 2>&1 || true
    docker network rm "$IT_NET" >/dev/null 2>&1 || true
}
it_cleanup
trap it_cleanup EXIT INT TERM

docker network create "$IT_NET" >/dev/null
docker volume create "$IT_VOL" >/dev/null
docker run -d --name "$IT_DB" --network "$IT_NET" \
    -e MARIADB_ROOT_PASSWORD=root \
    -e MARIADB_DATABASE=wordpress \
    -e MARIADB_USER=wordpress \
    -e MARIADB_PASSWORD=wordpress \
    "${DB_IMAGE:-mariadb:11}" >/dev/null

printf '  ...waiting for the database\n'
it_ready=no
i=0
while [ "$i" -lt 60 ]; do
    if docker exec "$IT_DB" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
        it_ready=yes
        break
    fi
    i=$((i + 1))
    sleep 1
done
assert_eq "yes" "$it_ready" "database came up"

# One helper so every call carries the same environment the deployment does.
# Extra docker flags go in IT_ENV, because "$@" here is the CONTAINER command —
# passing -e through it would hand the flag to the entrypoint instead.
IT_ENV=""
it_run() {
    # shellcheck disable=SC2086 -- IT_ENV is deliberately word-split
    docker run --rm --network "$IT_NET" -v "$IT_VOL:/usr/share/wordpress" \
        $IT_ENV \
        -e WP_DB_HOST=mariadb-not-used \
        -e WP_DB_NAME=wordpress \
        -e WP_DB_USER=wordpress \
        -e WP_DB_PASS=wordpress \
        -e WP_ABSPATH=/usr/share/wordpress \
        -e HOME=/tmp \
        --add-host "mariadb-not-used:$(docker inspect "$IT_DB" \
            --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}")" \
        "$IMAGE" "$@" 2>&1
}

# First boot on an empty volume: the entrypoint must fetch WordPress itself.
out=$(it_run wp --allow-root core version --allow-root 2>&1 || true)
assert_contains "$out" "Initializing vanilla Wordpress" "first boot downloads WordPress"

version=$(it_run wp --allow-root core version 2>/dev/null | grep -Eo '^[0-9]+\.[0-9]+' | head -1)
case "$version" in
    [0-9]*.[0-9]*) _pass "core version reads back ($version)" ;;
    *) _fail "core version reads back" "got [$version]" ;;
esac

# wp-config.php comes from the template on the same first boot.
has_config=$(it_run sh -c 'test -f /usr/share/wordpress/wp-config.php && echo yes || echo no' \
    | grep -Eo '^(yes|no)$' | head -1)
assert_eq "yes" "$has_config" "wp-config.php created from the template"

# The salt rewrite must have replaced the template's placeholders. Leaving them
# means every site installed from this image signs its auth cookies and nonces
# with a publicly known constant.
salts=$(it_run sh -c 'grep -c "put your unique phrase here" /usr/share/wordpress/wp-config.php || true' \
    | grep -Eo '^[0-9]+$' | head -1)
assert_eq "0" "$salts" "salt placeholders were rewritten"

# ...and must then STAY PUT. This is the assertion with teeth: the loop runs on
# every container start, and a salt is the key every auth cookie is signed with.
# Rewriting a live one logs every user out, which is what the deployed sites
# actually suffered. Read the same key twice, across two separate boots.
read_salt() {
    it_run sh -c "grep -m1 \"define('AUTH_KEY'\" /usr/share/wordpress/wp-config.php" \
        | grep -o "define('AUTH_KEY'.*" | head -1
}
salt_a=$(read_salt)
salt_b=$(read_salt)
assert_eq "$salt_a" "$salt_b" "salts are stable across a restart"
assert_not_contains "$salt_a" "put your unique phrase here" "the stable value is not the placeholder"

# An explicitly pinned value must win, on every boot — that is the whole point
# of the WORDPRESS_<KEY> contract, and it was silently broken too.
IT_ENV="-e WORDPRESS_AUTH_KEY=pinned-by-the-test"
pinned=$(it_run sh -c "grep -m1 \"define('AUTH_KEY'\" /usr/share/wordpress/wp-config.php")
IT_ENV=""
assert_contains "$pinned" "pinned-by-the-test" "WORDPRESS_AUTH_KEY is applied"

# And an unpinned key must not have been disturbed while that happened.
salt_c=$(read_salt)
assert_eq "pinned-by-the-test" "$(echo "$salt_c" | sed -n "s/.*'AUTH_KEY',[[:space:]]*'\([^']*\)'.*/\1/p")" \
    "a pinned value persists once written"

# And the real thing: a working install.
out=$(it_run wp --allow-root core install \
    --url=http://localhost --title=CI \
    --admin_user=ci --admin_password=ci --admin_email=ci@example.test \
    --skip-email 2>&1 || true)
assert_contains "$out" "Success" "wp core install succeeds"

installed=$(it_run wp --allow-root core is-installed --quiet >/dev/null 2>&1 && echo yes || echo no)
assert_eq "yes" "$installed" "wp core is-installed reports true"

it_cleanup
trap - EXIT INT TERM
