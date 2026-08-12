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

suite "extensions actually work (not merely loaded)"

# `php -m` listing a module says nothing about whether it can do the job. Each
# of these caught, or would have caught, a real defect:

# intl loaded but useless. Alpine's icu-libs pulls icu-data-en — English locale
# data only, four locales, no `de` — so a de_DE site gets "March 15, 2026".
# icu-data-full is what makes it "15. März 2026". This is THE reason intl was
# added, so assert the outcome rather than the module.
de_date=$(php_probe '(new IntlDateFormatter("de_DE", IntlDateFormatter::LONG,
    IntlDateFormatter::NONE, "Europe/Berlin"))->format(mktime(0,0,0,3,15,2026))')
assert_contains "$de_date" "März" "intl formats German dates in German ($de_date)"

locales=$(php_probe 'count(ResourceBundle::getLocales("")) > 100 ? "full" : "minimal"')
assert_eq "full" "$locales" "full ICU locale data is installed, not icu-data-en"

# imagick owns the media pipeline once it is present — WordPress switched from
# GD to EWWWIO_Imagick_Editor on contentreich — so its delegates matter more
# than its presence. Missing delegates fail at upload time, not at boot.
for fmt in JPEG PNG GIF WEBP; do
    got=$(php_probe "in_array('$fmt', Imagick::queryFormats()) ? 'yes' : 'no'")
    assert_eq "yes" "$got" "imagick has the $fmt delegate"
done

# A real encode/decode/resize round trip, which is what an upload does.
rt=$(php_probe '(function () {
    $im = new Imagick(); $im->newImage(40, 20, new ImagickPixel("red"));
    $im->setImageFormat("jpeg");
    $r = new Imagick(); $r->readImageBlob($im->getImageBlob());
    $r->resizeImage(20, 10, Imagick::FILTER_LANCZOS, 1);
    return $r->getImageWidth() . "x" . $r->getImageHeight();
})()')
assert_eq "20x10" "$rt" "imagick round-trips and resizes a JPEG"

# KNOWN ASYMMETRY, asserted so it stays known: gd is built --with-avif but
# Alpine's ImageMagick has no AVIF delegate. WordPress picks an editor per mime
# type, so AVIF still routes to GD — but if this ever flips, whoever changes it
# should have to change this line too.
assert_eq "no" "$(php_probe "in_array('AVIF', Imagick::queryFormats()) ? 'yes' : 'no'")" \
    "imagick has NO AVIF delegate (gd covers AVIF instead)"
assert_eq "yes" "$(php_probe 'gd_info()["AVIF Support"] ? "yes" : "no"')" \
    "gd still covers AVIF"

# exif is what the site's image plugins read orientation and metadata with.
assert_eq "yes" "$(php_probe 'function_exists("exif_read_data") ? "yes" : "no"')" \
    "exif_read_data() is callable"

suite "binaries"

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
