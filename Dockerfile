FROM php:8.1-fpm-alpine
LABEL vendor="Contentreich" \
      maintainer="a.steffan@contentreich.de" \
      description="Contentreich Wordpress based on PHP FPM" \
      version="1.0" \
      de.contentreich.is-beta= \
      de.contentreich.is-production="yes"
ENV LANG C

# And pagespeed, although we disable it
# https://developers.google.com/speed/pagespeed/module/download
# TODO: GD with freetype only for outdated "Really Simple CAPTCHA" in doodle-junkie contact form
# TODO: edge/community is a quick hack to get usermod/groupmod from shadow used by entrypoint
# apt-get update && apt-get install -y libpng12-dev libjpeg-dev libfreetype6-dev wget ssmtp  \
RUN echo http://dl-2.alpinelinux.org/alpine/edge/community/ >> /etc/apk/repositories \
    && apk add --no-cache --virtual .persistent-deps libpng-dev libjpeg-turbo-dev libavif-dev libwebp-dev freetype-dev wget ssmtp shadow \
    &&  docker-php-ext-configure gd --enable-gd --with-jpeg --with-freetype --with-webp --with-avif \
    && pecl install xdebug \
    && docker-php-ext-install gd mysqli opcache \
    && wget https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -O /usr/local/bin/wp && chmod 755 /usr/local/bin/wp \
    && echo "zend_extension = "`ls /usr/local/lib/php/extensions/*/xdebug.so` >>  /usr/local/etc/php/php.ini

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
                echo 'opcache.memory_consumption=128'; \
                echo 'opcache.interned_strings_buffer=8'; \
                echo 'opcache.max_accelerated_files=4000'; \
                echo 'opcache.revalidate_freq=60'; \
                echo 'opcache.fast_shutdown=1'; \
                echo 'opcache.enable_cli=1'; \
        } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Most frequent changing stuff last
# ADD ../ does not work
ADD wp-config-template.php /wp-config-template.php
ADD docker-entrypoint.sh /entrypoint.sh
ADD execute-statements-mysql.php  /execute-statements-mysql.php
ADD rename_site.php /rename_site.php
ADD contentreich.ini /usr/local/etc/php/conf.d
# ADD docker-php-pecl-install /usr/local/bin
# http adds dont cache
# ADD https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar  /wp
# ADD wp-cli.phar  /wp

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
