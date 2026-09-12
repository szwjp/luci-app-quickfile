#!/bin/sh
# Quickfile <-> luci-nginx integration for OpenWrt.
#
# Sourced by the luci-app-quickfile maintainer scripts; provides
# configure_nginx_quickfile() and cleanup_nginx_quickfile().
#
# Why the certificate matters: quickfile authenticates a request by asking
# LuCI, with an internal HTTP request to "<scheme>://<host>/cgi-bin/luci" where
# <host> is what the browser used. That client verifies TLS normally, so with
# HTTPS the server certificate has to be valid for the address the user typed.
# nginx-util's own self-signed certificate has a subject only (CN=OpenWrt, no
# SANs), and Go ignores CN since 1.15, so on a stock system every API call
# fails with "x509: cannot validate certificate ...". This script therefore
# installs a self-signed certificate whose SANs cover the LAN IP, 127.0.0.1 and
# the hostname, and points nginx._lan at it - but only when nginx-util's own
# certificate is in use. An administrator-provided certificate (ACME etc.) is
# never touched.
#
# On install/upgrade it does, in order:
#   0. Export the current nginx UCI configuration for rollback.
#   1. Repair leftovers of earlier versions of this package: duplicated list
#      entries (uci add_list never de-duplicates) and the extra 80/443
#      listeners such a version appended to nginx._lan. It also re-creates
#      nginx._redirect2ssl if an earlier version deleted it, so plain http://
#      keeps being redirected to https://.
#   2. Make sure nginx._lan includes conf.d/*.locations exactly once.
#   3. Certificate: create or refresh our self-signed certificate (IP SANs) and
#      point nginx._lan at it via the documented nginx-util mechanism
#      (uci_manage_ssl=<manager> + ssl_certificate*), unless the server uses a
#      certificate this package must not touch.
#   4. Commit and, only if something changed, reload nginx. The nginx init
#      script regenerates the configuration and runs `nginx -t` itself; when
#      that fails, the backup from step 0 is restored and nginx is reloaded
#      again, so a broken configuration is never left behind.
#
# It never adds listeners and never removes the http -> https redirect.
#
# Test hooks, unset on a real system: QUICKFILE_NGINX_INIT,
# QUICKFILE_BACKUP_DIR, QUICKFILE_CERT_DIR.

QF_INCLUDE='conf.d/*.locations'
QF_BACKUP_KEEP=10
QF_MANAGE_SSL='quickfile'
# Long validity: nginx-util only auto-renews certificates whose uci_manage_ssl
# is "self-signed", so ours is not renewed for us.
QF_CERT_DAYS=3650

QF_NGINX_INIT="${QUICKFILE_NGINX_INIT:-/etc/init.d/nginx}"
QF_BACKUP_DIR="${QUICKFILE_BACKUP_DIR:-/root/backup}"
QF_CERT_DIR="${QUICKFILE_CERT_DIR:-/etc/ssl/quickfile}"
QF_CERT="$QF_CERT_DIR/quickfile-ip.crt"
QF_KEY="$QF_CERT_DIR/quickfile-ip.key"

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
	# shellcheck disable=SC2016  # nginx variables must reach uci unexpanded
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

### Certificate handling

detect_lan_ip() {
	local ip
	# network.lan.ipaddr may be written with a CIDR suffix (192.168.1.1/24 on
	# newer configs) and a SAN entry needs a bare address, so validate after
	# stripping the prefix and fall back to the first global IPv4.
	for ip in "$(uci -q get network.lan.ipaddr 2>/dev/null)" \
		"$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | head -1)"; do
		ip="${ip%%/*}"
		case "$ip" in
		[0-9]*.[0-9]*.[0-9]*.[0-9]*)
			echo "$ip"
			return
			;;
		esac
	done
	echo "192.168.1.1"
}

# True when nginx._lan uses a certificate this package may replace: ours, or
# nginx-util's own self-signed one. Anything an administrator configured - ACME,
# snakeoil, a custom file, even a path that does not exist yet - is left alone.
_cert_is_replaceable() {
	local crt manage subject
	crt="$(uci -q get nginx._lan.ssl_certificate 2>/dev/null)"
	case "$crt" in
	"$QF_CERT_DIR"/*) return 0 ;;
	esac

	manage="$(uci -q get nginx._lan.uci_manage_ssl 2>/dev/null)"
	case "$manage" in
	"$QF_MANAGE_SSL") return 0 ;;
	esac

	# Nothing configured: nginx-util would create its own certificate.
	[ -n "$crt" ] || return 0

	# uci_manage_ssl=self-signed means nginx-util owns (and would renew) that
	# certificate, so taking it over is safe.
	case "$manage" in
	self-signed) return 0 ;;
	none | '') ;;
	*) return 1 ;;
	esac

	# A configured path this package cannot inspect is left alone, also when
	# the file is missing (it may still be getting issued).
	[ -f "$crt" ] || return 1
	command -v openssl >/dev/null 2>&1 || return 1
	# OpenSSL prints "subject=C = ZZ, ..., CN = OpenWrt"; strip spaces so a
	# portable case pattern can match.
	subject="$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | tr -d ' ')"
	case "$subject" in
	*CN=OpenWrt*) return 0 ;;
	esac
	return 1
}

_cert_is_current() { # <lan-ip>
	[ -f "$QF_CERT" ] && [ -f "$QF_KEY" ] || return 1
	command -v openssl >/dev/null 2>&1 || return 1
	openssl x509 -in "$QF_CERT" -noout -checkip "$1" >/dev/null 2>&1 || return 1
	openssl x509 -in "$QF_CERT" -noout -checkend 0 >/dev/null 2>&1
}

generate_cert() { # <lan-ip>
	local ip="$1" host san out
	command -v openssl >/dev/null 2>&1 || return 1
	host="$(uci -q get system.@system[0].hostname 2>/dev/null)"
	[ -n "$host" ] || host="$(uname -n 2>/dev/null)"
	case "$host" in
	'' | *[!A-Za-z0-9._-]*) host='' ;;
	esac
	san="IP:$ip,IP:127.0.0.1"
	[ -n "$host" ] && san="$san,DNS:$host"

	mkdir -p "$QF_CERT_DIR" || return 1
	chmod 0700 "$QF_CERT_DIR" 2>/dev/null
	# Keep openssl's diagnostics: a bare "failed" is not actionable.
	if ! out="$(openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "$QF_KEY" -out "$QF_CERT" -days "$QF_CERT_DAYS" \
		-subj "/CN=$ip" -addext "subjectAltName=$san" 2>&1)"; then
		echo "quickfile: openssl failed to create $QF_CERT (SAN: $san)" >&2
		printf '%s\n' "$out" | grep -iE 'error|unable|missing|cannot|invalid' | head -3 | sed 's/^/quickfile:   /' >&2
		return 1
	fi
	chmod 0600 "$QF_KEY" 2>/dev/null
	chmod 0644 "$QF_CERT" 2>/dev/null
	echo "quickfile: created $QF_CERT (SAN: $san, ${QF_CERT_DAYS} days)" >&2
	return 0
}

# Returns 0 when the certificate was created/refreshed (nginx needs a reload),
# 1 when nothing changed, and 2 when no certificate may be installed.
_configure_certificate() {
	local ip="$1"

	if ! _cert_is_replaceable; then
		echo "quickfile: nginx._lan uses a certificate this package does not manage ($(uci -q get nginx._lan.ssl_certificate 2>/dev/null)), not touching it" >&2
		echo "quickfile: HTTPS access by IP needs a certificate with an IP SAN; reach quickfile through a name that certificate covers instead" >&2
		return 2
	fi

	if ! command -v openssl >/dev/null 2>&1; then
		echo "quickfile: openssl is missing, cannot prepare a certificate with IP SANs (install openssl-util)" >&2
		return 2
	fi

	if _cert_is_current "$ip"; then
		# The file is fine; still make sure uci points at it.
		if [ "$(uci -q get nginx._lan.ssl_certificate 2>/dev/null)" = "$QF_CERT" ] &&
			[ "$(uci -q get nginx._lan.uci_manage_ssl 2>/dev/null)" = "$QF_MANAGE_SSL" ]; then
			return 1
		fi
		uci -q set "nginx._lan.uci_manage_ssl=$QF_MANAGE_SSL"
		uci -q set "nginx._lan.ssl_certificate=$QF_CERT"
		uci -q set "nginx._lan.ssl_certificate_key=$QF_KEY"
		return 0
	fi

	generate_cert "$ip" || {
		echo "quickfile: failed to create $QF_CERT; HTTPS access by IP will not work" >&2
		return 2
	}
	uci -q set "nginx._lan.uci_manage_ssl=$QF_MANAGE_SSL"
	uci -q set "nginx._lan.ssl_certificate=$QF_CERT"
	uci -q set "nginx._lan.ssl_certificate_key=$QF_KEY"
	return 0
}

### Entry points

configure_nginx_quickfile() {
	command -v uci >/dev/null 2>&1 || return 0
	# nginx-util uses the UCI configuration whenever uci_enable is set at all
	# (any non-empty value, e.g. the stock 'true'), so mirror that here.
	[ -n "$(uci -q get nginx.global.uci_enable 2>/dev/null)" ] || return 0
	uci -q get nginx._lan >/dev/null 2>&1 || return 0

	local before after cert_result=1
	before="$(uci export nginx 2>/dev/null)"

	_repair_leftovers
	_lan_has include "$QF_INCLUDE" || uci -q add_list "nginx._lan.include=$QF_INCLUDE"
	# 0 = certificate created/refreshed (needs a reload), 1 = unchanged,
	# 2 = no certificate may be installed.
	_configure_certificate "$(detect_lan_ip)"
	cert_result=$?

	after="$(uci export nginx 2>/dev/null)"
	[ "$before" = "$after" ] && [ "$cert_result" != "0" ] && return 0

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

	if [ "$(uci -q get nginx._lan.ssl_certificate 2>/dev/null)" = "$QF_CERT" ]; then
		uci -q delete nginx._lan.ssl_certificate
		uci -q delete nginx._lan.ssl_certificate_key
		# Hand the certificate back to nginx-util, which re-creates its own.
		uci -q set nginx._lan.uci_manage_ssl=self-signed
		uci -q commit nginx 2>/dev/null || true
		if [ -x "$QF_NGINX_INIT" ]; then
			"$QF_NGINX_INIT" reload >/dev/null 2>&1 || true
		fi
	fi

	rm -rf "$QF_CERT_DIR"
	return 0
}
