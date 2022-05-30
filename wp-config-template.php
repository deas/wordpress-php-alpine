<?php

$table_prefix  = 'wp_';   // Only numbers, letters, and underscores please!

/*
http://dev.mikamai.com/post/85531658709/a-modern-workflow-for-wordpress-using-docker-and-dokku

Apache config even overwrites php-fpm environment from shell

SetEnv WP_JETPACK_DEV_DEBUG true
SetEnv WP_DB_NAME wordpress
SetEnv WP_DB_USER wordpress
SetEnv WP_DB_PASS wordpress
SetEnv WP_DB_HOST localhost
*/

define('DB_CHARSET', 'utf8');
define('DB_COLLATE', '');
define('WP_MEMORY_LIMIT', '96M');

/**#@+
 * Authentication Unique Keys and Salts.
 *
 * Change these to different unique phrases!
 * You can generate these using the {@link https://api.wordpress.org/secret-key/1.1/salt/ WordPress.org secret-key service}
 * You can change these at any point in time to invalidate all existing cookies. This will force all users to have to log in again.
 *
 * @since 2.6.0
 */
define('AUTH_KEY',         'put your unique phrase here');
define('SECURE_AUTH_KEY',  'put your unique phrase here');
define('LOGGED_IN_KEY',    'put your unique phrase here');
define('NONCE_KEY',        'put your unique phrase here');
define('AUTH_SALT',        'put your unique phrase here');
define('SECURE_AUTH_SALT', 'put your unique phrase here');
define('LOGGED_IN_SALT',   'put your unique phrase here');
define('NONCE_SALT',       'put your unique phrase here');

// http://jetpack.me/2013/03/28/jetpack-dev-mode-release/
define( 'JETPACK_DEV_DEBUG', (bool) getenv('WP_JETPACK_DEV_DEBUG'));

// http://codex.wordpress.org/Debugging_in_WordPress
define('WP_DEBUG', (bool) getenv('WP_DEBUG'));
define('WP_DEBUG_LOG', (bool) getenv('WP_DEBUG_LOG')); // wp-content/debug.log
define('WP_DEBUG_DISPLAY', (bool) getenv('WP_DEBUG_DISPLAY'));
// Use dev versions of core JS and CSS files (only needed if you are modifying these core files)
define('SCRIPT_DEBUG', (bool) getenv('SCRIPT_DEBUG')); // -> Don't use minimized/compressed !
define('SAVEQUERIES', (bool) getenv('SAVEQUERIES'));

// ** MySQL settings ** //
define('DB_NAME', getenv('WP_DB_NAME'));
define('DB_USER', getenv('WP_DB_USER'));
define('DB_PASSWORD', getenv('WP_DB_PASS'));
define('DB_HOST', getenv('WP_DB_HOST'));
// Don't use this. value from wp_options overwrites it anyways!
// See http://codex.wordpress.org/Function_Reference/get_locale
// define('WPLANG', 'de_DE');
define('ABSPATH', getenv('WP_ABSPATH'));
// require_once('contentreich-config.php');// As w3  total cache et al write here
require_once('wp-settings.php');
// require_once(ABSPATH.'wp-settings.php');
?>
