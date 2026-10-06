#!/bin/bash
# shellcheck disable=SC2016  # envsubst wants the literal placeholder names
#
# clk-nixinit :: nginx
# nginx in one of three roles:
#
#   edge   - public TLS terminator in front of an apache backend (LAMP)
#   web    - the whole web tier, serving php-fpm directly (LEMP)
#   proxy  - TLS terminator in front of remote backends, optionally behind HAProxy
#
# usage: make-nginx.sh [edge|web|proxy]

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
logstart "nginx"

mode=${1:-$(cfg nginx_mode edge)}							# edge | web | proxy
# shellcheck disable=SC2034  # consumed by envsubst further down
hqips=$(cfg hq_ips "82.77.232.163")							# allowlist for the acl snippet
# shellcheck disable=SC2034  # consumed by envsubst further down
phpvrs=$(cfg php_default 8.4)								# fpm pool the admin tooling runs on
dhbits=$(cfg dhparam_bits 4096)								# dhparam size

case "$mode" in
	edge|web|proxy)	: ;;
	*)		echo -e "\n ${bred}Unknown nginx mode: $mode${cln}\n"; exit 1 ;;
esac


##
# Functions
##

# Hand TLS termination over to HAProxy: nginx stops owning 443 and listens on
# 9443 behind proxy_protocol instead. The templates carry both variants, one of
# them commented out, so this is a pure toggle.
nginx-backend() {

	local target

	for target in /etc/nginx/blocks/ngx.srvblock \
		      /etc/nginx/blocks/ngx.srwblock \
		      /etc/nginx/blocks/ngx.phpblock \
		      /etc/nginx/sites-available/blackhole; do

		[[ -f $target ]] || continue

		# comment out default port in srvblocks
		sed -i '/default SSL port/s/^\([^#]\)/#\1/' "$target"

		# comment in proxy port in srvblocks
		sed -i '/proxy SSL port/s/^#//' "$target"

		# comment in Real IP
		sed -i '/Set real IP/s/^#//' "$target"
		sed -i '/Real IP header/s/^#//' "$target"
	done
}


##
# Script
##

banner "nginx ($mode)"
cursoff

# nginx comes from the Ubuntu archive, no third party repo
step "Updating repositories"
makespin "apt-get update"

step "Installing nginx"
makespin "apt_install nginx"

# Security | Remove defaults
step "Removing defaults"
rm -f /etc/nginx/sites-enabled/default
rm -rf /var/www/html
okay

# Security | Create pem certificate for blackhole
step "Creating the blackhole certificate"
mkdir -p /etc/nginx/ssl
makespin "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /etc/nginx/ssl/blackhole.key -out /etc/nginx/ssl/blackhole.pem -sha256 -days 3650 -nodes -subj '/CN=Cyg X-1'"

# Security | Create and enable the blackhole, catching everything without SNI
step "Creating the blackhole"
cp -f "$scriptdir"/blocks/ngx.blackhole /etc/nginx/sites-available/blackhole
ln -sf /etc/nginx/sites-available/blackhole /etc/nginx/sites-enabled/blackhole
okay

# SSL | Create dhparam file
step "Creating the dhparam file"
makespin "openssl dhparam -dsaparam -out /etc/nginx/ssl/dhparam.pem $dhbits"

# SSL | Disable ssl protocols in default config, clk.ngx.conf sets them instead
step "Cleaning up the shipped config"
sed -i 's|^\tssl_protocols|#&|' /etc/nginx/nginx.conf
sed -i 's|^\tssl_prefer_server_ciphers|#&|' /etc/nginx/nginx.conf
okay

# Security | Install the custom conf, snippets and vhost templates
step "Installing custom configuration"
cp -f "$scriptdir"/confs/clk.ngx.conf /etc/nginx/conf.d/clk.ngx.conf

cp -f "$scriptdir"/snips/clk.ngx.acl.snip \
      "$scriptdir"/snips/clk.ngx.loghost.snip \
      "$scriptdir"/snips/clk.ngx.lognone.snip \
      "$scriptdir"/snips/clk.ngx.maps.snip /etc/nginx/snippets/

< "$scriptdir"/snips/clk.ngx.acl.IPs.snip envsubst '$hqips' > /etc/nginx/snippets/clk.ngx.acl.IPs.snip

mkdir -p /etc/nginx/blocks
cp -f "$scriptdir"/blocks/ngx.srvblock "$scriptdir"/blocks/ngx.srwblock \
      "$scriptdir"/blocks/ngx.phpblock "$scriptdir"/blocks/ngx.fwd80block /etc/nginx/blocks/

if [[ $mode == web ]]; then								# LEMP serves the admin tooling itself
	< "$scriptdir"/snips/clk.ngx.admin.snip envsubst '$phpvrs' > /etc/nginx/snippets/clk.ngx.admin.snip
fi
okay

# Logging | Enable loghost on default settings
step "Enabling loghost logging"
sed -i '/access_log/c\	include /etc/nginx/snippets/clk.ngx.loghost.snip;\n	access_log /var/log/nginx/access.log loghost;' /etc/nginx/nginx.conf
okay


######################################################
## Install and configure Bad Bot Blocker for nginx  ##
######################################################

step "Installing the Bad Bot Blocker"
makespin "wget -q https://raw.githubusercontent.com/mitchellkrogza/nginx-ultimate-bad-bot-blocker/master/install-ngxblocker -O /usr/local/sbin/install-ngxblocker && chmod +x /usr/local/sbin/install-ngxblocker && install-ngxblocker -x"

rm -f /usr/local/sbin/setup-ngxblocker						# the interactive setup would rewrite our vhosts

step "Scheduling the Bad Bot Blocker update"
if crontab -l 2>/dev/null | grep -q update-ngxblocker; then			# only ever schedule once
	skip
else
	crontab -l 2>/dev/null | { cat; echo "0 5 * * 6 /usr/local/sbin/update-ngxblocker >/dev/null 2>&1"; } | crontab -
	okay
fi


###################
## Mode wiring   ##
###################

case "$mode" in

	edge)	# nginx fronts apache, so apache has to read the forwarded client IP
		step "Wiring nginx in front of apache"
		if have_cmd a2enmod; then
			a2enmod remoteip >>"$clklog" 2>&1
			sed -i 's|LogFormat "%h|LogFormat "%a|' /etc/apache2/apache2.conf
			okay
		else
			skip
		fi
	;;

	proxy)	if have_cmd haproxy; then					# HAProxy owns 443, drop nginx to 9443
			step "Configuring the nginx backend"
			nginx-backend
			okay
		else
			curson
			echo
			if confirm "nginx streams are ${bred}[not]${cln} enabled. Enable now? [y/N]" N; then
				cursoff
				step "Installing the nginx stream module"
				makespin "apt_install libnginx-mod-stream"

				step "Configuring nginx streams"
				cp -f "$scriptdir"/confs/clk.streams.conf /etc/nginx/modules-available/clk.streams.conf
				ln -sf /etc/nginx/modules-available/clk.streams.conf /etc/nginx/modules-enabled/clk.streams.conf
				nginx-backend
				mkdir -p /var/log/nginx/streams
				okay
			fi
			cursoff
		fi
	;;

	web)	:								# LEMP needs no extra wiring, php-fpm is reached over its socket
	;;
esac

step "Testing the nginx configuration"
nginx -q -t >>"$clklog" 2>&1 || fail
okay

step "Restarting nginx"
makespin "systemctl restart nginx"

profile_add webserver nginx
profile_set nginx_mode "$mode"
profile_set hq_ips "$hqips"

curson

echo -e "${bgrn}   nginx complete!${cln}\n"
