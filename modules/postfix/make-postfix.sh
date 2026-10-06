#!/bin/bash
#
# clk-nixinit :: postfix
# Outbound mail only. Listens on localhost, never accepts mail from the
# network, and never will -- so there is no local certificate to present and
# nothing to request one from certbot for. Mandatory: every role gets it, so
# alerts (lfd, cron, this installer's own log) always have somewhere to go,
# even on a bare `core` box or a proxy that never installs nginx or certbot.
#
# usage: make-postfix.sh

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
logstart "postfix"

hostname=$(hostname)									# mailname


##
# Script
##

banner "Postfix"
cursoff

# Preseed the answers so the package never opens its own dialog
step "Installing postfix"
debconf-set-selections <<< "postfix postfix/mailname string $hostname"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
makespin "apt_install postfix"

# Modify listening ports
step "Binding postfix to localhost"
sed -i "/inet_interfaces/c\\inet_interfaces = localhost" /etc/postfix/main.cf
okay

# Outbound TLS. This box only ever submits mail, it never receives any, so
# smtpd (the receiving side) has no external connection to ever present a
# certificate to -- there is nothing here for certbot to have provided even
# if it ran. Opportunistic client TLS needs no certificate of its own either:
# it only validates the REMOTE server's certificate, against the system CA
# bundle, so this is identical whether nginx and certbot exist on this box or
# not. "may" upgrades to TLS whenever the far end offers it and falls back to
# plain text otherwise, which matters for direct-to-MX delivery -- requiring
# TLS outright would queue alerts indefinitely against any recipient that
# doesn't speak it.
step "Enabling opportunistic TLS for outbound mail"

set_or_append() {

	local pattern=$1 line=$2

	if grep -q "^$pattern" /etc/postfix/main.cf; then
		sed -i "/^$pattern/c\\$line" /etc/postfix/main.cf
	else
		echo "$line" >> /etc/postfix/main.cf
	fi
}

set_or_append 'smtp_tls_security_level' 'smtp_tls_security_level = may'
set_or_append 'smtp_tls_loglevel' 'smtp_tls_loglevel = 1'
okay

# Modify postfix logging
step "Moving the postfix log"
mkdir -p /var/log/postfix
postconf maillog_file=/var/log/postfix/mail.log >>"$clklog" 2>&1
okay

# logrotate postfix logs
step "Installing the postfix logrotate"
cat > /etc/logrotate.d/postfix <<'LREOF'
/var/log/postfix/*.log {
	daily
	missingok
	rotate 30
	compress
	delaycompress
	notifempty
	create 640 root adm
	dateext
}
LREOF
okay

step "Restarting postfix"
makespin "systemctl restart postfix"

profile_set postfix 1

curson

echo -e "${bgrn}   Postfix complete!${cln}\n"
