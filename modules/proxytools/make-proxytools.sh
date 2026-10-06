#!/bin/bash
#
# clk-nixinit :: proxytools
# Per-domain lifecycle tooling for a proxy: entld.ngx, entld.proxy,
# distld.proxy and the shared lampstart. entld.hpx ships with the haproxy
# module instead.
#
# usage: make-proxytools.sh

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
logstart "proxytools"


##
# Script
##

banner "Proxy tools"
cursoff

# entld.ngx only makes sense where nginx actually terminates traffic
if have_cmd nginx; then

	tools=(entld.ngx entld.proxy distld.proxy)
else
	tools=(entld.proxy distld.proxy)
fi

for tool in "${tools[@]}"; do

	step "Installing $tool"
	install -m 0755 "$scriptdir"/scripts/"$tool" /usr/sbin/"$tool" || fail
	okay
done

# lampstart is shared with the hosting module, one copy lives there
step "Installing lampstart"
install -m 0755 "$scriptdir"/../hosting/scripts/lampstart /usr/sbin/lampstart || fail
okay

profile_set proxy_tools 1

curson

echo -e "${bgrn}   Proxy tools complete!${cln}\n"
