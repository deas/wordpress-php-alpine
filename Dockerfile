# https://make.wordpress.org/core/handbook/references/php-compatibility-and-wordpress-versions/
# WordPress 7.0 supports PHP 8.5. The "beta support" label was retired in May
# 2026, so 8.5 is plain "supported" — no exceptions to work around.
FROM php:8.5-fpm-alpine
LABEL vendor="Contentreich" \
      maintainer="a.steffan@contentreich.de" \
      description="Contentreich Wordpress based on PHP FPM" \
      version="1.0" \
      de.contentreich.is-beta= \
      de.contentreich.is-production="yes"
# C.UTF-8, not C: WordPress is UTF-8 throughout and the bare C locale is not.
ENV LANG=C.UTF-8

# TODO: GD with freetype only for outdated "Really Simple CAPTCHA" in doodle-junkie contact form
#
# NO edge/community repository any more. It used to be here as "a quick hack to
# get usermod/groupmod from shadow", and it was a standing hazard: with edge in
# the repository list ANY apk resolution may pull an edge package onto a stable
# base. `shadow` has since landed in v3.24/community, which the base image
# already enables — so the hack buys nothing and is gone. Verified: usermod and
# groupmod are present without it.
#
# Two apk layers, deliberately. Only the shared libraries the extensions link
# against stay in the image; the -dev headers go in a virtual package that is
# deleted at the end. They used to be installed as `.persistent-deps` and never
# removed, so every -dev package shipped to production — weight, and CVE surface
# that cve-scan.yml then reported against.
#
# opcache is NOT in the ext-install list: as of PHP 8.5 the official image
# compiles it in statically. `docker-php-ext-install opcache` builds no module
# and fails the layer with
#   cp: can't stat 'modules/*': No such file or directory
# It is still loaded — `php -m` reports Zend OPcache on the untouched base.
#
# exif / intl / imagick answer WordPress's own Site Health report, which listed
# all three as missing optional modules on this image.
#   exif    free, bundled — image orientation and metadata, which the site's
#           image plugins (ewww, wp-retina-2x, regenerate-thumbnails,
#           contentreich-ps-img) all expect.
#   intl    +10 MB (icu-libs) and a further +28 MB for icu-data-full, which is
#           NOT optional here. Alpine's icu-libs pulls icu-data-en, i.e. English
#           locale data only — four locales, `de` not among them — so intl loads
#           and then formats German dates in English ("March 15, 2026"). With
#           the full data it is "15. März 2026". Installing intl for a de_DE
#           site and leaving it on icu-data-en buys nothing at all.
#   imagick +26 MB (imagemagick). WordPress prefers it over GD for resizing.
#           NOTE: Alpine 3.24 ships ImageMagick 7.1.2-27 marked "(Beta)". That
#           is the one module here taken on a calculated risk; drop this and the
#           imagemagick/imagemagick-dev packages to back it out.
RUN set -eux; \
    apk add --no-cache \
        libzip libpng libjpeg-turbo libavif libwebp freetype \
        icu-libs icu-data-full imagemagick \
        ssmtp shadow; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        libzip-dev libpng-dev libjpeg-turbo-dev libavif-dev libwebp-dev freetype-dev \
        icu-dev imagemagick-dev linux-headers; \
    docker-php-ext-configure gd --enable-gd --with-jpeg --with-freetype --with-webp --with-avif; \
    docker-php-ext-configure zip; \
    docker-php-ext-install -j"$(nproc)" zip gd mysqli exif intl; \
    pecl install imagick-3.8.1; \
    docker-php-ext-enable imagick; \
    pecl install xdebug-3.5.3; \
    pecl clear-cache; \
    curl -sSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp; \
    chmod 755 /usr/local/bin/wp; \
    apk del --no-network .build-deps; \
    php -m

# Xdebug ships in the image but is NOT loaded by default.
#
# It used to be registered by appending `zend_extension=` to php.ini itself,
# which meant production carried a loaded debugger with no way to switch it off,
# and every PHP notice came out wrapped in a ten-frame Xdebug stack trace — on
# stdout, where wp-cli's output is parsed.
#
# So: generate the ini the normal way, then move it OUT of conf.d. entrypoint.sh
# copies it back when PHP_XDEBUG_ENABLED says so, at container creation time.
# Everything else is native Xdebug 3 environment config and needs nothing from
# us — XDEBUG_MODE picks the mode, XDEBUG_CONFIG the client host/port.
#
# start_with_request=trigger means "loaded" still does not mean "slow": Xdebug
# stays dormant until a request actually carries XDEBUG_TRIGGER.
RUN set -eux; \
    docker-php-ext-enable xdebug; \
    { \
        cat /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini; \
        echo 'xdebug.mode=debug'; \
        echo 'xdebug.start_with_request=trigger'; \
        echo 'xdebug.client_host=host.docker.internal'; \
        echo 'xdebug.client_port=9003'; \
        echo 'xdebug.log=/proc/self/fd/2'; \
    } > /usr/local/etc/php/xdebug.ini.available; \
    rm /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini; \
    php -m | grep -qi xdebug && { echo "xdebug must NOT be loaded by default"; exit 1; } || true

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
# opcache.fast_shutdown is gone from this list: it was REMOVED in PHP 7.2 and
# has been silently ignored ever since (ini_get() returns false on 8.5).
RUN { \
                echo 'opcache.memory_consumption=128'; \
                echo 'opcache.interned_strings_buffer=8'; \
                echo 'opcache.max_accelerated_files=4000'; \
                echo 'opcache.revalidate_freq=60'; \
                echo 'opcache.enable_cli=1'; \
        } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Most frequent changing stuff last
# ADD ../ does not work
ADD wp-config-template.php /wp-config-template.php
ADD entrypoint.sh /entrypoint.sh
ADD execute-statements-mysql.php  /execute-statements-mysql.php
ADD rename_site.php /rename_site.php
ADD contentreich.ini /usr/local/etc/php/conf.d

# TODO: Should probably not be a volume so we can also move images around
VOLUME /usr/share/wordpress
VOLUME /var/log/www
WORKDIR /usr/share/wordpress

ENTRYPOINT ["/entrypoint.sh"]
# We use --expose 80 at runtime
# No way to get rid of EXPOSE setting from here
# EXPOSE 80
EXPOSE 9000
CMD ["php-fpm"]
