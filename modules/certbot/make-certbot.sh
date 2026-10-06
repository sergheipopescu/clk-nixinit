#!/bin/bash
#
# clk-nixinit :: certbot
# Let's Encrypt through the nginx plugin, plus the post-renewal hook that
# rebuilds the pure-ftpd pem and reloads the stack.
#
# On a LAMP/LEMP box this also requests a certificate for the server's own
# hostname, because postfix and pure-ftpd both consume it. A proxy box runs
# neither -- nothing there consumes a hostname certificate, and there is no
# vhost to request one against until entld.ngx makes one for a real proxied
# domain -- so there the package and the renewal hook are all that install.
#
# usage: make-certbot.sh [hostname-cert|pkg-only]

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
logstart "certbot"

mode=${1:-hostname-cert}								# hostname-cert | pkg-only
hostname=$(hostname)									# certificate subject
certmail=$(cfg cert_email "postmaster@$hostname")					# registration address

case "$mode" in
	hostname-cert|pkg-only)	: ;;
	*)				echo -e "\n ${bred}Unknown certbot mode: $mode${cln}\n"; exit 1 ;;
esac


##
# Script
##

banner "Let's Encrypt"
cursoff

step "Installing certbot"
makespin "apt_install python3-certbot-nginx"

if [[ $mode == hostname-cert ]]; then
	step "Requesting a certificate for $hostname"
	makespin "certbot certonly --nginx --non-interactive --agree-tos --quiet -m '$certmail' -d '$hostname'"
fi

# Install the post renew hook
step "Installing the post-renewal hook"
mkdir -p /etc/letsencrypt/renewal-hooks/post

cat > /etc/letsencrypt/renewal-hooks/post/clk.restack.sh <<'HOOKEOF'
#!/bin/bash
#
# Rebuild anything that consumes a renewed certificate, then reload the stack

hostname=$(hostname)

if [ -d /etc/pure-ftpd ]; then								# pure-ftpd wants one concatenated pem
	cat /etc/letsencrypt/live/"$hostname"/fullchain.pem \
	    /etc/letsencrypt/live/"$hostname"/privkey.pem > /etc/ssl/private/pure-ftpd.pem
	chmod 600 /etc/ssl/private/pure-ftpd.pem
fi

lampstart
HOOKEOF

chmod +x /etc/letsencrypt/renewal-hooks/post/clk.restack.sh
okay

profile_set certbot 1
profile_set cert_email "$certmail"

curson

echo -e "${bgrn}   Let's Encrypt complete!${cln}\n"
