#!/bin/sh
# What the image contains, and whether it works.
#
# Every check here only INSPECTS the image, so the whole file runs in ONE
# container rather than one per assertion. That is the difference between ~15
# container starts and 1, and a container start costs roughly 3.8s.

batch_run <<'PROBE'
emit php_version   "$(php -r 'echo PHP_VERSION;')"
emit modules       "$(php -m | tr '\n' ' ')"
emit wp_version    "$(wp --allow-root --version 2>/dev/null | grep -o 'WP-CLI [0-9.]*')"
emit dev_pkgs      "$(apk info 2>/dev/null | grep -c -- '-dev$' || true)"
emit repos         "$(tr '\n' ' ' </etc/apk/repositories)"
emit opcache_ini   "$(tr '\n' ' ' </usr/local/etc/php/conf.d/opcache-recommended.ini)"

for bin in wp ssmtp usermod groupmod curl; do
    emit "bin_$bin" "$(command -v "$bin" >/dev/null 2>&1 && echo yes || echo no)"
done

# PHP prints its own marker lines — one less layer of quoting than routing the
# values back out through emit.
php -r '
    $gd = gd_info();
    foreach (["JPEG", "FreeType", "WebP", "AVIF"] as $f) {
        printf("__P__gd_%s=%s__E__\n", strtolower($f), $gd["$f Support"] ? "yes" : "no");
    }

    $fmt = Imagick::queryFormats();
    foreach (["JPEG", "PNG", "GIF", "WEBP", "AVIF"] as $f) {
        printf("__P__imagick_%s=%s__E__\n", strtolower($f), in_array($f, $fmt) ? "yes" : "no");
    }

    $im = new Imagick();
    $im->newImage(40, 20, new ImagickPixel("red"));
    $im->setImageFormat("jpeg");
    $rt = new Imagick();
    $rt->readImageBlob($im->getImageBlob());
    $rt->resizeImage(20, 10, Imagick::FILTER_LANCZOS, 1);
    printf("__P__imagick_roundtrip=%dx%d__E__\n", $rt->getImageWidth(), $rt->getImageHeight());

    $df = new IntlDateFormatter("de_DE", IntlDateFormatter::LONG,
                                IntlDateFormatter::NONE, "Europe/Berlin");
    printf("__P__intl_de_date=%s__E__\n", $df->format(mktime(0, 0, 0, 3, 15, 2026)));
    printf("__P__intl_locales=%s__E__\n",
           count(ResourceBundle::getLocales("")) > 100 ? "full" : "minimal");

    printf("__P__exif_callable=%s__E__\n", function_exists("exif_read_data") ? "yes" : "no");
'
PROBE

suite "image contents"

php_version=$(batch_get php_version)
case "$php_version" in
    8.5.*) _pass "PHP is 8.5.x ($php_version)" ;;
    *) _fail "PHP is 8.5.x" "got [$php_version]" ;;
esac

modules=$(batch_get modules)
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
for f in jpeg freetype webp avif; do
    assert_eq "yes" "$(batch_get "gd_$f")" "gd has $f support"
done

for bin in wp ssmtp usermod groupmod curl; do
    assert_eq "yes" "$(batch_get "bin_$bin")" "binary present: $bin"
done

# wp-cli must actually run, not merely exist.
assert_contains "$(batch_get wp_version)" "WP-CLI" "wp-cli runs ($(batch_get wp_version))"

suite "extensions actually work (not merely loaded)"

# `php -m` listing a module says nothing about whether it can do the job. Each
# of these caught, or would have caught, a real defect:

# intl loaded but useless. Alpine's icu-libs pulls icu-data-en — English locale
# data only, four locales, no `de` — so a de_DE site gets "March 15, 2026".
# icu-data-full is what makes it "15. März 2026". This is THE reason intl was
# added, so assert the outcome rather than the module.
de_date=$(batch_get intl_de_date)
assert_contains "$de_date" "März" "intl formats German dates in German ($de_date)"
assert_eq "full" "$(batch_get intl_locales)" "full ICU locale data, not icu-data-en"

# imagick owns the media pipeline once it is present — WordPress switched from
# GD to EWWWIO_Imagick_Editor on contentreich — so its delegates matter more
# than its presence. Missing delegates fail at upload time, not at boot.
for f in jpeg png gif webp; do
    assert_eq "yes" "$(batch_get "imagick_$f")" "imagick has the $f delegate"
done

# A real encode/decode/resize round trip, which is what an upload does.
assert_eq "20x10" "$(batch_get imagick_roundtrip)" "imagick round-trips and resizes a JPEG"

# KNOWN ASYMMETRY, asserted so it stays known: gd is built --with-avif but
# Alpine's ImageMagick has no AVIF delegate. WordPress picks an editor per mime
# type, so AVIF still routes to GD — but if this ever flips, whoever changes it
# should have to change this line too.
assert_eq "no" "$(batch_get imagick_avif)" "imagick has NO AVIF delegate (gd covers AVIF)"
assert_eq "yes" "$(batch_get gd_avif)" "gd still covers AVIF"

# exif is what the site's image plugins read orientation and metadata with.
assert_eq "yes" "$(batch_get exif_callable)" "exif_read_data() is callable"

suite "build hygiene (regression guards)"

# Each of these guards a specific thing the 8.5 branch fixed. They are cheap and
# they are the ones most likely to be undone by a well-meaning edit.

# The -dev headers used to ship to production as `.persistent-deps`.
assert_eq "0" "$(batch_get dev_pkgs)" "no -dev packages left in the image"

# edge/community on a stable base lets any apk resolution pull from edge.
assert_not_contains "$(batch_get repos)" "edge" "no edge repository in the apk config"

# opcache.fast_shutdown was removed in PHP 7.2 and silently ignored since.
opcache_ini=$(batch_get opcache_ini)
assert_not_contains "$opcache_ini" "fast_shutdown" "opcache.fast_shutdown not set (removed in PHP 7.2)"
assert_contains "$opcache_ini" "opcache.memory_consumption" "opcache tuning still applied"
