#!/bin/bash
#
# clk-nixinit :: hosting
# Per-domain lifecycle tooling for a hosting stack: entld, distld, passtld,
# ngxentld and the shared lampstart. Installed on LAMP and LEMP boxes alike.
#
# usage: make-hosting.sh

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
logstart "hosting"


##
# Script
##

banner "Hosting tools"
cursoff

for tool in entld distld passtld ngxentld lampstart; do

	step "Installing $tool"
	install -m 0755 "$scriptdir"/scripts/"$tool" /usr/sbin/"$tool" || fail
	okay
done

profile_set hosting_tools 1

curson

echo -e "${bgrn}   Hosting tools complete!${cln}\n"
