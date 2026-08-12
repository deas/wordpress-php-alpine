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
it_run() {
    docker run --rm --network "$IT_NET" -v "$IT_VOL:/usr/share/wordpress" \
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

# The salt rewrite must have replaced the template's placeholders. If this ever
# fails, every container restart logs every user out.
salts=$(it_run sh -c 'grep -c "put your unique phrase here" /usr/share/wordpress/wp-config.php || true' \
    | grep -Eo '^[0-9]+$' | head -1)
assert_eq "0" "$salts" "salt placeholders were rewritten"

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
