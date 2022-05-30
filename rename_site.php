<?php
// WP_DB_NAME=wp WP_HOME=http://localhost/ WP_ABSPATH=/usr/share/wordpress WP_DB_USER=wp WP_DB_PASS=wp WP_DB_HOST=localhost php ./rename_site.php
// WP_DB_NAME=wp WP_HOME=http://localhost/ WP_ABSPATH=/usr/share/wordpress WP_DB_USER=wp WP_DB_PASS=wp WP_DB_HOST=localhost ./wp --path=/usr/share/wp_cr_loc/ search-replace http://xxx.de/ http://yyy:81/
/*
  The "Home" setting is the address you want people to type in their browser to reach your WordPress blog.
  The "Site URL" setting is the address where your WordPress core files reside.
  Both settings should include the http:// part and should not have a slash "/" at the end.
*/

$new_home = isset($_SERVER['HTTP_HOST']) ? "http://".$_SERVER['HTTP_HOST']."/" : getenv("WP_HOME");

if (!$new_home) {
    die("Wordpress home unset");
}

$wp_dir = getenv('WP_ABSPATH');// dirname(__FILE__)."/"
$mysql_host = getenv('WP_DB_HOST');
$mysql_username = getenv('WP_DB_USER');
$mysql_password = getenv('WP_DB_PASS');
$mysql_database = getenv('WP_DB_NAME');
$wp = dirname(__FILE__)."/wp";

$query = "select option_name,option_value from wp_options where option_name in ('home')";//,'siteurl')";
$con = mysqli_connect($mysql_host, $mysql_username, $mysql_password, $mysql_database) or die('Error connecting to MySQL server: ' . mysql_error());
$result = mysqli_query($con, $query);

while($row = mysqli_fetch_array($result)) {
    // echo $row['option_name'] . " " . $row['option_value'] . "\n";
    // http://php.net/manual/de/function.exec.php
    if (strcmp($row['option_value'], $new_home) != 0) {
        $cmd = "WP_DB_NAME=".$mysql_database." WP_DB_USER=".$mysql_username." WP_DB_PASS=".$mysql_password." WP_DB_HOST=".$mysql_host." ".$wp." --allow-root --path=".$wp_dir." search-replace ".$row['option_value']." $new_home 2>/tmp/phperr.log";
        $v = exec($cmd, $out, $rv);
        echo("$cmd\n$v\n$rv\n$out\n");
    } else {
        echo("Wordpress Home already set to ".$new_home."\n");
    }
}
mysqli_close($con);
// unlink($wp_dir."index.php");
// unlink($wp_dir."/wp");
if (file_exists($wp_dir."/index.php-orig")) {
    copy($wp_dir."/index.php-orig","index.php");
    unlink($wp_dir."/index.php-orig");
}

if (isset($_SERVER['HTTP_HOST'])) header("Location: ".$new_home);

?>
