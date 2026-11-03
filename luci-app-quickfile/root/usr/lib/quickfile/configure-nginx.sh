#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# nginx integration for the quickfile packages.
#
# The backend listens on a unix socket and is reached through the LuCI https
# endpoint: /etc/nginx/conf.d/quickfile.locations is picked up by the "_lan"
# server, which stock OpenWrt includes through "conf.d/*.locations".
#
# This file only
#   - makes sure that include is present on the "_lan" server,
#   - restores the stock http -> https redirect if an earlier version of this
#     package removed it,
#   - reloads nginx, rolling the change back when nginx rejects the result,
#   - removes leftovers of the 1.x integration (its own certificate and the
#     session cookie rewrite) when the package is removed.
#
# It never creates or replaces a certificate, never changes a listener and
# never touches the http -> https redirect that is in place. Every caller runs
# it with "|| true", so it can never fail the package transaction.

. /lib/functions.sh

QF_INCLUDE='conf.d/*.locations'
QF_CERT_DIR='/etc/ssl/quickfile'
QF_LEFTOVER_CONF='/etc/nginx/conf.d/quickfile-auth.conf'
QF_BACKUP_DIR='/root/backup'
QF_BACKUP_KEEP=5
QF_NGINX_INIT='/etc/init.d/nginx'

# The values of a UCI list option are printed as one quoted line, and the
# values themselves contain spaces, so they cannot be split on whitespace:
#   nginx._lan.listen='443 ssl default_server' '[::]:80'
_lan_items() { # <option>
	uci -q show "nginx._lan.$1" 2>/dev/null |
		sed -n "s/^nginx\._lan\.$1=//p" |
		tr "'" '\n' |
		grep -v '^[[:space:]]*$'
}

_lan_has() { # <option> <value>
	_lan_items "$1" | grep -qxF "$2"
}

# Drop repeated values. uci add_list appends unconditionally, so duplicates
# from earlier package versions must be removed explicitly.
_lan_dedupe() { # <option>
	local items
	items="$(_lan_items "$1" | awk '!seen[$0]++')"
	[ -n "$items" ] || return 0
	[ "$items" = "$(_lan_items "$1")" ] && return 0

	local item
	uci -q delete "nginx._lan.$1"
	printf '%s\n' "$items" | while IFS= read -r item; do
		[ -n "$item" ] && uci -q add_list "nginx._lan.$1=$item"
	done
}

# Earlier versions deleted this section, which removed the http -> https
# redirect for the whole web UI. Restore the stock definition when missing.
_restore_redirect2ssl() {
	uci -q get nginx._redirect2ssl >/dev/null 2>&1 && return 0

	echo "quickfile: restoring nginx._redirect2ssl (http -> https redirect)" >&2
	uci -q set nginx._redirect2ssl=server
	uci -q set nginx._redirect2ssl.server_name=_redirect2ssl
	uci -q add_list nginx._redirect2ssl.listen=80
	uci -q add_list 'nginx._redirect2ssl.listen=[::]:80'
	# shellcheck disable=SC2016  # nginx variables must reach uci unexpanded
	uci -q set 'nginx._redirect2ssl.return=302 https://$host$request_uri'
}

configure_nginx_quickfile() {
	command -v uci >/dev/null 2>&1 || return 0
	# nginx-util uses the UCI configuration whenever uci_enable is set at all
	# (any non-empty value, e.g. the stock 'true'), so mirror that here.
	[ -n "$(uci -q get nginx.global.uci_enable 2>/dev/null)" ] || return 0
	uci -q get nginx._lan >/dev/null 2>&1 || return 0

	local before after
	before="$(uci export nginx 2>/dev/null)"

	_lan_dedupe include
	_lan_has include "$QF_INCLUDE" || uci -q add_list "nginx._lan.include=$QF_INCLUDE"
	_restore_redirect2ssl

	after="$(uci export nginx 2>/dev/null)"
	[ "$before" = "$after" ] && return 0

	# Only a run that actually changes something leaves a rollback file.
	local backup=''
	if mkdir -p "$QF_BACKUP_DIR" 2>/dev/null; then
		backup="$QF_BACKUP_DIR/nginx-uci-$(date +%Y%m%d-%H%M%S).txt"
		printf '%s\n' "$before" > "$backup" 2>/dev/null || backup=''
		if [ -n "$backup" ]; then
			# Keep only the most recent rollback files.
			ls -1t "$QF_BACKUP_DIR"/nginx-uci-*.txt 2>/dev/null |
				sed -n "$((QF_BACKUP_KEEP + 1)),\$p" |
				while IFS= read -r old; do rm -f "$old"; done
		fi
	fi

	uci -q commit nginx 2>/dev/null || true
	echo "quickfile: nginx configuration updated (backup: ${backup:-none})" >&2

	if [ -x "$QF_NGINX_INIT" ] && ! "$QF_NGINX_INIT" reload >/dev/null 2>&1; then
		echo "quickfile: nginx rejected the updated configuration, rolling back" >&2
		if [ -n "$backup" ] && [ -f "$backup" ]; then
			uci import <"$backup" && uci -q commit nginx 2>/dev/null
			"$QF_NGINX_INIT" reload >/dev/null 2>&1 ||
				echo "quickfile: nginx still not reloading, check /etc/config/nginx" >&2
			echo "quickfile: nginx configuration restored from $backup" >&2
		else
			echo "quickfile: no backup available, check /etc/config/nginx manually" >&2
		fi
		return 1
	fi
	return 0
}

cleanup_nginx_quickfile() {
	command -v uci >/dev/null 2>&1 || return 0

	# The 1.x integration shipped its own certificate and pointed the "_lan"
	# server at it. This package does not provide a certificate, so hand the
	# server back to nginx-util, which re-creates its own.
	local cert
	cert="$(uci -q get nginx._lan.ssl_certificate 2>/dev/null)"
	case "$cert" in
	"$QF_CERT_DIR"/*)
		uci -q delete nginx._lan.ssl_certificate
		uci -q delete nginx._lan.ssl_certificate_key
		uci -q set nginx._lan.uci_manage_ssl=self-signed
		uci -q commit nginx 2>/dev/null || true
		if [ -x "$QF_NGINX_INIT" ]; then
			"$QF_NGINX_INIT" reload >/dev/null 2>&1 || true
		fi
		;;
	esac

	rm -f "$QF_LEFTOVER_CONF"
	rm -rf "$QF_CERT_DIR"
	return 0
}
