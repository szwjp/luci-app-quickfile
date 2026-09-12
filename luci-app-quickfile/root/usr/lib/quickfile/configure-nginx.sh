#!/bin/sh
# Quickfile <-> luci-nginx integration for OpenWrt.
#
# Sourced by the luci-app-quickfile maintainer scripts; provides
# configure_nginx_quickfile().
#
# The package needs exactly one thing from nginx: the LAN server must include
# conf.d/*.locations, which is where quickfile.locations is installed. Stock
# OpenWrt configures that already, so on a stock system this function changes
# nothing. It deliberately does not touch listen directives, ssl_certificate,
# uci_manage_ssl or the http -> https redirect: the LAN server may be serving a
# real certificate (e.g. ACME) that must not be replaced by a self-signed one.
#
# On install/upgrade it does, in order:
#   0. Export the current nginx UCI configuration for rollback.
#   1. Repair leftovers of earlier versions of this package: duplicated list
#      entries (uci add_list never de-duplicates) and the extra 80/443
#      listeners such a version appended to nginx._lan. It also re-creates
#      nginx._redirect2ssl if an earlier version deleted it, so plain http://
#      keeps being redirected to https://.
#   2. Make sure nginx._lan includes conf.d/*.locations exactly once.
#   3. Commit and, only if something changed, reload nginx. The nginx init
#      script regenerates the configuration and runs `nginx -t` itself; when
#      that fails, the backup from step 0 is restored and nginx is reloaded
#      again, so a broken configuration is never left behind.
#
# Test hooks, unset on a real system: QUICKFILE_NGINX_INIT,
# QUICKFILE_BACKUP_DIR.

QF_INCLUDE='conf.d/*.locations'
QF_BACKUP_KEEP=10

QF_NGINX_INIT="${QUICKFILE_NGINX_INIT:-/etc/init.d/nginx}"
QF_BACKUP_DIR="${QUICKFILE_BACKUP_DIR:-/root/backup}"

# One value per line. Note that `uci show` prints a list option on a single
# line with every value quoted:
#   nginx._lan.listen='443 ssl default_server' '[::]:80'
# and listen values themselves contain spaces, so they cannot be split on
# whitespace.
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

_lan_remove_value() { # <option> <value>
	_lan_has "$1" "$2" || return 0

	local items
	items="$(_lan_items "$1" | grep -vxF "$2")"
	# Never leave the server without any listen directive.
	[ -n "$items" ] || return 0

	local item
	uci -q delete "nginx._lan.$1"
	printf '%s\n' "$items" | while IFS= read -r item; do
		uci -q add_list "nginx._lan.$1=$item"
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
	# Single quotes on purpose: nginx's $host/$request_uri must reach uci
	# unexpanded.
	# shellcheck disable=SC2016
	uci -q set 'nginx._redirect2ssl.return=302 https://$host$request_uri'
}

_repair_leftovers() {
	local legacy
	_lan_dedupe include
	_lan_dedupe listen
	# Values appended by earlier versions; the stock _lan listens on 443 only
	# (plus whatever the administrator added, which is preserved).
	for legacy in '80' '[::]:80' '443 ssl' '[::]:443 ssl'; do
		_lan_remove_value listen "$legacy"
	done
	_restore_redirect2ssl
}

configure_nginx_quickfile() {
	command -v uci >/dev/null 2>&1 || return 0
	# nginx-util uses the UCI configuration whenever uci_enable is set at all
	# (any non-empty value, e.g. the stock 'true'), so mirror that here.
	[ -n "$(uci -q get nginx.global.uci_enable 2>/dev/null)" ] || return 0
	uci -q get nginx._lan >/dev/null 2>&1 || return 0

	local before after
	before="$(uci export nginx 2>/dev/null)"

	_repair_leftovers
	_lan_has include "$QF_INCLUDE" || uci -q add_list "nginx._lan.include=$QF_INCLUDE"

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
			uci import < "$backup" && uci -q commit nginx 2>/dev/null
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
