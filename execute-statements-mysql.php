<?php
// php execute-statements-mysql.sql localhost wp_scratch wp_scratch wp_scratch
$mysql_host = $argv[1];
$mysql_username = $argv[2];
$mysql_password = $argv[3];
$mysql_database = $argv[4];

// var_dump($argv);
// echo "$mysql_host $mysql_username $mysql_password $mysql_database";

mysql_connect($mysql_host, $mysql_username, $mysql_password) or die('Error connecting to MySQL server: ' . mysql_error());
mysql_select_db($mysql_database) or die('Error selecting MySQL database: ' . mysql_error());

$templine = '';
$cnt = 0;

while($line = fgets(STDIN)){
// Skip it if it's a comment
    if (substr($line, 0, 2) == '--' || $line == '')
        continue;
    $templine .= $line;

// If it has a semicolon at the end, it's the end of the query
    if (substr(trim($line), -1, 1) == ';')
    {
        // Perform the query
        mysql_query($templine) or print('Error performing query \'<strong>' . $templine . '\': ' . mysql_error() . '<br /><br />');
        // Reset temp variable to empty
        $templine = '';
        $cnt++;
    }
}
# $mysql->close();
echo "$cnt statements executed\n";
?>