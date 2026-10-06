#!/bin/bash
# shellcheck disable=SC2016  # envsubst wants the literal placeholder names
#
# clk-nixinit :: wildcard
# The /var/www/wildcard toolbox: phpinfo, a memcached probe and phpCacheAdmin,
# reachable from any vhost under /php.info, /php.cache and /php.CA, restricted to
# the HQ allowlist.
#
# usage: make-wildcard.sh

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
logstart "wildcard"

# shellcheck disable=SC2034  # consumed by envsubst further down
hqips=$(cfg hq_ips "82.77.232.163")							# allowlist for the wildcard directory
wildcard=/var/www/wildcard


##
# Script
##

banner "Wildcard toolbox"
cursoff

step "Creating the wildcard webroot"
mkdir -p "$wildcard"
cp -f "$scriptdir"/www/info.php "$wildcard"/info.php
cp -f "$scriptdir"/www/cache.php "$wildcard"/cache.php
okay

step "Installing phpCacheAdmin"
rm -rf "$wildcard"/phpCacheAdmin
makespin "git clone --depth 1 https://github.com/RobiNN1/phpCacheAdmin '$wildcard/phpCacheAdmin'"

step "Locking down the wildcard webroot"
rm -rf "$wildcard"/phpCacheAdmin/.git "$wildcard"/phpCacheAdmin/.github		# no vcs metadata under a webroot
find "$wildcard" -maxdepth 2 -name '.*' -not -name '.' -prune -exec rm -rf {} +

chown -R www-data "$wildcard"
chmod -R 0500 "$wildcard"
chmod -R 0700 "$wildcard"/phpCacheAdmin
find "$wildcard" -type f -print0 | xargs -0 chmod 400
okay

# Publish it. Under apache through a conf-available drop-in, under nginx through
# the admin snippet the nginx module already rendered.
step "Publishing the wildcard aliases"

if have_cmd a2enconf; then
	< "$scriptdir"/confs/a2.wildcard.conf envsubst '$hqips' > /etc/apache2/conf-available/wildcard.conf
	a2enconf wildcard >>"$clklog" 2>&1
	okay
elif [[ -f /etc/nginx/snippets/clk.ngx.admin.snip ]]; then
	okay
else
	skip
fi

profile_set wildcard 1

curson

echo -e "${bgrn}   Wildcard toolbox complete!${cln}\n"
