#!/bin/bash
# shellcheck disable=SC2016  # envsubst wants the literal placeholder names
#
# clk-nixinit :: apache
# Apache as the LAMP application backend, bound to 127.0.0.1:9080 only and never
# exposed directly. nginx terminates TLS in front of it.
#
# usage: make-apache.sh

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
logstart "apache"

# shellcheck disable=SC2034  # consumed by envsubst further down
hqips=$(cfg hq_ips "82.77.232.163")							# allowlist for phpMyAdmin and the wildcard vhost
backendport=$(cfg backend_port 9080)							# loopback port apache listens on


##
# Script
##

banner "Apache"
cursoff

# Apache comes from the Ubuntu archive, no third party repo
step "Updating repositories"
makespin "apt-get update"

step "Installing apache"
makespin "apt_install apache2"

# Install the custom security and compression configuration
step "Installing custom configuration"
< "$scriptdir"/confs/a2.conf envsubst '$hqips' > /etc/apache2/conf-available/clk.a2.conf
cp -f "$scriptdir"/confs/a2.deflate.conf /etc/apache2/conf-available/clk.a2.deflate.conf
a2enconf clk.a2 clk.a2.deflate >>"$clklog" 2>&1
okay

# Enable and disable modules
step "Configuring apache modules"
a2enmod alias rewrite headers deflate >>"$clklog" 2>&1
a2dismod status autoindex -f >>"$clklog" 2>&1
okay

## Security tweaks ##
step "Applying security tweaks"
sed -i 's|ServerTokens OS|ServerTokens Prod|' /etc/apache2/conf-enabled/security.conf
sed -i 's|ServerSignature On|ServerSignature Off|' /etc/apache2/conf-enabled/security.conf
okay

## Apache optimization tweaks ##
step "Applying optimization tweaks"
sed -i 's|Timeout 300|Timeout 60|' /etc/apache2/apache2.conf
sed -i 's|KeepAliveTimeout 5|KeepAliveTimeout 3|' /etc/apache2/apache2.conf

# mpm-event replaces the shipped config wholesale, the original is kept alongside
[[ -f /etc/apache2/mods-available/mpm_event.conf.bak ]] ||
	mv /etc/apache2/mods-available/mpm_event.conf /etc/apache2/mods-available/mpm_event.conf.bak
cp -f "$scriptdir"/confs/a2.mpm_event.conf /etc/apache2/mods-available/mpm_event.conf
a2enmod mpm_event >>"$clklog" 2>&1
okay

# Change listening port and disable the default website
step "Binding apache to port $backendport"
[[ -f /etc/apache2/ports.conf.default ]] || mv /etc/apache2/ports.conf /etc/apache2/ports.conf.default
echo "Listen $backendport" > /etc/apache2/ports.conf
a2dissite 000-default >>"$clklog" 2>&1
rm -rf /var/www/html
okay

# Create the apache blackhole, anything that reaches the backend unrouted gets 403
step "Creating the apache blackhole"
< "$scriptdir"/blocks/a2.blackhole envsubst '$backendport' > /etc/apache2/sites-available/0-blackhole.conf
a2ensite 0-blackhole >>"$clklog" 2>&1
okay

# Define loghost logging format
step "Defining the loghost log format"

if ! grep -q "loghost" /etc/apache2/apache2.conf; then					# only ever append once
	{
		echo
		echo "# Define loghost logging format"
		echo 'LogFormat "%a %l %u %t \"%{Host}i\" \"%r\" %>s %O \"%{Referer}i\"" loghost'
	} >> /etc/apache2/apache2.conf
fi
okay

# Install the vhost templates entld renders from
step "Installing vhost templates"
mkdir -p /etc/apache2/vhosts
cp -f "$scriptdir"/blocks/a2.vhost "$scriptdir"/blocks/a2.whost "$scriptdir"/blocks/a2.phost /etc/apache2/vhosts/
okay

# Stop apache, lampstart brings the whole stack up once everything is in place
systemctl stop apache2 >>"$clklog" 2>&1

profile_add webserver apache
profile_set backend_port "$backendport"
profile_set hq_ips "$hqips"

curson

echo -e "${bgrn}   Apache complete!${cln}\n"
