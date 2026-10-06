#!/bin/bash
#
# clk-nixinit :: csf
# Removes ufw, installs and locks down CSF/LFD, splits the firewall messages out
# of syslog and installs the clkcsf and krnlcln helpers.
# Mandatory module.
#
# usage: make-csf.sh

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
logstart "csf"

# shellcheck disable=SC2034  # consumed by envsubst further down
adminuser=$(cfg admin_user "$(distro_codename)")					# admin user to whitelist in lfd
sshport=$(cfg ssh_port 2282)								# ssh listening port
role=$(cfg role lamp)									# role decides which ports to open
alertmail=$(cfg alert_email "alerts@clickwork.ro")					# lfd alert recipient
csfurl=$(cfg csf_url "https://clickwork.ro/.down/csf.tgz")				# csf tarball source

case "$role" in										# open only what the role actually serves
	lamp|lemp)	tcpin_def="21,80,443,$sshport,40001:40128" ;;			# http, https, ftp and the passive range
	proxy)		tcpin_def="80,443,$sshport" ;;					# a proxy terminates http/https only
	*)		tcpin_def="$sshport" ;;						# core only, ssh and nothing else
esac

tcpin=$(cfg tcp_in "$tcpin_def")							# incoming tcp ports
tcpout=$(cfg tcp_out "20,21,25,53,80,113,443,$sshport,11371")				# outgoing tcp ports
udpout=$(cfg udp_out "20,21,53,113,123")						# outgoing udp ports


##
# Script
##

banner "Firewall"
cursoff

# Uninstall ufw, csf takes over the iptables ruleset
step "Removing ufw"
makespin_soft "apt-get remove ufw -y"

# Download & install CSF
step "Downloading CSF"
cd /opt || { echo "Unable to change directory"; exit 1; }
makespin "wget -O /opt/csf.tgz '$csfurl' && tar xzf /opt/csf.tgz -C /opt"

step "Installing CSF"
cd /opt/csf || { echo "Unable to change directory"; exit 1; }
makespin "./install.sh"

# Temporarily disable the firewall so it can't lock us out mid install
step "Disabling the firewall while we configure it"
makespin "csf -x"

hostname=$(hostname)


###################
## Configure CSF ##
###################

step "Configuring CSF"

sed -i 's|TESTING = "1"|TESTING = "0"|' /etc/csf/csf.conf
sed -i "/^TCP_IN =/c\\TCP_IN = \"$tcpin\"" /etc/csf/csf.conf
sed -i "/^TCP_OUT =/c\\TCP_OUT = \"$tcpout\"" /etc/csf/csf.conf
sed -i '/^UDP_IN =/c\UDP_IN = ""' /etc/csf/csf.conf
sed -i "/^UDP_OUT =/c\\UDP_OUT = \"$udpout\"" /etc/csf/csf.conf

# IPv6 on, but no v6 ports open
sed -i 's|IPV6 = "0"|IPV6 = "1"|' /etc/csf/csf.conf
sed -i '/^TCP6_IN =/c\TCP6_IN = ""' /etc/csf/csf.conf
sed -i '/^TCP6_OUT =/c\TCP6_OUT = ""' /etc/csf/csf.conf
sed -i '/^UDP6_IN =/c\UDP6_IN = ""' /etc/csf/csf.conf
sed -i '/^UDP6_OUT =/c\UDP6_OUT = ""' /etc/csf/csf.conf

# lfd alerting
sed -i "/^LF_ALERT_TO =/c\\LF_ALERT_TO = \"$alertmail\"" /etc/csf/csf.conf
sed -i "/^LF_ALERT_FROM =/c\\LF_ALERT_FROM = \"lfd@$hostname\"" /etc/csf/csf.conf

# Logging and port scan tracking
sed -i 's|RESTRICT_SYSLOG = "0"|RESTRICT_SYSLOG = "2"|' /etc/csf/csf.conf
sed -i 's|PS_INTERVAL = "0"|PS_INTERVAL = "60"|' /etc/csf/csf.conf
sed -i 's|PS_LIMIT = "10"|PS_LIMIT = "6"|' /etc/csf/csf.conf
sed -i 's|PS_PORTS = "0:65535,ICMP"|PS_PORTS = "0:65535,ICMP,BRD"|' /etc/csf/csf.conf
sed -i 's|IPTABLES_LOG = "/var/log/messages"|IPTABLES_LOG = "/var/log/syslog"|' /etc/csf/csf.conf
sed -i 's|SYSLOG_LOG = "/var/log/messages"|SYSLOG_LOG = "/var/log/syslog"|' /etc/csf/csf.conf
sed -i 's|LF_FTPD = "10"|LF_FTPD = "3"|' /etc/csf/csf.conf
sed -i 's|FTPD_LOG = "/var/log/messages"|FTPD_LOG = "/var/log/pure-ftpd/pure-ftpd.log"|' /etc/csf/csf.conf
okay

# Whitelist gateway ip address
step "Whitelisting the gateway"
ip route show | grep -i 'default via' | awk '{print $3}' | tee --append /etc/csf/csf.ignore >/dev/null
okay

# Configure CSF/LFD exclusions
step "Installing lfd process exclusions"
# shellcheck disable=SC2016  # envsubst wants the literal placeholder name
< "$scriptdir"/snips/csf.pignore.snip envsubst '$adminuser' >> /etc/csf/csf.pignore	# substitute the admin username
okay


#############
## Logging ##
#############

# Copy firewall messages from syslog to a firewall logfile
step "Splitting firewall messages out of syslog"
mkdir -p /var/log/csf
touch /var/log/csf/csf.fw.log
chmod 640 /var/log/csf/csf.fw.log
chown syslog:adm /var/log/csf/csf.fw.log
printf '# Log kernel generated firewall log to file\n:msg,contains,"Firewall:" /var/log/csf/csf.fw.log\n' > /etc/rsyslog.d/22-firewall.conf
systemctl restart rsyslog >>"$clklog" 2>&1
okay

# logrotate firewall logs
step "Installing firewall logrotate"
cat > /etc/logrotate.d/csf <<'LREOF'
/var/log/csf/*.log {
	daily
	missingok
	rotate 30
	compress
	delaycompress
	notifempty
	create 640 syslog adm
	dateext
}
LREOF
okay


#############
## Helpers ##
#############

step "Installing clkcsf"
install -m 0755 "$scriptdir"/scripts/clkcsf /usr/sbin/clkcsf
okay

step "Installing krnlcln"
install -m 0755 "$scriptdir"/scripts/krnlcln /usr/sbin/krnlcln
okay

profile_set tcp_in "$tcpin"
profile_set tcp_out "$tcpout"

# The wrapper keeps the firewall down until the whole run is finished, a
# standalone run has nothing else coming so it brings the firewall straight back
if [[ $(cfg fw_defer 0) == 1 ]]; then
	step "Leaving the firewall disabled for the rest of the run"
	skip
else
	step "Enabling the firewall"
	makespin "csf -e"
fi

curson

echo -e "${bgrn}   Firewall complete!${cln}\n"
