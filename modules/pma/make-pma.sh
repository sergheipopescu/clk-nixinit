#!/bin/bash
# shellcheck disable=SC2016  # the phpMyAdmin config is php, its $cfg must stay literal
#
# clk-nixinit :: pma
# phpMyAdmin under /php.MA, restricted to the HQ allowlist. Needs MariaDB and a
# web server already in place.
#
# usage: make-pma.sh

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
logstart "pma"

# shellcheck disable=SC2034  # consumed by envsubst further down
hqips=$(cfg hq_ips "82.77.232.163")							# allowlist for the pma directory
mdbadmin=$(cfg mariadb_admin mariadmin)							# mariadb superuser
pmasrc=$(cfg pma_url "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-english.tar.gz")
pmacfg=/usr/share/phpmyadmin/config.inc.php

mdbpass=$(salt_mdbpass)									# get MariaDB root password

[[ -n $mdbpass ]] || { echo -e "\n ${bred}No MariaDB password in $clksalt${cln}\n"; exit 1; }


##
# Script
##

banner "phpMyAdmin"
cursoff

step "Downloading phpMyAdmin"
cd /opt || { echo "Unable to change directory"; exit 1; }
makespin "wget -q -O /opt/phpMyAdmin.tar.gz '$pmasrc' && tar xf /opt/phpMyAdmin.tar.gz -C /opt"

step "Installing phpMyAdmin"
rm -f /opt/phpMyAdmin.tar.gz
rm -rf /usr/share/phpmyadmin
mv /opt/phpMyAdmin-* /usr/share/phpmyadmin
mkdir -p /var/lib/phpmyadmin/tmp
chown -R www-data:www-data /var/lib/phpmyadmin
mkdir -p /etc/phpmyadmin
cp /usr/share/phpmyadmin/config.sample.inc.php "$pmacfg"
okay

# Set pma db password and blowfish secret
step "Generating phpMyAdmin secrets"
pmadbpass=$(genpw 20)
salt_add "The pm--admin password is" "$pmadbpass"
pmabfish=$(openssl rand -base64 24)
salt_add "The phpMyAdmin blowfish is" "$pmabfish"
okay

# Customize phpMyAdmin
step "Customizing phpMyAdmin"
sed -i "/blowfish_secret/c\\\$cfg['blowfish_secret'] = '$pmabfish';" "$pmacfg"
sed -i "/controlhost/c\\\$cfg['Servers'][\$i]['controlhost'] = 'localhost';" "$pmacfg"
sed -i "/controluser/c\\\$cfg['Servers'][\$i]['controluser'] = 'pm--admin';" "$pmacfg"
sed -i "/controlpass/c\\\$cfg['Servers'][\$i]['controlpass'] = '$pmadbpass';" "$pmacfg"

# Uncomment the whole linked-tables schema block
for entry in pmadb bookmarktable relation table_info table_coords pdf_pages column_info \
	     history table_uiprefs tracking userconfig recent favorite users usergroups \
	     navigationhiding savedsearches central_columns designer_settings export_templates; do

	sed -i "/$entry/s/^...//" "$pmacfg"
done

sed -i "76i\\\$cfg['TempDir'] = '/var/lib/phpmyadmin/tmp';" "$pmacfg"
sed -i "/TempDir/{s/\$/\n\$cfg['ThemeDefault'] = 'metro';/}" "$pmacfg"
okay

# Import the linked-tables schema and create the control user
step "Creating the phpMyAdmin control user"
mariadb -u"$mdbadmin" -p"$mdbpass" < /usr/share/phpmyadmin/sql/create_tables.sql >>"$clklog" 2>&1 || fail

mariadb -u"$mdbadmin" -p"$mdbpass" >>"$clklog" 2>&1 <<SQLEOF || fail
GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'pm--admin'@'localhost' IDENTIFIED BY '$pmadbpass';
FLUSH PRIVILEGES;
SQLEOF
okay

# Publish it. Under apache through a conf-available drop-in, under nginx through
# the admin snippet the nginx module already rendered.
step "Publishing phpMyAdmin"

if have_cmd a2enconf; then
	< "$scriptdir"/confs/a2.pma.conf envsubst '$hqips' > /etc/apache2/conf-available/clk.a2.pma.conf
	a2enconf clk.a2.pma >>"$clklog" 2>&1
	okay
elif [[ -f /etc/nginx/snippets/clk.ngx.admin.snip ]]; then
	okay
else
	skip
fi

profile_set pma 1

curson

echo -e "${bgrn}   phpMyAdmin complete!${cln}\n"
