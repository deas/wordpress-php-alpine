#!/bin/sh
# What the image contains. No database, no network — pure inspection, so this
# suite is the fast one and runs first.

suite "image contents"

php_version=$(php_probe 'PHP_VERSION')
case "$php_version" in
    8.5.*) _pass "PHP is 8.5.x ($php_version)" ;;
    *) _fail "PHP is 8.5.x" "got [$php_version]" ;;
esac

modules=$(sh_probe 'php -m | tr "\n" " "')
for ext in gd zip mysqli exif intl imagick; do
    assert_contains "$modules" " $ext " "extension loaded: $ext"
done
# opcache is compiled in statically as of 8.5 rather than installed, so it is
# absent from the ext-install list on purpose. Assert it is loaded ANYWAY —
# that is what makes removing it from the list safe.
assert_contains "$modules" "Zend OPcache" "opcache loaded (statically, not installed)"

# gd's feature flags are the reason for the -dev packages and the configure
# line; a base bump that silently drops one would otherwise go unnoticed until
# an upload looked wrong.
for feature in 'JPEG Support' 'FreeType Support' 'WebP Support' 'AVIF Support'; do
    got=$(php_probe "gd_info()['$feature'] ? 'yes' : 'no'")
    assert_eq "yes" "$got" "gd has $feature"
done

for bin in wp ssmtp usermod groupmod curl; do
    path=$(sh_probe "command -v $bin || echo MISSING")
    assert_not_contains "$path" "MISSING" "binary present: $bin"
done

# wp-cli must actually run, not merely exist. Its output goes through the same
# marker trick because the phar emits a deprecation on stdout on PHP 8.5.
wp_version=$(sh_probe 'wp --allow-root --version 2>/dev/null | grep -o "WP-CLI [0-9.]*"')
assert_contains "$wp_version" "WP-CLI" "wp-cli runs ($wp_version)"

suite "build hygiene (regression guards)"

# Each of these guards a specific thing the 8.5 branch fixed. They are cheap and
# they are the ones most likely to be undone by a well-meaning edit.

# The -dev headers used to ship to production as `.persistent-deps`.
dev_pkgs=$(sh_probe 'apk info 2>/dev/null | grep -c -- "-dev$" || true')
assert_eq "0" "$dev_pkgs" "no -dev packages left in the image"

# edge/community on a stable base lets any apk resolution pull from edge.
repos=$(sh_probe 'cat /etc/apk/repositories | tr "\n" " "')
assert_not_contains "$repos" "edge" "no edge repository in the apk config"

# opcache.fast_shutdown was removed in PHP 7.2 and silently ignored since.
opcache_ini=$(sh_probe 'cat /usr/local/etc/php/conf.d/opcache-recommended.ini | tr "\n" " "')
assert_not_contains "$opcache_ini" "fast_shutdown" "opcache.fast_shutdown not set (removed in PHP 7.2)"
assert_contains "$opcache_ini" "opcache.memory_consumption" "opcache tuning still applied"
