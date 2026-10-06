#!/bin/bash
#
# clk-nixinit :: mariadb
# MariaDB server, with the root account renamed to mariadmin and its generated
# password recorded in /root/salt. Always pulls in the mariadbkp module.
#
# usage: make-mariadb.sh

##
# Variables
##

set -a											# export all variables

scriptdir=$(dirname "$(realpath "$0")")							# set script directory

# shellcheck source=../../lib/common.sh
. "$scriptdir"/../../lib/common.sh


##
# Configuration
##

need_root
logstart "mariadb"

mdbversion=$(cfg mariadb_version 11.4)							# mariadb series to track
mdbadmin=$(cfg mariadb_admin mariadmin)							# renamed superuser
poolsize=$(cfg innodb_pool 1G)								# innodb buffer pool


##
# Script
##

banner "MariaDB"
cursoff

# Add the MariaDB repo
step "Adding the MariaDB repository"
makespin "curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version='$mdbversion' --skip-maxscale"

step "Updating repositories"
makespin "apt-get update"

step "Installing MariaDB"
makespin "apt_install mariadb-server"

# Enable error log
step "Enabling the error log"
sed -i '/log_error/s/^#//g' /etc/mysql/mariadb.conf.d/50-server.cnf
okay

# Security tweaks. Run as direct SQL rather than piping canned answers into
# the interactive wizard -- that pipe only works because the exact number and
# order of its prompts happens to match this MariaDB series; a newer one that
# adds, drops or reorders a single prompt silently answers the wrong question
# with no error. DELETE/DROP/FLUSH are stable SQL, not an interactive script.
step "Dropping anonymous users and the test database"
mariadb >>"$clklog" 2>&1 <<SQLEOF || fail
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQLEOF
okay

## Create random mariadb password and rename the superuser ##
step "Setting the $mdbadmin password"
mdbpass=$(genpw 20)
salt_add "The root mariaDB password is" "$mdbpass"

mariadb >>"$clklog" 2>&1 <<SQLEOF || fail
ALTER USER 'root'@'localhost' IDENTIFIED BY '$mdbpass';
RENAME USER 'root'@'localhost' TO '$mdbadmin'@'localhost';
FLUSH PRIVILEGES;
SQLEOF
okay

## Optimization tweaks ##
# Every sed below anchors on text the packaged 50-server.cnf ships today. A
# future MariaDB series can reword or restructure that file, and sed finds no
# match and silently changes nothing -- so each edit is verified afterward and
# warns instead of quietly no-opping.
cnf=/etc/mysql/mariadb.conf.d/50-server.cnf

# query_cache_size is a removed/deprecated variable on some series -- only set
# it if this mariadbd build still recognizes it, or a stale value is fatal at
# startup rather than just wrong
step "Tuning query_cache_size"

# --help --verbose lists variables hyphenated (query-cache-size), matching its
# own --query-cache-size flag, not the underscored form the config file and
# this grep both otherwise use -- match either separator
if mariadbd --help --verbose 2>/dev/null | grep -qE '^[[:space:]]*query[_-]cache[_-]size([[:space:]]|$)'; then
	sed -i '/Fine Tuning/{N;N;s/$/\nquery_cache_size = 0/}' "$cnf"
	if grep -q '^query_cache_size = 0' "$cnf"; then okay; else warn; fi
else
	skip
fi

step "Tuning max_connections"
sed -i '/max_connections/c\max_connections         = 400' "$cnf"
if grep -q '^max_connections *= *400' "$cnf"; then okay; else warn; fi

step "Tuning innodb_buffer_pool_size"
sed -i "/innodb_buffer_pool_size =/c\\innodb_buffer_pool_size = $poolsize\nkey_buffer_size = 10M" "$cnf"
if grep -q "^innodb_buffer_pool_size = $poolsize\$" "$cnf"; then okay; else warn; fi

step "Restarting MariaDB"
makespin "systemctl restart mariadb"

profile_set mariadb 1
profile_set mariadb_admin "$mdbadmin"
profile_set mariadb_version "$mdbversion"

curson

echo -e "${bgrn}   MariaDB complete!${cln}\n"


##
# Wherever MariaDB lands, the backup script lands with it
##

bash "$scriptdir"/../mariadbkp/make-mdbkp.sh
