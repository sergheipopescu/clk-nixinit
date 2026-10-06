#!/bin/bash
#
# clk-nixinit :: php
# One or more php-fpm pools from the ondrej ppa. The highest version installed
# becomes the default pool, the rest stay opt-in per vhost.
#
# "latest" anywhere in the list is resolved against the repo once it is added,
# so it never needs a hardcoded version that goes stale.
#
# usage: make-php.sh [8.5,8.4,7.4|latest]

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
logstart "php"

phplist=${1:-$(cfg php latest)}								# comma or space separated version list

uploadmax=$(cfg php_upload_max 200M)							# upload_max_filesize / post_max_size
memlimit=$(cfg php_memory_limit 512M)							# memory_limit
exectime=$(cfg php_max_execution 300)							# max_execution_time / max_input_time
maxchildren=$(cfg php_max_children 50)							# pm.max_children

coreext=(fpm mysql gd mbstring opcache xml zip)						# always required
optext=(mcrypt curl dom exif fileinfo igbinary imagick intl memcached)			# nice to have, not every version ships all


##
# Functions
##

# Ask the repo what the newest php actually is. apt-cache does the loose match,
# grep does the precise one, so this does not depend on apt-cache's regex
# flavour. Only callable once the ppa is added and the index updated.
resolve_latest() {

	apt-cache search --names-only '^php.*-fpm$' 2>/dev/null |
		awk '{print $1}' |
		grep -E '^php[0-9]+\.[0-9]+-fpm$' |
		sed 's/^php//; s/-fpm$//' |
		sort -Vr |
		head -n 1
}

# Install the optional extension set, falling back to one at a time so a single
# missing package on a newer php does not sink the whole install
optional_extensions() {

	local vrs=$1 pkgs=() ext

	for ext in "${optext[@]}"; do pkgs+=("php$vrs-$ext"); done

	apt_install "${pkgs[@]}" && return 0

	for ext in "${pkgs[@]}"; do apt_install "$ext" || echo "skipped $ext"; done

	return 0
}

# php.ini and pool tuning, identical for every version we install
tune_php() {

	local vrs=$1
	local ini=/etc/php/$vrs/fpm/php.ini
	local pool=/etc/php/$vrs/fpm/pool.d/www.conf

	sed -i "s|pm.max_children = 5|pm.max_children = $maxchildren|" "$pool"
	sed -i "s|upload_max_filesize = 2M|upload_max_filesize = $uploadmax|" "$ini"
	sed -i "s|post_max_size = 8M|post_max_size = $uploadmax|" "$ini"
	sed -i "s|memory_limit = 128M|memory_limit = $memlimit|" "$ini"
	sed -i "s|max_execution_time = 30|max_execution_time = $exectime|" "$ini"
	sed -i "s|max_input_time = 60|max_input_time = $exectime|" "$ini"
	sed -i 's|;max_input_vars = 1000|max_input_vars = 20000|' "$ini"
	sed -i 's|;realpath_cache_size = 4096k|realpath_cache_size = 4096k|' "$ini"

	# enable opcache + optimization tweaks
	sed -i '/opcache.enable=/c\opcache.enable=1' "$ini"
	sed -i '/opcache.memory_consumption=/c\opcache.memory_consumption=256' "$ini"
	sed -i '/opcache.max_accelerated_files=/c\opcache.max_accelerated_files=30000' "$ini"
	sed -i '/opcache.max_wasted_percentage=/c\opcache.max_wasted_percentage=15' "$ini"
	sed -i '/opcache.validate_timestamps=/c\opcache.validate_timestamps=1' "$ini"
	sed -i '/opcache.revalidate_freq=/c\opcache.revalidate_freq=0' "$ini"
	sed -i '/opcache.enable_file_override=/c\opcache.enable_file_override=1' "$ini"
	sed -i '/opcache.interned_strings_buffer/c\opcache.interned_strings_buffer=64' "$ini"

	# move php logs out of the shared log root
	sed -i "/error_log =/c\\error_log = /var/log/php/php$vrs-fpm.log" /etc/php/"$vrs"/fpm/php-fpm.conf
	sed -i "/\/var\/log/c\\/var/log/php/php$vrs-fpm.log {" /etc/logrotate.d/php"$vrs"-fpm
}


##
# Script
##

banner "PHP"
cursoff

# Add ondrej repo for the newest php versions
step "Adding the php repository"
makespin "add-apt-repository ppa:ondrej/php -y"

step "Updating repositories"
makespin "apt-get update"

# Only now can the repo be asked what "latest" means
if [[ $phplist == *latest* ]]; then

	step "Resolving the latest php version"
	phplatest=$(resolve_latest)

	[[ -n $phplatest ]] || { echo -e "\n ${bred}Could not work out the latest php version from the repo${cln}\n"; fail; }

	phplist=${phplist//latest/$phplatest}
	okay
fi

# Highest version first, that one becomes the default pool
mapfile -t phpvrss < <(echo "$phplist" | tr ',' '\n' | tr ' ' '\n' | sed '/^$/d' | sort -Vr -u)

[[ ${#phpvrss[@]} -gt 0 ]] || { echo -e "\n ${bred}No php version given${cln}\n"; exit 1; }

phpdefault=${phpvrss[0]}								# default fpm pool

echo -e "	Installing php ${cyn}${phpvrss[*]}${cln}\n"

mkdir -p /var/log/php

step "Installing mcrypt tooling"
makespin_soft "apt_install mcrypt"

for phpvrs in "${phpvrss[@]}"; do

	step "Installing php$phpvrs core extensions"
	corepkgs=()
	for ext in "${coreext[@]}"; do corepkgs+=("php$phpvrs-$ext"); done
	makespin "apt_install ${corepkgs[*]}"

	step "Installing php$phpvrs optional extensions"
	makespin_soft "optional_extensions $phpvrs"

	step "Tuning php$phpvrs"
	tune_php "$phpvrs"
	okay

	# Keep lfd from tripping over a long lived fpm master
	grep -q "exe:/usr/sbin/php-fpm$phpvrs" /etc/csf/csf.pignore 2>/dev/null ||
		echo "exe:/usr/sbin/php-fpm$phpvrs" >> /etc/csf/csf.pignore

	profile_add php_versions "$phpvrs"

done


####################
## Apache wiring  ##
####################

# Only the default pool gets wired in globally. A vhost that wants another
# version includes the matching a2.phost snippet instead.
if have_cmd a2enconf; then

	step "Wiring php$phpdefault into apache"

	for phpvrs in "${phpvrss[@]}"; do
		a2dismod "php$phpvrs" -f >>"$clklog" 2>&1				# mod_php would shadow php-fpm
		a2disconf "php$phpvrs-fpm" >>"$clklog" 2>&1
	done

	{
		a2dismod cgi -f
		a2enmod proxy_fcgi setenvif
		a2enconf "php$phpdefault-fpm"
	} >>"$clklog" 2>&1

	# proxy error pages back to apache
	sed -i 's|^#  ProxyErrorOverride On|  ProxyErrorOverride On|' /etc/apache2/conf-available/clk.a2.conf
	okay
fi

for phpvrs in "${phpvrss[@]}"; do
	systemctl restart "php$phpvrs-fpm" >>"$clklog" 2>&1 || fail
done

profile_set php_default "$phpdefault"
profile_set php "$(printf '%s,' "${phpvrss[@]}" | sed 's/,$//')"

curson

echo -e "	Default php-fpm pool: ${cyn}$phpdefault${cln}\n"
echo -e "${bgrn}   PHP complete!${cln}\n"
