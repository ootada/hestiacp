#!/bin/bash

# Hestia Control Panel upgrade script for target version 1.10.8

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

# BEGIN #5977: dovecot-hestia Fail2Ban filter
# Fix dovecot-iptables jail never banning any IP: the stock fail2ban dovecot
# filter does not match the log format produced by Hestia's Dovecot config
# (new "Login aborted" messages, auth(user,ip,sasl:...) lines from Exim's
# SASL backend and "passwd-file: missing passwd file" errors). Install the
# Hestia-specific filter and point the jail to it.
f2b_jail="/etc/fail2ban/jail.local"
f2b_filter="/etc/fail2ban/filter.d/dovecot-hestia.conf"
hestia_f2b_filter="$HESTIA_INSTALL_DIR/fail2ban/filter.d/dovecot-hestia.conf"

dovecot_jail_section() {
	sed -n '/^\[dovecot-iptables\]/,/^\[/p' "$f2b_jail"
}

if [[ -f "$f2b_jail" ]] && [[ -f "$hestia_f2b_filter" ]] \
	&& dovecot_jail_section | grep -qE '^[[:space:]]*filter[[:space:]]*=[[:space:]]*dovecot[[:space:]]*(#.*)?$'; then

	echo "[ + ] Updating Dovecot filter for Fail2Ban"

	f2b_was_active=false
	if systemctl is-active --quiet fail2ban; then
		f2b_was_active=true
	fi

	backup_jail="$(mktemp)"

	# Keep an existing (possibly customised) filter under a unique name
	filter_backup_ok=true
	if [[ -f "$f2b_filter" ]]; then
		if backup_filter="$(mktemp "$f2b_filter.bak-XXXXXX")" && cp -p "$f2b_filter" "$backup_filter"; then
			echo "[ + ] Previous dovecot-hestia filter saved as $backup_filter"
		else
			filter_backup_ok=false
		fi
	fi

	if ! cp -p "$f2b_jail" "$backup_jail" || ! $filter_backup_ok; then
		echo "[ ! ] Failed to create temporary backup"
		rm -f "$backup_jail"
	elif ! cp -f "$hestia_f2b_filter" "$f2b_filter"; then
		echo "[ ! ] Failed to install Dovecot Fail2Ban filter"
		rm -f "$backup_jail"
	else
		sed -i '/^\[dovecot-iptables\]/,/^\[/ s/^\([[:space:]]*filter[[:space:]]*=[[:space:]]*\)dovecot[[:space:]]*\(#.*\)\?$/\1dovecot-hestia/' "$f2b_jail"

		if ! dovecot_jail_section | grep -qE '^[[:space:]]*maxretry'; then
			sed -i '/^\[dovecot-iptables\]/,/^\[/ s/^\([[:space:]]*filter[[:space:]]*=[[:space:]]*dovecot-hestia[[:space:]]*\)$/\1\nmaxretry = 10/' "$f2b_jail"
		fi

		if ! fail2ban-client -t &> /dev/null; then
			echo "[ ! ] Error validating Fail2Ban configuration, restoring previous jail.local"

			if cp -p "$backup_jail" "$f2b_jail" && fail2ban-client -t; then
				echo "[ + ] Previous jail.local restored successfully"
				rm -f "$backup_jail"
			else
				echo "[ ! ] CRITICAL: Failed to restore previous Fail2Ban configuration"
				echo "[ ! ] Temporary backup preserved at: $backup_jail"
			fi
		elif $f2b_was_active; then
			if systemctl restart fail2ban && systemctl is-active --quiet fail2ban; then
				echo "[ + ] Service Fail2Ban restarted successfully"
				rm -f "$backup_jail"
			else
				echo "[ ! ] Error restarting Fail2Ban, restoring previous jail.local"

				if cp -p "$backup_jail" "$f2b_jail" \
					&& fail2ban-client -t \
					&& systemctl restart fail2ban \
					&& systemctl is-active --quiet fail2ban; then

					echo "[ + ] Previous jail.local restored successfully"
					rm -f "$backup_jail"
				else
					echo "[ ! ] CRITICAL: Failed to restore previous Fail2Ban configuration"
					echo "[ ! ] Temporary backup preserved at: $backup_jail"
				fi
			fi
		else
			rm -f "$backup_jail"
		fi
	fi
fi
# END #5977

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

# BEGIN #5913: per-domain SMTP relay lookup for authenticated null-sender mail
exim_conf="/etc/exim4/exim4.conf.template"
# No colon in the expression: the macro is used in colon separated lists (require_files, client_send)
exim_relay_new_expr='${if eq{$sender_address_domain}{}{${extract{2}{@}{$authenticated_id}}}{$sender_address_domain}}'
exim_relay_old_dsearch='SMTP_RELAY_FILE = ${if exists{/etc/exim4/domains/${lookup{$sender_address_domain}dsearch{/etc/exim4/domains}}/smtp_relay.conf}{/etc/exim4/domains/${lookup{$sender_address_domain}dsearch{/etc/exim4/domains}}/smtp_relay.conf}{/etc/exim4/smtp_relay.conf}}'
exim_relay_old_legacy='SMTP_RELAY_FILE = ${if exists{/etc/exim4/domains/${sender_address_domain}/smtp_relay.conf}{/etc/exim4/domains/$sender_address_domain/smtp_relay.conf}{/etc/exim4/smtp_relay.conf}}'

if [[ -f "$exim_conf" ]] && grep -q '^SMTP_RELAY_FILE = ' "$exim_conf" \
	&& ! grep -q '^SMTP_RELAY_FILE = .*authenticated_id' "$exim_conf"; then

	exim_content="$(< "$exim_conf")"
	exim_new_content="${exim_content//"$exim_relay_old_dsearch"/SMTP_RELAY_FILE = \${if exists\{/etc/exim4/domains/\${lookup\{$exim_relay_new_expr\}dsearch\{/etc/exim4/domains\}\}/smtp_relay.conf\}\{/etc/exim4/domains/\${lookup\{$exim_relay_new_expr\}dsearch\{/etc/exim4/domains\}\}/smtp_relay.conf\}\{/etc/exim4/smtp_relay.conf\}\}}"
	exim_new_content="${exim_new_content//"$exim_relay_old_legacy"/SMTP_RELAY_FILE = \${if exists\{/etc/exim4/domains/$exim_relay_new_expr/smtp_relay.conf\}\{/etc/exim4/domains/$exim_relay_new_expr/smtp_relay.conf\}\{/etc/exim4/smtp_relay.conf\}\}}"

	if [[ "$exim_new_content" == "$exim_content" ]]; then
		echo "[ ! ] Exim SMTP_RELAY_FILE line was customised, not updating it. See https://github.com/hestiacp/hestiacp/pull/5913 for the new line"
	else
		echo "[ + ] Fixing per-domain SMTP relay lookup for null-sender mail in Exim"

		exim_was_active=false
		if systemctl is-active --quiet exim4; then
			exim_was_active=true
		fi

		# Unique name, an existing backup is never overwritten
		exim_conf_bak="$(mktemp "$exim_conf.bak-XXXXXX")"

		if ! cp -p "$exim_conf" "$exim_conf_bak"; then
			echo "[ ! ] Failed to create a backup of $exim_conf, not updating it"
			rm -f "$exim_conf_bak"
		else
			printf '%s\n' "$exim_new_content" > "$exim_conf"

			# Exim reads the config generated from the template, check that one
			exim_check_file="$(mktemp)"
			if update-exim4.conf -o "$exim_check_file" > /dev/null 2>&1 \
				&& exim4 -C "$exim_check_file" -bV > /dev/null 2>&1; then
				exim_ok=true
			else
				exim_ok=false
			fi
			rm -f "$exim_check_file"

			if ! $exim_ok; then
				echo "[ ! ] The updated Exim configuration is invalid, restoring the previous one"
				if cp -p "$exim_conf_bak" "$exim_conf"; then
					echo "[ + ] Previous Exim configuration restored, backup kept at: $exim_conf_bak"
				else
					echo "[ ! ] CRITICAL: Failed to restore $exim_conf, backup kept at: $exim_conf_bak"
				fi
			elif $exim_was_active; then
				if systemctl restart exim4 && systemctl is-active --quiet exim4; then
					echo "[ + ] Exim4 restarted successfully, previous template saved as $exim_conf_bak"
				else
					echo "[ ! ] Exim4 failed to restart, restoring the previous configuration"
					if cp -p "$exim_conf_bak" "$exim_conf" && systemctl restart exim4 && systemctl is-active --quiet exim4; then
						echo "[ + ] Exim4 restarted successfully after rollback, backup kept at: $exim_conf_bak"
					else
						echo "[ ! ] CRITICAL: Exim4 failed to restart even after rollback, backup kept at: $exim_conf_bak"
					fi
				fi
			else
				echo "[ + ] Exim4 is not running, new configuration takes effect on next start"
			fi
		fi
	fi
fi
# END #5913
