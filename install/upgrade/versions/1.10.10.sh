#!/bin/bash

# Hestia Control Panel upgrade script for target version 1.10.10

#######################################################################################
#######                      Place additional commands below.                   #######
#######################################################################################
####### upgrade_config_set_value only accepts true or false.                    #######
#######                                                                         #######
####### Pass through information to the end user in case of a issue or problem  #######
#######                                                                         #######
####### Use add_upgrade_message "My message here" to include a message          #######
####### in the upgrade notification email. Example:                             #######
#######                                                                         #######
####### add_upgrade_message "My message here"                                   #######
#######                                                                         #######
####### You can use \n within the string to create new lines.                   #######
#######################################################################################

upgrade_config_set_value 'UPGRADE_UPDATE_WEB_TEMPLATES' 'false'
upgrade_config_set_value 'UPGRADE_UPDATE_DNS_TEMPLATES' 'false'
upgrade_config_set_value 'UPGRADE_UPDATE_FILEMANAGER_CONFIG' 'false'
upgrade_config_set_value 'UPGRADE_UPDATE_MAIL_TEMPLATES' 'false'
upgrade_config_set_value 'UPGRADE_REBUILD_USERS' 'false'

# Fix per-domain SMTP relay lookup for authenticated null-sender mail on existing Exim installations
exim_conf="${exim_conf:-/etc/exim4/exim4.conf.template}"
exim_conf_bak="${exim_conf}.before_smtp_relay_null_sender.bak"
pattern_dsearch='SMTP_RELAY_FILE = ${if exists{/etc/exim4/domains/${lookup{$sender_address_domain}dsearch{/etc/exim4/domains}}/smtp_relay.conf}{/etc/exim4/domains/${lookup{$sender_address_domain}dsearch{/etc/exim4/domains}}/smtp_relay.conf}{/etc/exim4/smtp_relay.conf}}'
pattern_legacy='SMTP_RELAY_FILE = ${if exists{/etc/exim4/domains/${sender_address_domain}/smtp_relay.conf}{/etc/exim4/domains/$sender_address_domain/smtp_relay.conf}{/etc/exim4/smtp_relay.conf}}'
# NOTE: no ":" may appear in the new block (SMTP_RELAY_FILE is used inside colon-separated
# lists such as require_files), hence eq{}{} instead of def:.
new_block='RELAY_SENDER_DOMAIN = ${if eq{$sender_address_domain}{}{${extract{2}{@}{$authenticated_id}}}{$sender_address_domain}}
RELAY_DOMAIN_DIR = /etc/exim4/domains/${lookup{RELAY_SENDER_DOMAIN}dsearch{/etc/exim4/domains}}
SMTP_RELAY_FILE = ${if exists{RELAY_DOMAIN_DIR/smtp_relay.conf}{RELAY_DOMAIN_DIR/smtp_relay.conf}{/etc/exim4/smtp_relay.conf}}'

if [[ -f "$exim_conf" ]] \
	&& ! grep -qE '^RELAY_(SENDER_DOMAIN|DOMAIN_DIR)[[:space:]]*=' "$exim_conf" \
	&& { grep -qFx "$pattern_dsearch" "$exim_conf" || grep -qFx "$pattern_legacy" "$exim_conf"; }; then
	echo "[ + ] Fixing per-domain SMTP relay lookup for null-sender mail in Exim"

	cp -p "$exim_conf" "$exim_conf_bak"
	exim_conf_tmp="$(mktemp "${exim_conf}.XXXXXX")"

	# Exact whole-line match in awk (no regex/escaping issues); values go through
	# ENVIRON so backslashes and special characters are kept untouched.
	PAT1="$pattern_dsearch" PAT2="$pattern_legacy" NEW="$new_block" \
		awk '$0 == ENVIRON["PAT1"] || $0 == ENVIRON["PAT2"] { print ENVIRON["NEW"]; next } { print }' \
		"$exim_conf" > "$exim_conf_tmp"
	cat "$exim_conf_tmp" > "$exim_conf" # keep original owner/permissions
	rm -f "$exim_conf_tmp"

	if systemctl restart exim4; then
		echo "[ + ] Exim4 restarted successfully"
	else
		echo "[ ! ] Exim4 failed to restart, rolling back configuration"

		if [[ -f "$exim_conf_bak" ]]; then
			mv "$exim_conf_bak" "$exim_conf"

			if systemctl restart exim4; then
				echo "[ + ] Exim4 restarted successfully after rollback"
			else
				echo "[ ! ] Exim4 failed to restart even after rollback"
			fi
		else
			echo "[ ! ] Backup file not found, unable to rollback"
		fi
	fi
fi

# Replace MySQL database grants that used an unescaped database name.
# "_" and "%" are wildcards in database-level grants, so a grant on "mys_l"
# also covered the "mysql" system schema and "johnv_shop" covered "johnvxshop".
if [ -f "$HESTIA/conf/mysql.conf" ]; then
	echo "[ * ] Replacing wildcard MySQL database grants with exact grants"
	(
		source "$HESTIA/func/db.sh"
		mysql_migrate_legacy_db_grants
	)
	add_upgrade_message "Security: MySQL database grants have been changed from wildcard to exact database names. If database users were created with a name like <user>_<db> where the pattern could match another database (for example the 'mysql' schema), please review existing MySQL accounts and stored routines for unexpected privileges."
fi

# Reinstall the phpMyAdmin SSO endpoint and rotate its keys.
# The SSO token used to be signed with bcrypt (which ignores input past 72
# bytes), allowing offline token forgery, and the host field reached a
# root-run command unvalidated. A package update refreshes the template under
# $HESTIA/install but NOT the already-deployed /usr/share/phpmyadmin/hestia-sso.php,
# so existing installs keep the vulnerable verifier and a possibly-exposed key.
# Reinstalling swaps in the fixed endpoint and generates a fresh PHPMYADMIN_KEY
# and API key; previously issued SSO links stop working, which is intended.
if [ -n "$PHPMYADMIN_KEY" ] || [ -f /usr/share/phpmyadmin/hestia-sso.php ]; then
	echo "[ * ] Reinstalling phpMyAdmin SSO with a stronger token signature and fresh keys"
	$HESTIA/bin/v-delete-sys-pma-sso quiet > /dev/null 2>&1
	if ! $HESTIA/bin/v-add-sys-pma-sso quiet > /dev/null 2>&1; then
		add_upgrade_message "phpMyAdmin Single Sign-On was disabled during the security update because it could not be reinstalled automatically. Re-enable it with 'v-add-sys-pma-sso' once phpMyAdmin and the API are available."
	fi
fi
# SMTP relay configs contain the relay password and were created world-readable
if [[ -f /etc/exim4/smtp_relay.conf ]]; then
	echo "[ + ] Restricting permissions of SMTP relay configuration"
	chmod 640 /etc/exim4/smtp_relay.conf
	chown root:Debian-exim /etc/exim4/smtp_relay.conf
fi
for relay_conf in /etc/exim4/domains/*/smtp_relay.conf; do
	if [[ -f "$relay_conf" ]]; then
		chmod 660 "$relay_conf"
		chown Debian-exim:mail "$relay_conf"
	fi
done

# Add the mail_compress plugin to the global mail_plugins setting in Dovecot 2.4
# so that doveadm can work with compressed emails.
_config_file="/etc/dovecot/conf.d/10-mail.conf"
_backup_file="${_config_file}.hestia_$(date +%Y%m%d_%H%M).bak"
_service_name="dovecot"
_required_version="2.4"
_old_line_regex='^\s*mail_plugins\s*=\s*quota\s*$'
_new_line="mail_plugins = mail_compress quota"
_dovecot_version=$(dovecot --version 2> /dev/null | awk '{print $1}' | cut -d. -f1,2)

if [ "$_dovecot_version" = "$_required_version" ]; then
	echo "[ * ] Adding mail_compress to Dovecot's global mail_plugins"

	if [ ! -f "$_config_file" ]; then
		echo "[ ! ] File not found: $_config_file" >&2
	elif ! grep -Eq "$_old_line_regex" "$_config_file"; then
		echo "[ * ] Line 'mail_plugins = quota' not found in $_config_file. Nothing to do"
	elif ! cp -p "$_config_file" "$_backup_file"; then
		echo "[ ! ] Could not create backup: $_backup_file" >&2
	else
		echo "[ + ] Backup created: $_backup_file"

		# Replace the line
		if sed -i -E "s/$_old_line_regex/$_new_line/" "$_config_file"; then
			echo "[ + ] Line replaced with: $_new_line"

			# Validate the configuration
			if doveconf -n > /dev/null 2>&1; then

				# Restart the service and check that it is running
				if systemctl restart "$_service_name" && sleep 2 && systemctl is-active --quiet "$_service_name"; then
					echo "[ + ] $_service_name is running with the new configuration"
				else
					# Failure: restore the backup and restart with the old configuration
					echo "[ ! ] $_service_name failed to start with the new configuration" >&2
					if cp -p "$_backup_file" "$_config_file"; then
						echo "[ + ] Backup restored: $_config_file"

						# Restart again and check that the original configuration works
						if systemctl restart "$_service_name" && sleep 2 && systemctl is-active --quiet "$_service_name"; then
							echo "[ * ] $_service_name is running again with the original configuration"
						else
							echo "[ ! ] $_service_name still fails to start after restoring the backup" >&2
						fi
					else
						echo "[ ! ] Could not restore the backup, it is still available at: $_backup_file" >&2
					fi
				fi
			else
				# Invalid configuration: restore the backup
				echo "[ ! ] Invalid Dovecot configuration after modification" >&2
				if cp -p "$_backup_file" "$_config_file"; then
					echo "[ + ] Backup restored: $_config_file"
				else
					echo "[ ! ] Could not restore the backup, it is still available at: $_backup_file" >&2
				fi
			fi
		else
			# Replacement failed: restore the backup
			echo "[ ! ] Could not modify $_config_file" >&2
			if cp -p "$_backup_file" "$_config_file"; then
				echo "[ + ] Backup restored: $_config_file"
			else
				echo "[ ! ] Could not restore the backup, it is still available at: $_backup_file" >&2
			fi
		fi
	fi
fi

# Start migrating PPA
# For Ubuntu: Migrate existing Apache2 repo from PPA to sury repository
# and add sury Apache2 repo if Apache2 is the web system and no sury repo is configured
_running_os="$(lsb_release -s -i)"
_running_os="${_running_os,,}"
_arch="$(dpkg --print-architecture)"
_codename="$(lsb_release -s -c)"
_apt_dir="/etc/apt/sources.list.d"
_apt_file="$_apt_dir/apache2.list"
_ppa_regex='ppa\.launchpad(content)?\.net/ondrej/apache2/ubuntu'
_sury_regex='packages\.sury\.org/apache2'
_keyring="/usr/share/keyrings/apache2-keyring.gpg"

# Download sury Apache2 key and add repo
_add_sury_apache2_repo() {
	local _tmp_key
	_tmp_key="$(mktemp)"
	if curl -fsL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 5 --retry-max-time 30 https://packages.sury.org/apache2/apt.gpg | gpg --dearmor --yes > "$_tmp_key" 2> /dev/null && [[ -s "$_tmp_key" ]]; then
		install -m 644 "$_tmp_key" "$_keyring"
		echo "[ + ] Key installed: $_keyring"
		echo "deb [arch=$_arch signed-by=$_keyring] https://packages.sury.org/apache2/ $_codename main" > "$_apt_file"
		echo "[ + ] Repo added: $_apt_file"
	else
		echo "[ ! ] Key download failed; repo not added" >&2
	fi
	rm -f "$_tmp_key"
}

if [[ "$_running_os" == "ubuntu" ]]; then

	# Find PPA files
	_ppa_files=()
	while IFS= read -r -d '' _file; do
		_ppa_files+=("$_file")
	done < <(grep -rlEZ --include='*.list' --include='*.sources' -- "$_ppa_regex" "$_apt_dir")

	# Run only if PPA files exist
	if [[ ${#_ppa_files[@]} -gt 0 ]]; then
		echo "[ + ] Migrating Apache2 PPA repo to sury"

		# Backup and remove PPA files (.save is ignored by apt)
		_ts="$(date +%Y%m%d_%H%M%S)"
		for _file in "${_ppa_files[@]}"; do
			_backup="${_file}.hestia-${_ts}.save"
			if cp -p -- "$_file" "$_backup" && rm -f -- "$_file"; then
				echo "[ + ] PPA backed up: $_backup"
			else
				echo "[ ! ] PPA backup failed: $_file" >&2
			fi
		done

		_add_sury_apache2_repo
	fi

	# Add sury repo if Apache2 is the web system and no sury Apache2 repo is configured
	_web_system="$("$BIN"/v-list-sys-config json | jq -r '.[]|.WEB_SYSTEM')"
	if [[ "$_web_system" == "apache2" && ! -e "$_apt_file" ]] \
		&& ! grep -rqE --include='*.list' --include='*.sources' -- "$_sury_regex" "$_apt_dir"; then
		echo "[ + ] Adding sury Apache2 repo"
		_add_sury_apache2_repo
	fi
fi

# The Launchpad PPA origin (ppa:ondrej/php) is no longer listed because the
# PPA has been deprecated.
_uu_conf="/etc/apt/apt.conf.d/60unattended-upgrades-hestia-php"
echo "[ + ] Update unattended-upgrades conf to install PHP updates"
cat > "$_uu_conf" << 'EOF'
Unattended-Upgrade::Origins-Pattern {
        "origin=deb.sury.org";
};
EOF

# Remove the unattended-upgrades conf that allowed Apache updates from the
# Sury PPA. That PPA has been deprecated, so the file is obsolete. Apache
# updates are still applied automatically: the PHP conf above allows the
# "deb.sury.org" origin, which also covers Sury's apache2 repository.
_uu_apache2_conf="/etc/apt/apt.conf.d/60unattended-upgrades-hestia-apache2"
if [ -f "$_uu_apache2_conf" ]; then
	echo "[ + ] Removing obsolete unattended-upgrades conf to install Apache updates"
	rm -f "$_uu_apache2_conf"
fi
# End migrating Apache2 PPA

# Catch-up migration for Ubuntu hosts whose legacy PHP PPA still uses
# ppa.launchpad.net (1.10.6.sh only matched ppa.launchpadcontent.net) or
# whose ondrej/php PPA survived in .list / .sources files.
_php_running_os="$(lsb_release -s -i 2> /dev/null)"
if [ "${_php_running_os,,}" = "ubuntu" ]; then
	_php_apt_dir="/etc/apt/sources.list.d"
	_php_ppa_regex='^[^#]*ppa\.launchpad(content)?\.net/ondrej/php/ubuntu'
	_php_sury_regex='^[^#]*packages\.sury\.org/php(/|[[:space:]]|$)'
	_php_keyring="/usr/share/keyrings/sury-keyring.gpg"
	_php_list="$_php_apt_dir/php.list"

	_php_ppa_files=()
	if [ -d "$_php_apt_dir" ]; then
		while IFS= read -r -d '' _php_file; do
			_php_ppa_files+=("$_php_file")
		done < <(grep -rlEZ --include='*.list' --include='*.sources' "$_php_ppa_regex" "$_php_apt_dir" 2> /dev/null)
	fi

	if [ "${#_php_ppa_files[@]}" -gt 0 ]; then
		_php_has_other_sury=0
		while IFS= read -r -d '' _php_sury_file; do
			_php_in_ppa=0
			for _php_file in "${_php_ppa_files[@]}"; do
				if [ "$_php_sury_file" = "$_php_file" ]; then
					_php_in_ppa=1
					break
				fi
			done
			if [ "$_php_in_ppa" -eq 0 ]; then
				_php_has_other_sury=1
				break
			fi
		done < <(grep -rlEZ --include='*.list' --include='*.sources' "$_php_sury_regex" "$_php_apt_dir" 2> /dev/null)

		_php_arch=""
		_php_codename=""
		_php_ready=1
		if [ "$_php_has_other_sury" -eq 0 ]; then
			_php_arch="$(dpkg --print-architecture 2> /dev/null)"
			_php_codename="$(lsb_release -s -c 2> /dev/null)"
			if [ -z "$_php_arch" ] || [ -z "$_php_codename" ]; then
				echo "[ ! ] Unable to determine architecture or Ubuntu codename; keeping existing PHP PPA sources"
				_php_ready=0
			fi
		fi

		_php_need_key=1
		if [ "$_php_has_other_sury" -eq 1 ] && [ -s "$_php_keyring" ]; then
			_php_need_key=0
		fi

		_php_tmp_raw=""
		_php_tmp_key=""
		if [ "$_php_ready" -eq 1 ] && [ "$_php_need_key" -eq 1 ]; then
			_php_tmp_raw="$(mktemp)"
			_php_tmp_key="$(mktemp)"
			if [ -z "$_php_tmp_raw" ] || [ -z "$_php_tmp_key" ] || ! curl -fsL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 5 --retry-max-time 30 -o "$_php_tmp_raw" https://packages.sury.org/php/apt.gpg || [ ! -s "$_php_tmp_raw" ] || ! gpg --batch --yes --dearmor -o "$_php_tmp_key" "$_php_tmp_raw" || [ ! -s "$_php_tmp_key" ]; then
				echo "[ ! ] Failed to download Sury PHP archive keyring; keeping existing PHP PPA sources"
				rm -f "$_php_tmp_raw" "$_php_tmp_key"
				_php_ready=0
			elif ! mkdir -p "$(dirname "$_php_keyring")" || ! install -m 644 "$_php_tmp_key" "$_php_keyring"; then
				echo "[ ! ] Failed to install Sury PHP archive keyring; keeping existing PHP PPA sources"
				rm -f "$_php_tmp_raw" "$_php_tmp_key"
				_php_ready=0
			else
				rm -f "$_php_tmp_raw" "$_php_tmp_key"
			fi
		fi

		if [ "$_php_ready" -eq 1 ]; then
			_php_backup_dir="${HESTIA_BACKUP:-/root/hst_backups}/conf/apt-php-ppa"
			for _php_file in "${_php_ppa_files[@]}"; do
				echo "[ + ] Migrating legacy Ubuntu PHP PPA source: $_php_file"
				_php_rel="${_php_file#"$_php_apt_dir"/}"
				mkdir -p "$_php_backup_dir/$(dirname "$_php_rel")"
				mv -f "$_php_file" "$_php_backup_dir/$_php_rel"
			done

			if ! grep -rlEq --include='*.list' --include='*.sources' "$_php_sury_regex" "$_php_apt_dir" 2> /dev/null; then
				echo "deb [arch=$_php_arch signed-by=$_php_keyring] https://packages.sury.org/php/ $_php_codename main" > "$_php_list"
				chmod 644 "$_php_list"
			fi
		fi
	fi
fi
unset _php_running_os _php_apt_dir _php_ppa_regex _php_sury_regex _php_keyring _php_list \
	_php_ppa_files _php_file _php_has_other_sury _php_sury_file _php_in_ppa \
	_php_arch _php_codename _php_ready _php_need_key _php_tmp_raw _php_tmp_key _php_backup_dir _php_rel
# End migrating legacy PHP PPA

# Local patches (integration build). Patched builds keep VERSION=1.10.10, so these blocks re-run on
# every 1.10.10-N install: each one must stay idempotent.

# BEGIN #5965: restrict permissions of the Restic configuration files
# Earlier versions created them with the default umask (world readable).
if [[ -f "$HESTIA/conf/restic.conf" ]] && [[ ! -L "$HESTIA/conf/restic.conf" ]]; then
	chmod 660 -- "$HESTIA/conf/restic.conf"
fi
# Per user repository password files
for restic_conf in "$HESTIA"/data/users/*/restic.conf; do
	if [[ -f "$restic_conf" ]] && [[ ! -L "$restic_conf" ]]; then
		chmod 600 -- "$restic_conf"
	fi
done
unset restic_conf
# END #5965

# Remove sudo and polkit administrator rights from the Hestia user "admin" (#5919).
# Ubuntu's %admin sudoers rule and polkit admin identity would grant them. The helper is
# idempotent, so run it every time: it also repairs a damaged or partial installation.
if [[ -d "$HESTIA/data/users/admin" ]]; then
	# Only report the first successful run: the step runs on every 1.10.10-N update
	admin_deny_existed=no
	[[ -f /etc/sudoers.d/zz-hestia-deny-admin ]] && admin_deny_existed=yes
	echo "[ * ] Ensuring the admin user has no sudo or polkit administrator rights"
	if protect_admin_user; then
		# 40-hestia-admin-identities.rules only existed in unreleased builds
		rm -f /etc/polkit-1/rules.d/40-hestia-admin-identities.rules
		if [[ "$admin_deny_existed" = "no" ]]; then
			add_upgrade_message "Ensured the Hestia user admin has no sudo or polkit administrator rights. On Ubuntu its primary group admin is granted both by the default configuration. Hestia installed /etc/sudoers.d/zz-hestia-deny-admin and, on Ubuntu, /etc/polkit-1/rules.d/49-hestia-admin-identities.rules. The sudoers entry also overrides a leftover /etc/sudoers.d/admin on older servers. If you used the admin account for shell administration, use a separate account in the sudo group instead: adduser myadmin and usermod -aG sudo myadmin. See https://github.com/hestiacp/hestiacp/issues/5919"
		fi
	else
		echo "[ ! ] Failed to remove sudo and polkit administrator rights from the admin user"
		add_upgrade_message "Unable to remove sudo and polkit administrator rights from the admin user (Ubuntu grants them through the admin group). Check /etc/sudoers.d and /etc/polkit-1/rules.d, then run the upgrade again. See https://github.com/hestiacp/hestiacp/issues/5919"
	fi
fi

# Apply the per-user package RATE_LIMIT to sendmail / PHP mail() in Exim (#5324).
# Replaces the stock acl_not_smtp block of the installed template with the one
# shipped in the new template. A customised block is never touched. Exim is not
# restarted here, the upgrade restarts the mail services at the end.
# usage: patch_exim_not_smtp_ratelimit [installed_template] [shipped_template]
patch_exim_not_smtp_ratelimit() {
	local conf="${1:-/etc/exim4/exim4.conf.template}"
	local shipped="${2:-$HESTIA_INSTALL_DIR/exim/exim4.conf.template}"
	local stock cur new bak n tmp vdir

	[[ -f "$conf" && -f "$shipped" ]] || return 0

	# _acl_block prints the acl_not_smtp block (up to the next top level label),
	# _acl_block_norm the same with whitespace collapsed and blank lines dropped.
	_acl_block() {
		awk '/^acl_not_smtp:/ { f = 1; print; next } f && /^[A-Za-z_][A-Za-z0-9_]*:/ { exit } f' "$1"
	}
	_acl_block_norm() {
		_acl_block "$1" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//; /^$/d'
	}

	stock=$(
		cat << 'EOF'
acl_not_smtp:
deny message = Website of user $authenticated_id is sending too many emails - rate overlimit = $sender_rate / $sender_rate_period
ratelimit = 200 / 1h / $authenticated_id
warn ratelimit = 100 / 1h / strict / $authenticated_id
log_message = Sender rate [limitlog]: log / account / $authenticated_id / $sender_rate / $sender_rate_period
accept
EOF
	)
	cur=$(_acl_block_norm "$conf")
	new=$(_acl_block_norm "$shipped")

	if [[ -z "$new" ]]; then
		echo "[ ! ] Exim: no acl_not_smtp block in the shipped template, not patched"
		return 0
	fi
	if [[ "$cur" == "$new" ]]; then
		return 0
	fi
	if [[ "$cur" != "$stock" ]]; then
		echo "[ ! ] Exim: custom acl_not_smtp block in $conf, not patched (per-user RATE_LIMIT is not applied to PHP mail())"
		add_upgrade_message "Exim: the acl_not_smtp block in $conf is customised and was not updated, so the package RATE_LIMIT is not applied to sendmail and PHP mail(). Replace it with the block from /usr/local/hestia/install/deb/exim/exim4.conf.template, then run update-exim4.conf and restart Exim."
		return 0
	fi

	echo "[ + ] Applying per-user mail rate limit to Exim acl_not_smtp"

	# Unique backup name, never overwrite an existing backup
	bak="$conf.$(date +%Y%m%d-%H%M%S).before_5324.bak"
	n=0
	while [[ -e "$bak" ]]; do
		n=$((n + 1))
		bak="$conf.$(date +%Y%m%d-%H%M%S).before_5324.$n.bak"
	done
	if ! cp -p -- "$conf" "$bak"; then
		echo "[ ! ] Exim: could not create a backup, nothing was modified"
		return 0
	fi

	# Build the candidate: installed template with the new block swapped in.
	# Every step must succeed and the result must carry the new block.
	tmp=$(mktemp "$conf.XXXXXX") || return 0
	vdir=$(mktemp -d) || {
		rm -f "$tmp"
		return 0
	}
	if ! {
		_acl_block "$shipped" > "$vdir/block" && [[ -s "$vdir/block" ]] \
			&& cp -p -- "$conf" "$tmp" \
			&& awk '
				NR == FNR { nb[++n] = $0; next }
				/^acl_not_smtp:/ { for (i = 1; i <= n; i++) print nb[i]; skip = 1; next }
				skip && /^[A-Za-z_][A-Za-z0-9_]*:/ { skip = 0 }
				!skip { print }
			' "$vdir/block" "$conf" > "$tmp" \
			&& [[ "$(_acl_block_norm "$tmp")" == "$new" ]]
	}; then
		echo "[ ! ] Exim: could not build the patched configuration, nothing was changed"
		rm -f "$tmp"
		rm -rf "$vdir"
		return 0
	fi

	# Validate the candidate before it goes anywhere near the live config
	cp -- "$tmp" "$vdir/exim4.conf.template"
	cp -- "$(dirname "$conf")/update-exim4.conf.conf" "$vdir/" 2> /dev/null
	cp -- "$(dirname "$conf")/exim4.conf.localmacros" "$vdir/" 2> /dev/null
	if ! { update-exim4.conf --confdir "$vdir" --output "$vdir/exim4.conf" \
		&& exim4 -C "$vdir/exim4.conf" -bV; } > "$vdir/validate.log" 2>&1; then
		echo "[ ! ] Exim: the patched configuration did not validate, nothing was changed"
		echo "      Details: $vdir/validate.log, rejected candidate: $tmp, backup: $bak"
		return 0
	fi

	if mv -f -- "$tmp" "$conf" && update-exim4.conf > "$vdir/apply.log" 2>&1 \
		&& exim4 -bV >> "$vdir/apply.log" 2>&1; then
		rm -rf "$vdir"
	else
		echo "[ ! ] Exim: applying the patched configuration failed, restoring the backup"
		cp -p -- "$bak" "$conf" && update-exim4.conf > /dev/null 2>&1
		echo "      Details: $vdir/apply.log, backup kept: $bak"
		return 0
	fi
}

if [[ "$MAIL_SYSTEM" == exim* ]]; then
	# Fill /etc/exim4/user-limits with each user's package RATE_LIMIT. The helper
	# warns on failure; its stderr goes to stdout so that the upgrade log has it.
	for user in $("$BIN/v-list-users" list); do
		update_exim_user_limit "$user" 2>&1
	done

	patch_exim_not_smtp_ratelimit
fi

unset -f patch_exim_not_smtp_ratelimit _acl_block _acl_block_norm
