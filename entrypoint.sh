#!/bin/sh
# defroute=`ip route show | grep ^default`
# routeparts=(${defroute//;/ })
# hostip=${routeparts[2]}
# hostif=${routeparts[4]}
#
# FIXME: wp-config.php should
#
WORDPRESS_ABSPATH=`pwd`
EXTRACT_DIR=..
SRC_DIR=/

#  Test overwrites
# . test_env.sh
# : ${WORDPRESS_JETPACK_DEV_DEBUG:=1}
# WORDPRESS_JETPACK_DEV_DEBUG=${WORDPRESS_JETPACK_DEV_DEBUG-"1"}
# WORDPRESS_DEBUG=${WORDPRESS_DEBUG-"0"}
# WORDPRESS_DEBUG_LOG=${WORDPRESS_DEBUG_LOG-"0"}
# WORDPRESS_DEBUG_DISPLAY=${WORDPRESS_DEBUG_DISPLAY-"0"}
# WORDPRESS_SCRIPT_DEBUG=${WORDPRESS_SCRIPT_DEBUG-"0"}
# WORDPRESS_SAVEQUERIES=${WORDPRESS_SAVEQUERIES-"0"}
IMPORT_SRC=${IMPORT_SRC-"/usr/share/wordpress-import"}
IMPORT_SQL=${IMPORT_SRC}/wordpress.sql
# DOCKER_HOST=`ip route show | grep ^default | awk '{print $3}'`
# SMTP_HOST=`{ grep smtp /etc/hosts || echo $DOCKER_HOST; } |  sed -e s,"\s.*",,g`
SMTP_DOMAIN=${SMTP_DOMAIN-"localhost"}
HTTP=${HTTP-"y"}
HTTPS=${HTTPS-"n"}

set -xe

# function print_help {
#     cat <<EOF
# Usage $0
# Download and setup xy
#   -v                  xy, e.g. "4.2.f"
#   -h                  This help
# EOF
# }

# FIXME - We should really move more (but not all swiches to commandline args)
# Not quite, will be clumsy to override command from the cli
# while getopts "hH:S:" opt; do
#     case "$opt" in
#         H) HTTP=$OPTARG ;;
#         S) HTTPS=$OPTARG ;;
#         # h) print_help;exit 2 ;;
#     esac
# done


# if [ -z "$MYSQL_PORT_3306_TCP" ]; then
    # echo >&2 'error: missing MYSQL_PORT_3306_TCP environment variable'
    # echo >&2 '  Did you forget to --link some_mysql_container:mysql ?'
    # exit 1
    # Host/testing tweak
#    if ip -B link show docker0 >/dev/null 2>&1 ; then
#        WP_DB_HOST=localhost
#    else
#        WP_DB_HOST="$DOCKER_HOST"
#    fi
# else
#     WP_DB_HOST="${MYSQL_PORT_3306_TCP#tcp://}"
# fi


printenv

echo

if [ -z "$WP_DB_PASS" ]; then
    echo >&2 'error: missing required WP_DB_PASS environment variable'
    echo >&2 '  Did you forget to -e WP_DB_PASS=... ?'
    echo >&2
    echo >&2 '  (Also of interest might be WP_DB_USER and WP_DB_NAME.)'
    exit 1
fi

# Set up the installation if wordpress is not there
if ! [ -e "${EXTRACT_DIR}/wordpress/index.php" -a -e "${EXTRACT_DIR}/wordpress/wp-includes/version.php" ]; then
    echo >&2 "WordPress not found in ${EXTRACT_DIR}/wordpress"
    current=$(curl -sSL 'http://api.wordpress.org/core/version-check/1.7/' | sed -r 's/^.*"current":"([^"]+)".*$/\1/')
    echo "Initializing vanilla Wordpress $current"
    curl -SL http://wordpress.org/wordpress-$current.tar.gz | tar -xzC ${EXTRACT_DIR}
#    cp "${SRC_DIR}/wp-config-template.php" "${EXTRACT_DIR}/wordpress/wp-config.php"
    echo >&2 "Complete! WordPress has been successfully set up"
elif [ -e "${IMPORT_SQL}" ] ; then
    echo "Importing SQL"
    cat "${IMPORT_SQL}" | TERM=dumb php "${SRC_DIR}/execute-statements-mysql.php" $WP_DB_HOST $WP_DB_NAME $WP_DB_USER $WP_DB_PASS
    if ! [ -z "$WORDPRESS_HOME" ] ; then
        echo "Fixing values in database"
        WP_DB_NAME="$WP_DB_NAME" WP_HOME="$WORDPRESS_HOME" WP_ABSPATH="$WORDPRESS_ABSPATH" \
                  WP_DB_USER="$WP_DB_USER" WP_DB_PASS="$WP_DB_PASS" WP_DB_HOST="$WP_DB_HOST" php ${SRC_DIR}/rename.site.php
    fi
fi

if ! [ -e "${EXTRACT_DIR}/wordpress/wp-config.php" ] ; then
    cp "${SRC_DIR}/wp-config-template.php" "${EXTRACT_DIR}/wordpress/wp-config.php"
fi

# BULLETPROOF writes this file
# if [ ! -e .htaccess ]; then
#     cat > .htaccess <<-'EOF'
# RewriteEngine On
# RewriteBase /
# RewriteRule ^index\.php$ - [L]
# RewriteCond %{REQUEST_FILENAME} !-f
# RewriteCond %{REQUEST_FILENAME} !-d
# RewriteRule . /index.php [L]
# EOF
# fi

# TODO handle WordPress upgrades magically in the same way, but only if wp-includes/version.php's $wp_version is less
# than /usr/share/wordpress/wp-includes/version.php's $wp_version

set_config() {
    key="$1"
    value="$2"
    php_escaped_value="$(php -r 'var_export($argv[1]);' "$value")"
    sed_escaped_value="$(echo "$php_escaped_value" | sed 's/[\/&]/\\&/g')"
    sed -ri "s/((['\"])$key\2\s*,\s*)(['\"]).*\3/\1$sed_escaped_value/" "${EXTRACT_DIR}/wordpress/wp-config.php"
}

# allow any of these "Authentication Unique Keys and Salts." to be specified via
# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
# NO array in busybox ash
UNIQUES="AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT"

echo "Setting values wp-config.php"

for unique in ${UNIQUES}; do
    eval unique_value=\$WORDPRESS_$unique
    if [ "$unique_value" ]; then
        set_config "$unique" "$unique_value"
    else
        # if not specified, let's generate a random value
        set_config "$unique" "$(head -c1m /dev/urandom | sha1sum | cut -d' ' -f1)"
    fi
done

echo "Setting up ssmtp.conf"
# Hint: Using sed may miss things
mv /etc/ssmtp/ssmtp.conf /etc/ssmtp/orig-ssmtp.conf
cat <<EOF >/etc/ssmtp/ssmtp.conf
#
# Config file for sSMTP sendmail
#
# The person who gets all mail for userids < 1000
# Make this empty to disable rewriting.
root=postmaster

# The place where the mail goes. The actual machine name is required no
# MX records are consulted. Commonly mailhosts are named mail.domain.com
mailhub=smtp

# Where will the mail seem to come from?
rewriteDomain=$SMTP_DOMAIN

# The full hostname

# Are users allowed to set their own From: address?
# YES - Allow the user to specify their own From: address
# NO - Use the system generated From: address
FromLineOverride=YES
EOF

# From
# sed -i \
#    -e 's/.*mailhub=.*l/mailhub=smtp/' \
#    -e '/hostname=/d' \
#    -e "s/.*rewriteDomain=.*/rewriteDomain=$SMTP_DOMAIN/" \
#    -e "s/.*FromLineOverride=.*/FromLineOverride=YES/" \
#     /etc/ssmtp/ssmtp.conf

# Dev goodness
# No usermod/groupmod in alpine
if [ -n "${WWW_UID}" ] ; then
    usermod -u ${WWW_UID} www-data
fi

if [ -n "${WWW_GID}" ] ; then
    groupmod -g ${WWW_GID} www-data
fi

# Make sure php can write!
chown -R www-data:www-data /var/log/www

# echo ">> exec docker CMD"
# echo "$@"
exec "$@"
