#!/bin/bash
# shellcheck shell=bash
#
# clk-nixinit shared library
# Sourced by the wrapper and by every module's entrypoint script, so that any
# module can also be run on its own without the wrapper.

[[ -n "${clkcommon:-}" ]] && return 0							# guard against double sourcing
clkcommon=1

set -a											# export all variables


##
# Paths
##

clkroot=/etc/clickwork									# clickwork state directory
clkprofile=$clkroot/nixinit.conf							# non-secret install profile
clksalt=/root/salt									# credential ledger, legacy format
clklogdir=/var/log/clickwork								# installer log directory
clklog=$clklogdir/nixinit.log								# installer log file


##
# Colours
##

cln=$(echo -en '\033[0m')
red=$(echo -en '\033[0;31m')
grn=$(echo -en '\033[32m')
ylw=$(echo -en '\033[33m')
# shellcheck disable=SC2034
blu=$(echo -en '\033[1;34m')
cyn=$(echo -en '\033[36m')
# shellcheck disable=SC2034
bgrn=$(echo -en '\033[1;32m')
bred=$(echo -en '\033[1;91m')


##
# Progress reporting
##

step() {

	local msg="$1"									# message to print
	local pad="................................................."			# dot filler

	printf '%s %s   ' "$msg" "${pad:${#msg}}"					# print message padded to a fixed width
}

okay() {

	echo -e "\b\b[${grn} OK ${cln}]\n"						# print okay, backspaces eat the spinner
}

skip() {

	echo -e "\b\b[${ylw}SKIP${cln}]\n"						# print skipped
}

warn() {

	echo -e "\b\b[${ylw}WARN${cln}]\n"						# print warning, keep going
}

fail() {

	echo -e "\b\b[${bred}FAIL${cln}]\n"						# print fail

	if [[ -s $clklog ]]; then							# if anything was logged
		echo -e "${red}last lines of $clklog:${cln}\n"
		tail -n 15 "$clklog"
		echo
	fi

	tput cnorm 2>/dev/null								# restore the cursor before dying
	exit 1
}

spinframes='/-\|'									# frames, cycled in place
spinfd=											# fd backing the fork free tick
spinpid=										# running spinner, if any

# Hold both ends of a fifo open so a read on it never sees EOF and always waits
# out its full timeout. That turns a tick into a pure builtin: one setup fork
# for the whole run, instead of a sleep(1) process ten times a second.
spinopen() {

	local fifo
	fifo=$(mktemp -u) || return 1
	mkfifo "$fifo" 2>/dev/null || return 1
	{ exec {spinfd}<>"$fifo"; } 2>/dev/null || { rm -f "$fifo"; return 1; }	# braces keep the 2>/dev/null from sticking to the whole shell
	rm -f "$fifo"									# unlinked, our own fd keeps it alive
}

spinopen || spinfd=									# no fifo, spintick falls back to sleep

spintick() {

	if [[ -n $spinfd ]]; then
		# shellcheck disable=SC2034  # spindump is a throwaway, the read only exists to wait
		read -r -t 0.1 -u "$spinfd" spindump 2>/dev/null || :			# always times out, reads nothing
	else
		sleep 0.1								# fallback, one fork per tick
	fi
}

spinny() {

	trap - EXIT INT TERM								# the child must never run the cleanup trap

	local i=0 n=${#spinframes}

	while :; do

		printf '%s\b' "${spinframes:i++%n:1}"
		spintick
	done
}

spinstart() {

	[[ ${clkverbose:-0} == 1 ]] && return 0						# nothing to animate in verbose mode

	spinny &
	spinpid=$!
}

spinstop() {

	[[ -n $spinpid ]] || return 0							# nothing running

	kill "$spinpid" 2>/dev/null
	wait "$spinpid" 2>/dev/null
	spinpid=
}

# Run a command behind the spinner, logging everything. The first argument says
# what a non-zero exit means: fail aborts the run, warn carries on.
runspin() {

	local onfail=$1 rc
	shift

	if [[ ${clkverbose:-0} == 1 ]]; then						# verbose mode, no spinner, no hiding
		echo
		eval "$*" 2>&1 | tee -a "$clklog"
		rc=${PIPESTATUS[0]}							# tee's status is not the command's
	else
		spinstart
		eval "$*" >>"$clklog" 2>&1
		rc=$?
		spinstop
	fi

	if [[ $rc -eq 0 ]]; then
		okay
	else
		"$onfail"
	fi
}

# Run a command quietly behind a spinner, logging everything, dying on failure
makespin() {

	runspin fail "$@"
}

# Same as makespin but a failure only warns, for optional packages
makespin_soft() {

	runspin warn "$@"
}

banner() {

	echo "${cyn}"
	echo "		##############################################"
	printf '		##  %-40s##\n' "$1"
	echo "		##############################################"
	echo "${cln}"
	echo
}

cursoff() {

	tput civis 2>/dev/null								# hide the cursor while a module runs
}

curson() {

	tput cnorm 2>/dev/null								# give the cursor back
}

# However the run ends, never leave a spinner animating or the cursor hidden
trap 'spinstop; curson' EXIT
trap 'spinstop; curson; exit 130' INT TERM


##
# Environment checks
##

need_root() {

	if [[ $EUID -ne 0 ]]; then
		echo -e "\n ${bred}This script must run as root${cln}\n"
		exit 1
	fi
}

# Ubuntu release codename, the admin username is derived from it
distro_codename() {

	# shellcheck disable=SC1091
	. /etc/os-release && echo "${VERSION_CODENAME:-resolute}"
}

distro_version() {

	# shellcheck disable=SC1091
	. /etc/os-release && echo "${VERSION_ID:-26.04}"
}

# kvm | microsoft | vmware | none | ...
detect_virt() {

	systemd-detect-virt 2>/dev/null || echo none
}

# Friendly hypervisor label for the summary output
virt_label() {

	case "$(detect_virt)" in
		kvm|qemu)	echo "KVM" ;;
		microsoft)	echo "Hyper-V" ;;
		none)		echo "bare metal" ;;
		*)		detect_virt ;;
	esac
}


##
# Install profile - non-secret state shared between modules and day-2 tools
##

profile_init() {

	mkdir -p "$clkroot"
	[[ -f $clkprofile ]] || echo "# clk-nixinit install profile" > "$clkprofile"
	chmod 0644 "$clkprofile"
}

profile_set() {

	profile_init
	sed -i "/^$1=/d" "$clkprofile"							# drop any previous value
	echo "$1=\"$2\"" >> "$clkprofile"						# write the new one
}

profile_get() {

	[[ -f $clkprofile ]] || { echo "${2:-}"; return 0; }
	local val
	val=$(sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$clkprofile" | tail -n 1)
	echo "${val:-${2:-}}"
}

# Append a value to a space separated profile list, ignoring duplicates
profile_add() {

	local cur
	cur=$(profile_get "$1")
	for item in $cur; do [[ $item == "$2" ]] && return 0; done
	profile_set "$1" "$(echo "$cur $2" | xargs)"
}


##
# Configuration resolution: CLK_<KEY> environment  >  profile file  >  default
##

cfg() {

	local key=$1 def=${2:-} envkey
	envkey="CLK_$(echo "$key" | tr '[:lower:]' '[:upper:]')"

	if [[ -n ${!envkey:-} ]]; then
		echo "${!envkey}"
	else
		profile_get "$key" "$def"
	fi
}


##
# Credential ledger - /root/salt, legacy format, day-2 tools grep it
##

salt_add() {

	touch "$clksalt"; chmod 600 "$clksalt"
	echo -e "$1:\t$2" | tee --append "$clksalt" > /dev/null				# label already carries its own wording
}

# Recover the MariaDB root password the way every day-2 script does
salt_mdbpass() {

	grep -oP "mariaDB password is:\s+\K\w+" "$clksalt"
}


##
# Helpers
##

# Random password of the given length, printable, no slashes
genpw() {

	openssl rand -base64 29 | tr -d "/" | cut -c1-"${1:-20}"
}

apt_install() {

	DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# Is a package installed and configured
have_pkg() {

	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

have_cmd() {

	command -v "$1" &>/dev/null
}

# Ask a yes/no question, honouring non-interactive mode
confirm() {

	local prompt=$1 def=${2:-Y} reply

	if [[ ${clkyes:-0} == 1 || ! -t 0 ]]; then					# no tty or -y given, take the default
		[[ $def =~ ^[Yy] ]] && return 0 || return 1
	fi

	read -r -n 1 -p "	$prompt [$def] ${grn}>${cln} " reply
	echo
	reply=${reply:-$def}
	[[ $reply =~ ^[Yy] ]]
}

logstart() {

	mkdir -p "$clklogdir"; chmod 0750 "$clklogdir"
	echo -e "\n===== $(date '+%F %T')  $* =====" >> "$clklog"
	chmod 0640 "$clklog"
}
