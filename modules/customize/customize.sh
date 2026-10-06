#!/bin/bash
#
# clk-nixinit :: customize
# Timezone, hostname, admin user, ssh hardening, motd and shell customization.
# Mandatory module. Runs first, everything after it keys off the admin user.
#
# usage: customize.sh [fqdn]
# set CLK_GITHUB_USER to authorize that github account's public keys for root and the admin user

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
logstart "customize"

fqdn=${1:-$(cfg fqdn)}									# server hostname fqdn
timezone=$(cfg timezone "Europe/Bucharest")						# server timezone
adminuser=$(cfg admin_user "$(distro_codename)")					# admin user, named after the release codename
gecos=$(cfg gecos "Clickwork IT Admin")							# admin user full name
sshport=$(cfg ssh_port 2282)								# ssh listening port
githubuser=$(cfg github_user sergheipopescu)							# github account whose public keys get authorized
brandline=$(cfg brand_line "                 Server maintained by \\033[01;34mClickwork\\033[37m|\\033[01;34mClockwork IT\\033[37m!")

if [[ -z $fqdn ]]; then									# no fqdn from flags, env or profile
	echo
	read -r -p "$(echo -e "	Enter server hostname fqdn: ${cyn}")" fqdn		# ask for hostname and read input
	echo -e "${cln}"
fi

[[ -n $fqdn ]] || { echo -e "\n ${bred}No hostname given${cln}\n"; exit 1; }


##
# Script
##

banner "Customization"
cursoff

profile_set fqdn "$fqdn"
profile_set timezone "$timezone"
profile_set admin_user "$adminuser"
profile_set ssh_port "$sshport"
profile_set hypervisor "$(detect_virt)"
profile_set codename "$(distro_codename)"
profile_set release "$(distro_version)"

echo "	Detected ${cyn}Ubuntu $(distro_version) ($(distro_codename))${cln} on ${cyn}$(virt_label)${cln}"
echo "	Admin user will be ${cyn}$adminuser${cln}"
echo

# Set timezone and 24h clock
step "Setting timezone and 24h clock"
makespin "timedatectl set-timezone '$timezone' && update-locale 'LC_TIME=\"C.UTF-8\"'"

# Set hostname
step "Setting hostname"
makespin "hostnamectl set-hostname '$fqdn'"


################
## Admin user ##
################

# On KVM the box is a bare cloud image and the user has to be created. On Hyper-V
# the installer already created it during setup, so we only adopt it here. Either
# way the name follows the release codename, and everything below keys off it.
step "Creating admin user $adminuser"

if id -u "$adminuser" &>/dev/null; then							# user already exists, adopt it
	skip
else
	makespin "adduser '$adminuser' --gecos '$gecos' --disabled-password"
fi

# Add user to the admin group
step "Granting sudo to $adminuser"
getent group admin >/dev/null || addgroup --system admin >>"$clklog" 2>&1		# create the admin group once
echo "%admin ALL=(ALL) ALL" > /etc/sudoers.d/clk-admin					# grant it sudo in its own drop-in
chmod 0440 /etc/sudoers.d/clk-admin
visudo -cf /etc/sudoers.d/clk-admin >>"$clklog" 2>&1 || fail				# never leave a broken sudoers behind
makespin "adduser '$adminuser' admin"

# Suppress the first login sudo hint the supported way
touch /home/"$adminuser"/.sudo_as_admin_successful
chown "$adminuser": /home/"$adminuser"/.sudo_as_admin_successful

# Copy root ssh key to user profile
step "Copying root ssh key to $adminuser"

if [[ -d /root/.ssh ]]; then
	mkdir -p /home/"$adminuser"/.ssh
	chmod 0700 /home/"$adminuser"/.ssh

	if [[ -f /root/.ssh/authorized_keys ]]; then					# merge instead of clobbering an existing key
		cat /root/.ssh/authorized_keys >> /home/"$adminuser"/.ssh/authorized_keys
		sort -u -o /home/"$adminuser"/.ssh/authorized_keys /home/"$adminuser"/.ssh/authorized_keys
		chmod 0600 /home/"$adminuser"/.ssh/authorized_keys
	fi

	chown -R "$adminuser": /home/"$adminuser"/.ssh
	okay
else
	skip
fi

# Pull the public keys published on github into root and the admin user
step "Fetching ssh keys from github"

if [[ -n $githubuser ]]; then
	ghkeys=$(mktemp)								# scratch file for the downloaded keys

	if wget -q -O "$ghkeys" "https://github.com/$githubuser.keys" && [[ -s $ghkeys ]]; then
		for keyhome in /root /home/"$adminuser"; do				# root and the sudo user

			mkdir -p "$keyhome"/.ssh
			chmod 0700 "$keyhome"/.ssh
			cat "$ghkeys" >> "$keyhome"/.ssh/authorized_keys
			sort -u -o "$keyhome"/.ssh/authorized_keys "$keyhome"/.ssh/authorized_keys	# no duplicate keys
			chmod 0600 "$keyhome"/.ssh/authorized_keys
		done

		chown -R "$adminuser": /home/"$adminuser"/.ssh
		rm -f "$ghkeys"
		okay
	else
		rm -f "$ghkeys"
		warn									# bad username or no network, keep going
	fi
else
	skip
fi


##############
## Packages ##
##############

step "Running update"
makespin "apt-get update"

step "Running upgrades"
makespin "DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=\"--force-confold\" upgrade"

step "Running dist-upgrade"
makespin "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y"

step "Installing base tooling"
makespin "apt_install mc nano libwww-perl haveged fortune-mod software-properties-common dirmngr apt-transport-https argon2 btop"

step "Installing landscape-common"
makespin_soft "apt-get --no-install-recommends -y install landscape-common"

# The Azure-tuned kernel carries Hyper-V integration drivers and only makes
# sense on Hyper-V. Installing it on KVM would be installing the wrong kernel.
step "Installing the Hyper-V kernel"

if [[ $(detect_virt) == microsoft ]]; then
	makespin_soft "apt_install linux-azure"
else
	skip
fi


###################
## ssh hardening ##
###################

step "Moving ssh to port $sshport"
sed -i "s|^#\?Port .*|Port $sshport|" /etc/ssh/sshd_config
grep -q "^Port $sshport\$" /etc/ssh/sshd_config || echo "Port $sshport" >> /etc/ssh/sshd_config	# no Port directive existed at all
okay

step "Hardening sshd"
sed -i 's|PasswordAuthentication no|PasswordAuthentication yes|' /etc/ssh/sshd_config	# allow password auth for the admin user
sed -i "/#MaxAuthTries/c\MaxAuthTries	3" /etc/ssh/sshd_config
sed -i 's|PermitRootLogin yes|PermitRootLogin prohibit-password|' /etc/ssh/sshd_config

if ! grep -q "^Match User root" /etc/ssh/sshd_config; then				# disable password auth for root only
	printf '\nMatch User root\n\tPasswordAuthentication no\n' >> /etc/ssh/sshd_config
fi

sshd -t >>"$clklog" 2>&1 || fail							# never leave a broken sshd_config behind
okay

# Apply it now rather than waiting on an optional reboot -- an already
# established session survives the restart, only new connections see the
# change, so this is the same operation admins run by hand to switch port.
step "Restarting ssh on port $sshport"
systemctl restart ssh >>"$clklog" 2>&1 || fail
ss -tln 2>/dev/null | grep -q ":$sshport " || fail					# must be listening on the new port
ss -tln 2>/dev/null | grep -q ':22 ' && fail						# and must not still be listening on 22
okay


##################
## motd cleanup ##
##################

step "Cleaning up the motd"

[[ -f /etc/default/motd-news ]] && sed -i 's|ENABLED=1|ENABLED=0|' /etc/default/motd-news

landscapelink=/usr/lib/python3/dist-packages/landscape/sysinfo/landscapelink.py

if [[ -f $landscapelink ]]; then							# strip the landscape upsell
	sed -i '/Graph this data/d' "$landscapelink"
	sed -i '/landscape.canonical.com/d' "$landscapelink"
	sed -i 's|self._sysinfo.add_footnote(|self._sysinfo.add_footnote("")|' "$landscapelink"
fi

[[ -f /etc/update-motd.d/00-header ]] && sed -i '/printf/i \echo' /etc/update-motd.d/00-header
[[ -f /etc/update-motd.d/10-help-text ]] && sed -i '/printf/d' /etc/update-motd.d/10-help-text

if [[ -f /usr/lib/update-notifier/apt_check.py ]]; then					# silence the esm/pro advertising
	sed -Ezi.orig \
		-e 's/(def _output_esm_service_status.outstream, have_esm_service, service_type.:\n)/\1    return\n/' \
		-e 's/(def _output_esm_package_alert.*?\n.*?\n.:\n)/\1    return\n/' \
		/usr/lib/update-notifier/apt_check.py
	/usr/lib/update-notifier/update-motd-updates-available --force >>"$clklog" 2>&1
fi
okay


#########################
## Login customization ##
#########################

# Appended rather than spliced in by line number, so it survives a release bump.
# Bash reads .bashrc top to bottom, so our PS1 wins over the shipped one.
step "Customizing the login shell"

userrc=/home/$adminuser/.bashrc

if ! grep -q "clk-nixinit" "$userrc" 2>/dev/null; then					# only ever append once
	{
		cat <<'RCEOF'

##
# clk-nixinit customization
##

PS1='${debian_chroot:+($debian_chroot)}\[\033[01;31m\]\u\[\033[01;32m\]@\[\033[01;34m\]\h\[\033[00m\]:\[\033[01;32m\]\w\[\033[00m\]# '

echo
if [ -x /usr/games/fortune ]; then
	/usr/games/fortune -s
fi
echo
echo
RCEOF
		printf 'echo -e "\\033[01;30m%s"\necho\n' "$brandline"			# branding line, escapes stay literal
	} >> "$userrc"

	chown "$adminuser": "$userrc"
fi
okay

# Customize nanorc default text highlighting
step "Installing nano syntax highlighting"
cp -f "$scriptdir"/confs/env.default.nanorc /usr/share/nano/default.nanorc
okay

curson

echo -e "${bgrn}   Customization complete!${cln}\n"
