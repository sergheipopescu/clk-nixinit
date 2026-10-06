#!/bin/bash
#
# clk-nixinit :: pftpd
# pure-ftpd with MariaDB backed virtual users. entld adds one row per hosted
# domain, so an FTP account never becomes a system account.
#
# usage: make-pftpd.sh

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
logstart "pftpd"

hostname=$(hostname)									# certificate subject
mdbadmin=$(cfg mariadb_admin mariadmin)							# mariadb superuser
passiveports=$(cfg ftp_passive_ports "40001 40128")					# passive port range
ftpuid=$(cfg ftp_uid 2001)								# uid/gid of the shared pftpd account

mdbpass=$(salt_mdbpass)									# get MariaDB root password

[[ -n $mdbpass ]] || { echo -e "\n ${bred}No MariaDB password in $clksalt${cln}\n"; exit 1; }


##
# Script
##

banner "pure-ftpd"
cursoff

step "Installing pure-ftpd"
makespin "apt_install pure-ftpd-mysql"

# Create the pftpd user every virtual account maps onto
step "Creating the pftpd system account"

if getent passwd pftpd >/dev/null; then
	skip
else
	groupadd -g "$ftpuid" pftpd >>"$clklog" 2>&1
	useradd -u "$ftpuid" -s /bin/false -d /bin/null -c "Pureftpd User" -g pftpd pftpd >>"$clklog" 2>&1
	okay
fi

# Generate the ftp database password
step "Creating the ftp database"
ftpdbpass=$(genpw 20)
salt_add "The pftpd-admin password is" "$ftpdbpass"

mariadb -u"$mdbadmin" -p"$mdbpass" >>"$clklog" 2>&1 <<SQLEOF || fail
CREATE DATABASE IF NOT EXISTS pftpd;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP ON pftpd.* TO 'pftpd-admin'@'localhost' IDENTIFIED BY '$ftpdbpass';
FLUSH PRIVILEGES;
USE pftpd;
CREATE TABLE IF NOT EXISTS ftpd (User varchar(64) NOT NULL default '',
status enum('0','1') NOT NULL default '0',
Password varchar(160) NOT NULL default '',
Uid varchar(11) NOT NULL default '-1',
Gid varchar(11) NOT NULL default '-1',
Dir varchar(128) NOT NULL default '',
ULBandwidth smallint(5) NOT NULL default '0',
DLBandwidth smallint(5) NOT NULL default '0',
comment tinytext NOT NULL,
ipaccess varchar(15) NOT NULL default '*',
QuotaSize smallint(5) NOT NULL default '0',
QuotaFiles int(11) NOT NULL default 0,
PRIMARY KEY (User),UNIQUE KEY User (User)
) ENGINE=MyISAM;
SQLEOF
okay

# Create the db connect config file
step "Configuring the database connection"
[[ -f /etc/pure-ftpd/db/mysql.conf.orig ]] || mv /etc/pure-ftpd/db/mysql.conf /etc/pure-ftpd/db/mysql.conf.orig
cp -f "$scriptdir"/confs/pftpd.mysql.conf /etc/pure-ftpd/db/mysql.conf
sed -i "/MYSQLUser/{s/\$/\nMYSQLPassword\t$ftpdbpass/}" /etc/pure-ftpd/db/mysql.conf
chmod 600 /etc/pure-ftpd/db/mysql.conf
okay

step "Configuring pure-ftpd"
echo "yes" > /etc/pure-ftpd/conf/ChrootEveryone					# lock users into their webroot
echo "yes" > /etc/pure-ftpd/conf/CreateHomeDir					# create the homedir on first login
echo "yes" > /etc/pure-ftpd/conf/DontResolve					# optimize by disabling hostname lookup
echo "33" > /etc/pure-ftpd/conf/MinUID						# minimum uid, www-data
echo "1" > /etc/pure-ftpd/conf/TLS						# enable TLS
echo "$passiveports" > /etc/pure-ftpd/conf/PassivePortRange			# set passive ports
curl -s ipinfo.io/ip > /etc/pure-ftpd/conf/ForcePassiveIP			# set passive IP

sed -i "/NoAnonymous/c\\NoAnonymous		yes" /etc/pure-ftpd/pure-ftpd.conf
sed -i "/MaxIdleTime/c\\MaxIdleTime		5" /etc/pure-ftpd/pure-ftpd.conf
okay

# Install the TLS certificate, pure-ftpd wants one concatenated pem
step "Installing the ftp certificate"

if [[ -d /etc/letsencrypt/live/$hostname ]]; then
	mkdir -p /etc/ssl/private
	cat /etc/letsencrypt/live/"$hostname"/fullchain.pem \
	    /etc/letsencrypt/live/"$hostname"/privkey.pem > /etc/ssl/private/pure-ftpd.pem
	chmod 600 /etc/ssl/private/pure-ftpd.pem
	okay
else
	skip										# certbot has not run yet, its renewal hook will fill this in
fi

# Configure pure-ftpd logging
step "Splitting the ftp log out of syslog"
mkdir -p /var/log/pure-ftpd
printf '# Log kernel generated FTP log to file\n:syslogtag, isequal, "pure-ftpd:" /var/log/pure-ftpd/pure-ftpd.log\n\n# Do not log messages to syslog\n& stop\n' > /etc/rsyslog.d/23-pftpd.conf
chown root:syslog /var/log/pure-ftpd
chmod 0770 /var/log/pure-ftpd
systemctl restart rsyslog >>"$clklog" 2>&1
okay

# logrotate ftp logs
step "Installing the ftp logrotate"
cat > /etc/logrotate.d/pure-ftpd <<'LREOF'
/var/log/pure-ftpd/pure-ftpd.log {
	weekly
	missingok
	rotate 7
	compress
	delaycompress
	postrotate
		/usr/sbin/pure-ftpd-control restart >/dev/null
	endscript
	notifempty
}
LREOF
okay

step "Restarting pure-ftpd"
makespin "systemctl restart pure-ftpd-mysql"

profile_set pftpd 1
profile_set ftp_uid "$ftpuid"

curson

echo -e "${bgrn}   pure-ftpd complete!${cln}\n"
