#!/bin/bash
#
# shellcheck disable=SC2174  # mkdir -m with -p only applies the mode to the leaf, which is what we want
# clk-nixinit :: mariadbkp
# Installs the nightly MariaDB backup job. Pulled in automatically by the
# mariadb module, but runnable on its own against an existing MariaDB.
#
# This script installs itself on first run, then acts as the cron job on every
# later, already-installed run -- the original mdbkp.sh convention, preserved
# here. Because the installed copy has to keep working long after this source
# checkout is gone, it stays fully self-contained and never sources
# lib/common.sh.
#
# Unlike the original mdbkp.sh it does not remove its own source directory:
# it now lives inside the larger clk-nixinit checkout, so deleting it here
# would only ever be a piece of that checkout's own cleanup, not this script's
# job. Removing the whole checkout is the wrapper's --cleanup flag.
#
# usage: make-mdbkp.sh

##
# Variables
##

clkprofile=/etc/clickwork/nixinit.conf							# install profile
clksalt=/root/salt									# credential ledger, legacy format

BkpDir=/bkp/mariaDB									# backup path for dbs
BkpLogDir=/var/log/mariaDBkp								# backup log path
InstDir=/etc/clickwork/mariaDBkp							# installation path

NoBkpDBs=("performance_schema" "information_schema" "phpmyadmin" "sys")			# list of excluded databases


##
# Functions
##

profile_get() {

	[[ -f $clkprofile ]] || { echo "$2"; return 0; }
	local val
	val=$(sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$clkprofile" | tail -n 1)
	echo "${val:-$2}"
}

mdbadmin=$(profile_get mariadb_admin mariadmin)						# mariadb superuser


##
# Install script if it's not present
##

if ! [ -f "$InstDir"/mdbkp ]; then							# if script doesn't exist

	##
	# Check for .my.cnf
	##

	echo
	echo -n "Checking for .my.cnf autologin file .............. "

	if ! [ -f /root/.my.cnf ]; then

		echo -e "[\033[33m NOT FOUND \033[0m]\n"

		if [ -f "$clksalt" ] && grep -q "mariaDB password is" "$clksalt"; then

			mDBPass=$(grep -oP "mariaDB password is:\s+\K\w+" "$clksalt")	# get MariaDB root password

			echo -n "Creating .my.cnf autologin file .................. "
			echo -e "[client]\nuser=$mdbadmin\npassword=$mDBPass" > /root/.my.cnf || { echo -e "\n \033[1;91m[FAILED]\033[0m"; echo; exit 1; } ; echo -e "[\033[32m OK \033[0m]\n"

		else

			read -r -p "	Enter mariaDB login username: " mDBUsr	# ask for username
			read -r -p "	Enter mariaDB login password: " mDBPass	# ask for password

			echo
			echo -n "Creating .my.cnf autologin file .................. "
			echo -e "[client]\nuser=$mDBUsr\npassword=$mDBPass" > /root/.my.cnf || { echo -e "\n \033[1;91m[FAILED]\033[0m"; echo; exit 1; } ; echo -e "[\033[32m OK \033[0m]\n"

		fi

		chmod 600 /root/.my.cnf

	else

		echo -e "[\033[32m OK \033[0m]\n"

	fi


	##
	# Installation
	##

	echo -n "Installing script ................................ "
	install -D -m500 "$0" "$InstDir"/mdbkp || { echo -e "\n \033[1;91m[FAILED]\033[0m"; echo; exit 1; }; echo -e "[\033[32m OK \033[0m]\n"

	echo -n "Create backup directory .......................... "
	mkdir -p -m 700 "$BkpDir" || { echo -e "\n \033[1;91m[FAILED]\033[0m"; echo; exit 1; } ; echo -e "[\033[32m OK \033[0m]\n"

	echo -n "Create backup log directory ...................... "
	mkdir -p "$BkpLogDir" || { echo -e "\n \033[1;91m[FAILED]\033[0m"; echo; exit 1; } ; echo -e "[\033[32m OK \033[0m]\n"

	echo -n "Create backup schedule ........................... "
	ln -sf "$InstDir"/mdbkp /etc/cron.daily/mdbkp || { echo -e "\n \033[1;91m[FAILED]\033[0m"; echo; exit 1; } ; echo -e "[\033[32m OK \033[0m]\n"

	echo -n "Create rotate backup schedule .................... "
	printf '#!/bin/sh\nfind %s -mindepth 1 -mtime +30 -delete\n' "$BkpDir" > /etc/cron.daily/rotate-backups || { echo -e "\n \033[1;91m[FAILED]\033[0m"; echo; exit 1; } ; echo -e "[\033[32m OK \033[0m]\n"
	chmod +x /etc/cron.daily/rotate-backups

	[ -f "$clkprofile" ] || mkdir -p "$(dirname "$clkprofile")"
	sed -i '/^mariadbkp=/d' "$clkprofile" 2>/dev/null
	echo 'mariadbkp="1"' >> "$clkprofile"

else

	##
	# Backup variables
	##

	BkpTime=$(date +%Y.%m.%d_%H:%M) # date and time for backup file name

	mapfile -t AllDBs < <(echo "SHOW DATABASES;" | mariadb -N) # Get a list of databases

	mapfile -t BkpDBs < <(echo "${AllDBs[@]}" "${NoBkpDBs[@]}" | tr ' ' '\n' | sort | uniq -u) # extract the list of DBs to backup


	##
	# Loop through the DBs
	##

	for EachDB in "${BkpDBs[@]}"; do

		BkpFile="$BkpDir"/"$EachDB""_""$BkpTime"".sql.gz" # generate backup filename

		BkpErrLog="$BkpLogDir"/"$EachDB""_""$BkpTime"".error.log" # generate backup error log filename

		mariadb-dump --opt --routines --triggers --single-transaction "$EachDB" 2>"$BkpErrLog" | gzip >"$BkpFile" # dump and compress the database, logging errors into the error log

		[ -s "$BkpErrLog" ] || rm -f "$BkpErrLog" # delete error log if empty

	done

fi
