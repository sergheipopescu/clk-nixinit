#!/bin/bash
#
# clk-nixinit
# Clickwork Ubuntu server provisioner.
#
# Runs two ways from the same entrypoint:
#
#   non-interactive - every choice comes from flags or CLK_* environment
#                     variables, for cloud-init where there is no tty
#   interactive     - run it with no role on a tty and it asks, for a
#                     hand-built Hyper-V box
#
# Every module under modules/ is also runnable on its own, without this wrapper.

# shellcheck disable=SC2034  # the CLK_ variables are exported to the modules by set -a

##
# Variables
##

set -a											# export all variables

rootdir=$(dirname "$(realpath "$0")")							# set project root directory
moddir=$rootdir/modules									# module directory

# shellcheck source=lib/common.sh
. "$rootdir"/lib/common.sh

version=1.0-alpha1


##
# Functions
##

usage() {

	cat <<'USAGEEOF'

  clk-nixinit - Clickwork Ubuntu server provisioner

  usage: clk-nixinit.sh [options]

  Options:
    -r, --role <role>        what to build, see the role list below (default core)
    -f, --fqdn <fqdn>        server hostname fqdn
    -p, --php <list>         php versions, comma separated (default latest)
                             "latest" resolves to the newest the repo offers;
                             the highest one becomes the default fpm pool
    -u, --user <name>        admin username (default: the release codename)
    -t, --timezone <tz>      server timezone (default Europe/Bucharest)
    -g, --github-user <name> authorize this github account's public keys for
                             root and the admin user
        --hq-ip <ip[,ip]>    allowlist for phpMyAdmin and the wildcard tools
        --alert-email <addr> lfd alert recipient
        --cert-email <addr>  certbot registration address
        --cleanup            remove the project directory when finished
                             (left in place unless this is given)
        --no-reboot          do not reboot when finished (default: reboot)
    -y, --yes                assume yes, never prompt (implied without a tty)
    -v, --verbose            show command output instead of a spinner
    -l, --list               list the modules and exit
    -h, --help               this help

  Roles:
    min                      Customization only, removes ufw; no csf, no postfix
    core                    Customization, firewall and outbound mail only
                             (the default when no role is given)
    lamp                     LAMP + nginx front end (apache, mariadb, php, pma)
    lemp                     LEMP (nginx only, serving php-fpm directly, mariadb, pma)
    proxy                    Reverse proxy, nginx + HAProxy

  Every option also reads a CLK_ environment variable, so cloud-init can set
  CLK_ROLE, CLK_FQDN, CLK_PHP, CLK_ADMIN_USER, CLK_TIMEZONE, CLK_HQ_IPS,
  CLK_ALERT_EMAIL, CLK_CERT_EMAIL, CLK_GITHUB_USER, CLK_CLEANUP, CLK_REBOOT
  and CLK_YES.

  Examples:
    clk-nixinit.sh                                    # interactive
    clk-nixinit.sh -r lamp -f vps1.example.ro -p 8.5,7.4
    clk-nixinit.sh -r proxy -f edge1.example.ro -y --cleanup
    clk-nixinit.sh -r core -f box1.example.ro -y --no-reboot
    clk-nixinit.sh -r min -f box2.example.ro -g mygithub -y

USAGEEOF
}

# Every module's entrypoint follows make-<name>.sh, except customize (just
# customize.sh, it's not building anything) and the three whose module id
# was shortened from its old full name: csf, pma, pftpd.
module_script() {

	case "$1" in

		customize)	echo customize.sh ;;
		csf)		echo make-csf.sh ;;
		pma)		echo make-pma.sh ;;
		pftpd)		echo make-pftpd.sh ;;
		mariadbkp)	echo make-mdbkp.sh ;;
		apache|certbot|haproxy|hosting|mariadb|nginx|php|postfix|proxytools|wildcard)
				echo "make-$1.sh" ;;
		*)		return 1 ;;
	esac
}

list_modules() {

	echo
	echo "  Modules, each runnable on its own as modules/<name>/<script>:"
	echo

	for dir in "$moddir"/*/; do

		local mod script
		mod=$(basename "$dir")
		script=$(module_script "$mod") || continue
		[[ -x $dir$script ]] || continue

		# the line right after the "clk-nixinit :: <name>" header is the description
		printf '    %-14s %-16s %s\n' "$mod" "$script" \
			"$(sed -n '/^# clk-nixinit ::/{n;s/^# //p;q;}' "$dir$script")"
	done

	echo
}

# The module sequence for a role. Order is a dependency order, not a preference:
# apache before php because php wires itself into apache, php before nginx on a
# LEMP box because the nginx admin snippet renders against the default fpm pool.
# postfix is not listed here -- it is mandatory for every role, run alongside
# customize and csf, so alerts always have somewhere to go regardless of role.
role_modules() {

	case "$1" in

		lamp)		echo "apache mariadb php pma wildcard nginx certbot pftpd hosting" ;;
		lemp)		echo "mariadb php nginx certbot pma wildcard pftpd hosting" ;;
		proxy)		echo "haproxy nginx certbot proxytools" ;;
		core|min)	echo "" ;;
		*)		return 1 ;;
	esac
}

# nginx wears a different hat per role
role_nginx_mode() {

	case "$1" in

		lamp)		echo edge ;;
		lemp)		echo web ;;
		proxy)		echo proxy ;;
		*)		echo edge ;;
	esac
}

run_module() {

	local mod=$1 arg=${2:-} script

	script=$(module_script "$mod") || { echo -e "\n ${bred}No such module: $mod${cln}\n"; exit 1; }
	[[ -x $moddir/$mod/$script ]] || { echo -e "\n ${bred}No such module: $mod${cln}\n"; exit 1; }

	bash "$moddir/$mod/$script" "$arg" || exit 1
}

ask_role() {

	echo
	echo "	What should this server become?"
	echo
	echo "	0) ${grn}Min${cln}   - customization only, removes ufw, no firewall or mail"
	echo "	1) ${red}Core${cln}  - customization, firewall and outbound mail only"
	echo "	2) ${ylw}LAMP${cln}  - apache + mariadb + php, behind an ${grn}nginx${cln} front end"
	echo "	3) ${ylw}LEMP${cln}  - ${grn}nginx${cln} only, serving php-fpm directly + mariadb"
	echo "	4) ${cyn}Proxy${cln} - reverse proxy, ${grn}nginx${cln} + ${ylw}HAProxy${cln}"
	echo

	while :; do

		read -r -n 1 -p "	Please choose an option [1] ${grn}>${cln} " reply
		echo

		case "$reply" in

			0)	role=min	; break ;;
			''|1)	role=core	; break ;;			# bare Enter takes the default
			2)	role=lamp	; break ;;
			3)	role=lemp	; break ;;
			4)	role=proxy	; break ;;
			*)	echo -e "	${bred}Bad${cln} choice, try again\n" ;;
		esac
	done
}

ask_php() {

	echo
	echo "	Which php versions? Any combination, the highest becomes the default pool."
	echo
	echo "	  ${cyn}${phpoffer//,/   }${cln}    or ${cyn}latest${cln} for just the newest the repo has"
	echo

	read -r -p "	Versions, comma separated [$php] ${grn}>${cln} " reply
	php=${reply:-$php}
	echo
}


##
# Flags
##

role=${CLK_ROLE:-}
fqdn=${CLK_FQDN:-}
php=${CLK_PHP:-latest}									# resolved against the repo by the php module

# What the interactive prompt offers: the newest three of the 8 branch plus the
# last of the 7 branch. Only a menu -- any version the repo carries is accepted,
# and "latest" is resolved for real at install time, so this list going stale
# costs a prompt hint, never a wrong install.
phpoffer="8.5,8.4,8.3,7.4"
clkyes=${CLK_YES:-0}
clkverbose=${CLK_VERBOSE:-0}
docleanup=${CLK_CLEANUP:-0}								# left in place unless asked
doreboot=${CLK_REBOOT:-1}								# reboots unless told not to

while [[ $# -gt 0 ]]; do

	case "$1" in

		-r|--role)	role=$2			; shift 2 ;;
		-f|--fqdn)	fqdn=$2			; shift 2 ;;
		-p|--php)	php=$2			; shift 2 ;;
		-u|--user)	CLK_ADMIN_USER=$2	; shift 2 ;;
		-t|--timezone)	CLK_TIMEZONE=$2		; shift 2 ;;
		-g|--github-user)	CLK_GITHUB_USER=$2	; shift 2 ;;
		--hq-ip)	CLK_HQ_IPS=$2		; shift 2 ;;
		--alert-email)	CLK_ALERT_EMAIL=$2	; shift 2 ;;
		--cert-email)	CLK_CERT_EMAIL=$2	; shift 2 ;;
		--cleanup)	docleanup=1		; shift ;;
		--no-reboot)	doreboot=0		; shift ;;
		-y|--yes)	clkyes=1		; shift ;;
		-v|--verbose)	clkverbose=1		; shift ;;
		-l|--list)	list_modules		; exit 0 ;;
		-h|--help)	usage			; exit 0 ;;
		*)		echo -e "\n ${bred}Unknown option: $1${cln}\n"; usage; exit 1 ;;
	esac
done


##
# Script
##

need_root
logstart "wrapper $*"

clear											# clear the screen

echo "${cyn}"
echo "		##############################################"
echo "		##       Clickwork Ubuntu provisioner       ##"
printf '		##  %-40s##\n' "v$version  -  Ubuntu $(distro_version) on $(virt_label)"
echo "		##############################################"
echo "${cln}"

[[ -t 0 ]] || clkyes=1									# no tty, never prompt

# Hostname, the one thing the mandatory modules always need
if [[ -z $fqdn ]]; then

	if [[ $clkyes == 1 ]]; then
		echo -e "\n ${bred}No hostname given. Pass --fqdn or set CLK_FQDN${cln}\n"
		exit 1
	fi

	echo
	read -r -p "	Enter server hostname fqdn: ${cyn}" fqdn
	echo -e "${cln}"
fi

# Role. Nothing given and nobody to ask means core -- the safe floor, a box
# that is customized, firewalled and able to mail out, and nothing more.
if [[ -z $role ]]; then

	if [[ $clkyes == 1 ]]; then
		role=core
	else
		ask_role
	fi
fi

role_modules "$role" >/dev/null || { echo -e "\n ${bred}Unknown role: $role${cln}\n"; usage; exit 1; }

# php versions, only ever asked for a stack that runs php
case "$role" in
	lamp|lemp)	[[ $clkyes == 1 ]] || ask_php ;;
esac

# Everything the modules read is exported from here
CLK_FQDN=$fqdn
CLK_ROLE=$role
CLK_PHP=$php
CLK_NGINX_MODE=$(role_nginx_mode "$role")
CLK_FW_DEFER=1										# the firewall goes up at the very end

mapfile -t modules < <(role_modules "$role" | tr ' ' '\n' | sed '/^$/d')


##
# Confirm
##

echo
echo "	Hostname     ${cyn}$fqdn${cln}"
echo "	Role         ${cyn}$role${cln}"
echo "	Admin user   ${cyn}$(cfg admin_user "$(distro_codename)")${cln}"

case "$role" in
	lamp|lemp)	echo "	PHP          ${cyn}$php${cln}" ;;
esac

if [[ $role == min ]]; then
	echo "	Modules      ${cyn}customize (ufw removed)${cln}"
else
	echo "	Modules      ${cyn}customize csf postfix ${modules[*]}${cln}"
fi

echo "	When done    ${cyn}cleanup=$docleanup reboot=$doreboot${cln}"
echo

confirm "Proceed? [Y/n]" Y || { echo -e "\n	Aborted\n"; exit 0; }


##
# Mandatory modules
##

run_module customize "$fqdn"

if [[ $role == min ]]; then

	# Min stops here, no csf and no postfix, but ufw still has to go
	step "Removing ufw"
	makespin_soft "apt-get remove ufw -y"
else
	run_module csf
	run_module postfix
fi


##
# Optional modules
##

for mod in "${modules[@]}"; do

	case "$mod" in

		nginx)		run_module nginx "$CLK_NGINX_MODE" ;;
		php)		run_module php "$php" ;;
		certbot)	case "$role" in							# nothing on a proxy box consumes a hostname cert
					proxy)		run_module certbot pkg-only ;;
					*)		run_module certbot hostname-cert ;;
				esac
		;;
		*)		run_module "$mod" ;;
	esac
done


##
# Finish
##

# Sweep up whatever the modules and the ufw removal left orphaned
step "Removing unused packages"
makespin_soft "DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge"

profile_set role "$role"
profile_set installed_on "$(date '+%F %T')"

echo "${cyn}"
echo "		##############################################"
echo "		##                All done!                 ##"
echo "		##############################################"
echo "${cln}"
echo
echo "	Credentials    ${cyn}$clksalt${cln}"
echo "	Install log    ${cyn}$clklog${cln}"
echo "	Profile        ${cyn}$clkprofile${cln}"
echo "	ssh port       ${cyn}$(cfg ssh_port 2282)${cln}"
echo

case "$role" in
	lamp|lemp)	echo "	Add a domain   ${cyn}entld example.ro${cln}"
			echo "	Drop a domain  ${cyn}distld example.ro${cln}" ;;
	proxy)		echo "	Add a domain   ${cyn}entld.proxy -h${cln}" ;;
esac

if [[ $role != min ]]; then
	echo "	Reload stack   ${cyn}lampstart${cln}"
	echo "	Firewall       ${cyn}clkcsf -h${cln}"
fi

echo

# The firewall stayed down for the whole run, bring it up now (min never installed one)
if [[ $role != min ]]; then
	step "Enabling the firewall"
	makespin "csf -e"
fi

if [[ $docleanup == 1 ]]; then

	echo -e "	Removing ${cyn}$rootdir${cln}\n"
	rm -rf "$rootdir"
fi

if [[ $doreboot == 1 ]]; then

	echo -e "	${ylw}Rebooting ...${cln}\n"
	reboot
else
	echo -e "	${ylw}Reboot when ready:${cln} systemctl reboot\n"
fi
