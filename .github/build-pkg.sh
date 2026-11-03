#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Build the quickfile packages (apk) without the OpenWrt SDK.
#
#   Usage: fakeroot bash .github/build-pkg.sh <backend-binary>
#
# The backend binary is not built here: it is compiled by the "backend" job of
# .github/workflows/build.yml from the upstream source tarball pinned in
# quickfile/Makefile (PKG_SOURCE / PKG_HASH) and passed in as a file. Its
# sha256 is verified against QUICKFILE_BACKEND_SHA256, which that job exports,
# so a corrupted or swapped artifact aborts the build.
#
# Scope: x86_64 only. OpenWrt identifies packages by the distribution
# architecture name (ARCH_PACKAGES), which is "x86_64" for x86/64, and by
# "noarch" for architecture independent packages. A package carrying any other
# arch string is rejected by apk (only an exact match or "noarch" is
# installable).
#
# Package definitions also exist in quickfile/Makefile and
# luci-app-quickfile/Makefile for in-tree/feed builds; this script mirrors them
# for the CI release build and does not call OpenWrt's BuildPackage machinery.
#
# Integrity checks, all mandatory:
#   1. The backend binary must match the sha256 exported by the build job.
#   2. The backend binary must be a static x86-64 ELF executable.
# A failure aborts the build; there is no silent fallback.

set -o errexit
set -o pipefail
set -o nounset

usage() {
	echo "usage: $0 <backend-binary>" >&2
	exit 1
}

BACKEND_BIN="${1:-${QUICKFILE_BACKEND_BIN:-}}"
shift || true
[ $# -eq 0 ] || usage
[ -n "$BACKEND_BIN" ] || usage
[ -f "$BACKEND_BIN" ] || {
	echo "error: backend binary not found: $BACKEND_BIN" >&2
	exit 1
}

ARCH=x86_64
# apk-tools v3 spells architecture independent packages "noarch".
NOARCH_APK=noarch

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$BASE_DIR/.." && pwd)"
OUT_DIR="$REPO_DIR/dist"

fail() {
	echo "error: $*" >&2
	exit 1
}

get_mk_value() { # <field> <makefile>
	sed -n "s/^$1:=//p" "$2" | head -n1 | tr -d '[:space:]'
}

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

# Reproducible timestamps: derive them from the last commit that changed
# packaged content instead of the build time, so that rebuilding the same
# packaged content (even from a later commit that only touched docs or CI)
# produces byte-identical artifacts. .github/build-pkg.sh is part of the
# packaged content because it decides what goes into the packages; the workflow
# itself is not.
#
# The backend binary is not a committed input, so the packages are reproducible
# for a given binary, not across backend rebuilds: Rust is not bit-reproducible
# by default. The binary's own sha256 is published with the release.
PACKAGE_PATHS=(
	.github/build-pkg.sh
	.github/patches
	LICENSE
	quickfile
	luci-app-quickfile
)
SOURCE_DATE_EPOCH="$(git -C "$REPO_DIR" log -1 --format=%ct -- "${PACKAGE_PATHS[@]}" 2>/dev/null || true)"
[ -n "$SOURCE_DATE_EPOCH" ] || SOURCE_DATE_EPOCH=0
echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH (last commit touching the packaged files)"
export SOURCE_DATE_EPOCH
export PKG_SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"

### Version and hash metadata
VERSION="$(get_mk_value PKG_VERSION "$REPO_DIR/luci-app-quickfile/Makefile")"
RELEASE="$(get_mk_value PKG_RELEASE "$REPO_DIR/luci-app-quickfile/Makefile")"
QUICKFILE_VERSION="$(get_mk_value PKG_VERSION "$REPO_DIR/quickfile/Makefile")"
SOURCE_HASH="$(get_mk_value PKG_HASH "$REPO_DIR/quickfile/Makefile")"
if [ -z "$VERSION" ] || [ -z "$RELEASE" ]; then
	fail "cannot read PKG_VERSION/PKG_RELEASE from luci-app-quickfile/Makefile"
fi
[ "$VERSION" = "$QUICKFILE_VERSION" ] ||
	fail "PKG_VERSION mismatch: luci-app-quickfile=$VERSION vs quickfile=$QUICKFILE_VERSION (bump both Makefiles together)"
[ -n "$SOURCE_HASH" ] || fail "cannot read PKG_HASH from quickfile/Makefile"

### Verify the backend binary handed over by the build job
echo "::group::Verifying backend binary"
BACKEND_SHA="$(sha256sum "$BACKEND_BIN" | cut -d' ' -f1)"
echo "backend binary sha256: $BACKEND_SHA"
if [ -n "${QUICKFILE_BACKEND_SHA256:-}" ]; then
	[ "$BACKEND_SHA" = "$QUICKFILE_BACKEND_SHA256" ] ||
		fail "backend binary sha256 mismatch: expected $QUICKFILE_BACKEND_SHA256, got $BACKEND_SHA"
	echo "backend binary matches the sha256 exported by the build job"
else
	echo "::warning::QUICKFILE_BACKEND_SHA256 is not set; the backend binary is not cross-checked"
fi

# The backend is built for x86_64-unknown-linux-musl and links the xz
# decompressor statically, so it must not need any shared library. A dynamic
# binary would not run on OpenWrt (musl) and is therefore a build error.
if command -v readelf >/dev/null 2>&1; then
	NEEDED="$(readelf -d "$BACKEND_BIN" 2>/dev/null | grep NEEDED || true)"
	if [ -n "$NEEDED" ]; then
		fail "backend binary is not statically linked: $NEEDED"
	fi
	echo "backend binary is statically linked"
fi
echo "::endgroup::"

# apk-tools v3 uses "-r<N>"
PKGVER="${VERSION}-r${RELEASE}"
echo "Building apk packages for version ${PKGVER} (arch: ${ARCH}, noarch: ${NOARCH_APK})"
mkdir -p "$OUT_DIR"

### Package trees
APP_DIR="$TEMP_DIR/luci-app-quickfile"
mkdir -p "$APP_DIR"
cp -fpR "$REPO_DIR/luci-app-quickfile/htdocs" "$APP_DIR/www"
cp -fpR "$REPO_DIR/luci-app-quickfile/root/"* "$APP_DIR/"
mkdir -p "$APP_DIR/usr/share/licenses/luci-app-quickfile"
install -m0644 "$REPO_DIR/LICENSE" "$APP_DIR/usr/share/licenses/luci-app-quickfile/LICENSE"

I18N_DIR="$TEMP_DIR/luci-i18n-quickfile-zh-cn"
mkdir -p "$I18N_DIR/usr/lib/lua/luci/i18n"
po2lmo "$REPO_DIR/luci-app-quickfile/po/zh_Hans/quickfile.po" "$I18N_DIR/usr/lib/lua/luci/i18n/quickfile.zh-cn.lmo"

QF_DIR="$TEMP_DIR/quickfile-${ARCH}"
mkdir -p "$QF_DIR/usr/bin" "$QF_DIR/etc/init.d" "$QF_DIR/etc/nginx/conf.d" \
	"$QF_DIR/usr/share/licenses/quickfile"
install -m0755 "$BACKEND_BIN" "$QF_DIR/usr/bin/quickfile"
install -m0755 "$REPO_DIR/quickfile/files/quickfile.init" "$QF_DIR/etc/init.d/quickfile"
install -m0644 "$REPO_DIR/quickfile/files/quickfile.locations" "$QF_DIR/etc/nginx/conf.d/quickfile.locations"
install -m0644 "$REPO_DIR/quickfile/LICENSE" "$QF_DIR/usr/share/licenses/quickfile/LICENSE"
install -m0644 "$REPO_DIR/quickfile/NOTICE" "$QF_DIR/usr/share/licenses/quickfile/NOTICE"

### Maintainer scripts for luci-app-quickfile

# configure_nginx_quickfile only ensures that the LAN server includes
# conf.d/*.locations, repairs leftovers of earlier versions and rolls itself
# back if nginx rejects the result. It never touches certificates, listeners or
# the http -> https redirect, and a failure must not fail the package
# transaction.
cat > "$TEMP_DIR/app-post-install" <<'POSTINST'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-quickfile"

[ -f /usr/lib/quickfile/configure-nginx.sh ] && . /usr/lib/quickfile/configure-nginx.sh

default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	configure_nginx_quickfile || true
	exit 0
}
POSTINST

cat > "$TEMP_DIR/app-post-upgrade" <<'POSTUP'
#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-quickfile"

[ -f /usr/lib/quickfile/configure-nginx.sh ] && . /usr/lib/quickfile/configure-nginx.sh

default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	configure_nginx_quickfile || true
	exit 0
}
POSTUP

cat > "$TEMP_DIR/app-pre-deinstall" <<'PRERM'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-quickfile"
# Hand the certificate back to nginx-util and drop ours, so nothing keeps
# pointing at files this package no longer provides.
[ -f /usr/lib/quickfile/configure-nginx.sh ] && . /usr/lib/quickfile/configure-nginx.sh
[ -n "${IPKG_INSTROOT}" ] || cleanup_nginx_quickfile
default_prerm $0 $@
PRERM

### Maintainer scripts for the quickfile backend package

# The backend ships an init script. Without a post-install script apk never
# enables or starts it, so a fresh install would leave the service down and
# every request for the backend would fail.
cat > "$TEMP_DIR/qf-post-install" <<'POSTINST'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="quickfile"

# default_postinst enables and starts every /etc/init.d script this package
# ships, which is /etc/init.d/quickfile.
default_postinst $0 $@
exit 0
POSTINST

# On removal the service has to stop, the runtime socket has to go and nginx
# has to stop routing to it. The location file belongs to this package, but
# nginx only drops the location on a reload, so the teardown does both.
cat > "$TEMP_DIR/qf-pre-deinstall" <<'PRERM'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="quickfile"

if [ -z "${IPKG_INSTROOT}" ]; then
	# default_prerm stops the service and removes its rc.d link. It must be
	# the only one doing it: a second stop finds no procd instance left and
	# makes the removal log a "service delete (Not found)" error.
	default_prerm $0 $@
	# The runtime socket and the nginx location belong to this package. nginx
	# only drops the location on a reload, so the teardown does both.
	rm -rf /tmp/run/quickfile
	rm -f /etc/nginx/conf.d/quickfile.locations
	[ -x /etc/init.d/nginx ] && /etc/init.d/nginx reload >/dev/null 2>&1
	exit 0
fi
default_prerm $0 $@
exit 0
PRERM

### Packaging helper

function build_apk() { # <pkg_dir> <name> <version> <arch> <desc> <depends> <scripts>
	local pkg_dir="$1" name="$2" version="$3" arch="$4" desc="$5" depends="$6" scripts="$7"

	mkdir -p "$pkg_dir/lib/apk/packages"
	find "$pkg_dir" -type f,l -printf '/%P\n' | sort > "$pkg_dir/lib/apk/packages/$name.list"

	local script_args=()
	if [ "$scripts" == "luci" ]; then
		script_args+=(--script "post-install:$TEMP_DIR/app-post-install")
		script_args+=(--script "post-upgrade:$TEMP_DIR/app-post-upgrade")
		script_args+=(--script "pre-deinstall:$TEMP_DIR/app-pre-deinstall")
	elif [ "$scripts" == "backend" ]; then
		script_args+=(--script "post-install:$TEMP_DIR/qf-post-install")
		script_args+=(--script "pre-deinstall:$TEMP_DIR/qf-pre-deinstall")
	fi

	apk mkpkg \
		--info "name:$name" \
		--info "version:$version" \
		--info "description:$desc" \
		--info "arch:$arch" \
		--info "license:Apache-2.0" \
		--info "origin:https://github.com/szwjp/luci-app-quickfile" \
		--info "url:https://github.com/szwjp/luci-app-quickfile" \
		--info "maintainer:sbwml <admin@cooluc.com>" \
		--info "depends:$depends" \
		"${script_args[@]}" \
		--files "$pkg_dir" \
		--output "$OUT_DIR/${name}-${version}.apk"
}

### Build

build_apk "$APP_DIR" "luci-app-quickfile" "$PKGVER" "$NOARCH_APK" \
	"LuCI File Manager module" "libc luci-nginx quickfile" "luci"
build_apk "$I18N_DIR" "luci-i18n-quickfile-zh-cn" "$PKGVER" "$NOARCH_APK" \
	"QuickFile - Chinese translation" "luci-app-quickfile" "no"
build_apk "$QF_DIR" "quickfile" "$PKGVER" "$ARCH" \
	"Lightweight web-based file manager for OpenWrt" "libc" "backend"

echo "Artifacts in $OUT_DIR:"
ls -l "$OUT_DIR"
