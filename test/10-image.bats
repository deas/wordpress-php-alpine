#!/usr/bin/env bats
# What the image contains, and whether it works.
#
# Every check here only INSPECTS the image, so setup_file collects everything in
# ONE container and each test reads a value back. 32 assertions, 1 container.

setup_file() {
    load test_helper
    batch_run <<'PROBE'
emit php_version   "$(php -r 'echo PHP_VERSION;')"
emit modules       "$(php -m | tr '\n' ' ')"
emit wp_version    "$(wp --allow-root --version 2>/dev/null | grep -o 'WP-CLI [0-9.]*')"
emit wp_mysql_bin  "$(wp --allow-root cli info 2>/dev/null | sed -n 's/^MySQL binary:[[:space:]]*//p')"
emit wp_mysql_ver  "$(wp --allow-root cli info 2>/dev/null | sed -n 's/^MySQL version:[[:space:]]*//p')"
emit dev_pkgs      "$(apk info 2>/dev/null | grep -c -- '-dev$' || true)"
emit repos         "$(tr '\n' ' ' </etc/apk/repositories)"
emit opcache_ini   "$(tr '\n' ' ' </usr/local/etc/php/conf.d/opcache-recommended.ini)"

for bin in wp mysql mysqldump mysqlcheck ssmtp usermod groupmod curl; do
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
}

setup() { load test_helper; }

@test "PHP is 8.5.x" {
    assert_regex "$(batch_get php_version)" '^8\.5\.'
}

@test "extensions gd zip mysqli exif intl imagick are loaded" {
    local modules
    modules=" $(batch_get modules) "
    for ext in gd zip mysqli exif intl imagick; do
        [[ "$modules" == *" $ext "* ]] || fail "extension not loaded: $ext"
    done
}

# opcache is compiled in statically as of 8.5 rather than installed, so it is
# absent from the ext-install list on purpose. Assert it is loaded ANYWAY —
# that is what makes removing it from the list safe.
@test "opcache is loaded (statically, not installed)" {
    [[ "$(batch_get modules)" == *"Zend OPcache"* ]] || fail "Zend OPcache missing"
}

# gd's feature flags are the reason for the -dev packages and the configure
# line; a base bump that silently drops one would go unnoticed until an upload
# looked wrong.
@test "gd has jpeg support" { assert_equal "$(batch_get gd_jpeg)" yes; }
@test "gd has freetype support" { assert_equal "$(batch_get gd_freetype)" yes; }
@test "gd has webp support" { assert_equal "$(batch_get gd_webp)" yes; }
@test "gd has avif support" { assert_equal "$(batch_get gd_avif)" yes; }

@test "binary present: wp" { assert_equal "$(batch_get bin_wp)" yes; }
@test "binary present: mysql" { assert_equal "$(batch_get bin_mysql)" yes; }
@test "binary present: mysqldump" { assert_equal "$(batch_get bin_mysqldump)" yes; }
@test "binary present: mysqlcheck" { assert_equal "$(batch_get bin_mysqlcheck)" yes; }
@test "binary present: ssmtp" { assert_equal "$(batch_get bin_ssmtp)" yes; }
@test "binary present: usermod" { assert_equal "$(batch_get bin_usermod)" yes; }
@test "binary present: groupmod" { assert_equal "$(batch_get bin_groupmod)" yes; }
@test "binary present: curl" { assert_equal "$(batch_get bin_curl)" yes; }

@test "wp-cli actually runs, not merely exists" {
    assert_regex "$(batch_get wp_version)" '^WP-CLI [0-9]'
}

# The one with teeth: `command -v mysql` above says a file exists, this says
# wp-cli FOUND it. The whole `wp db` family shells out to these binaries, and
# before mariadb-client was installed this line read "MySQL binary:" followed by
# nothing — wp-cli present, `wp db export` dead.
@test "wp-cli resolves a mysql binary" {
    assert_regex "$(batch_get wp_mysql_bin)" '^/'
}

# Client major must track the server the stack runs (mariadb:11, as
# 40-integration pins). A mysqldump from a client a major behind writes output
# the server will not load, which surfaces at restore time, not at dump time.
@test "the mysql client is MariaDB 11.x" {
    assert_regex "$(batch_get wp_mysql_ver)" '11\.[0-9]+\.[0-9]+-MariaDB'
}

# --- extensions actually work, not merely load -------------------------------
#
# `php -m` listing a module says nothing about whether it can do the job. Each
# of these caught, or would have caught, a real defect.

# intl loaded but useless: Alpine's icu-libs pulls icu-data-en — English locale
# data only, four locales, no `de` — so a de_DE site got "March 15, 2026".
# icu-data-full is what makes it "15. März 2026". That is THE reason intl was
# added, so assert the outcome rather than the module.
@test "intl formats German dates in German" {
    assert_regex "$(batch_get intl_de_date)" 'März'
}

@test "full ICU locale data is installed, not icu-data-en" {
    assert_equal "$(batch_get intl_locales)" full
}

# imagick owns the media pipeline once present — WordPress switched from GD to
# EWWWIO_Imagick_Editor on contentreich — so its delegates matter more than its
# presence. Missing delegates fail at upload time, not at boot.
@test "imagick has the jpeg delegate" { assert_equal "$(batch_get imagick_jpeg)" yes; }
@test "imagick has the png delegate" { assert_equal "$(batch_get imagick_png)" yes; }
@test "imagick has the gif delegate" { assert_equal "$(batch_get imagick_gif)" yes; }
@test "imagick has the webp delegate" { assert_equal "$(batch_get imagick_webp)" yes; }

@test "imagick round-trips and resizes a JPEG" {
    assert_equal "$(batch_get imagick_roundtrip)" 20x10
}

# KNOWN ASYMMETRY, asserted so it stays known: gd is built --with-avif but
# Alpine's ImageMagick has no AVIF delegate. WordPress picks an editor per mime
# type so AVIF still routes to GD — if this ever flips, whoever changes it
# should have to change this test too.
@test "imagick has NO AVIF delegate (gd covers AVIF instead)" {
    assert_equal "$(batch_get imagick_avif)" no
    assert_equal "$(batch_get gd_avif)" yes
}

@test "exif_read_data() is callable" {
    assert_equal "$(batch_get exif_callable)" yes
}

# --- build hygiene regression guards -----------------------------------------
#
# Each guards a specific thing the 8.5 branch fixed, and each is the kind of
# thing a well-meaning edit undoes silently.

@test "no -dev packages left in the image" {
    assert_equal "$(batch_get dev_pkgs)" 0
}

@test "no edge repository in the apk config" {
    refute_regex "$(batch_get repos)" 'edge'
}

@test "opcache.fast_shutdown is not set (removed in PHP 7.2)" {
    refute_regex "$(batch_get opcache_ini)" 'fast_shutdown'
    assert_regex "$(batch_get opcache_ini)" 'opcache.memory_consumption'
}
