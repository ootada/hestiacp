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
