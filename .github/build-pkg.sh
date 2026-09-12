#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Build the quickfile packages (apk + ipk) without the OpenWrt SDK.
#
#   Usage: fakeroot bash .github/build-pkg.sh <apk|ipk>
#
# Scope: x86_64 only. OpenWrt identifies packages by the distribution
# architecture name (ARCH_PACKAGES), which is "x86_64" for x86/64, and by
# "noarch" (apk) / "all" (ipk) for architecture independent packages. A package
# carrying any other arch string is rejected by apk (only an exact match or
# "noarch" is installable) and ignored by opkg ("has no valid architecture").
#
# Package definitions also exist in quickfile/Makefile and
# luci-app-quickfile/Makefile for in-tree/feed builds; this script mirrors them
# for the CI release build and does not call OpenWrt's BuildPackage machinery.
#
# Build inputs are committed, no binary is downloaded at build time:
#   vendor/quickfile/quickfile-<version>-x86_64.tar.gz   (git-lfs)
#   vendor/quickfile/SHA256SUMS
#
# Integrity checks, all mandatory:
#   1. The vendored tarball must match vendor/quickfile/SHA256SUMS.
#   2. The upstream multi-arch tarball is downloaded and must match
#      PKG_HASH from quickfile/Makefile.
#   3. Its quickfile.x86_64 must be byte-identical to the vendored one.
# A failure aborts the build; there is no silent fallback.
# Set QUICKFILE_SKIP_UPSTREAM_VERIFY=1 only for offline development builds,
# which then print a warning.

set -o errexit
set -o pipefail
set -o nounset

usage() {
	echo "usage: $0 <apk|ipk>" >&2
	exit 1
}

PKG_MGR="${1:-}"
shift || true
[ $# -eq 0 ] || usage
case "$PKG_MGR" in
apk | ipk) ;;
*) usage ;;
esac

ARCH=x86_64
# apk-tools v3 spells architecture independent packages "noarch"; opkg uses "all".
NOARCH_APK=noarch
NOARCH_IPK=all

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$BASE_DIR/.." && pwd)"
VENDOR_DIR="$REPO_DIR/vendor/quickfile"
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
PACKAGE_PATHS=(
	.github/build-pkg.sh
	LICENSE
	quickfile
	luci-app-quickfile
	vendor/quickfile
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
QUICKFILE_HASH="$(get_mk_value PKG_HASH "$REPO_DIR/quickfile/Makefile")"
if [ -z "$VERSION" ] || [ -z "$RELEASE" ]; then
	fail "cannot read PKG_VERSION/PKG_RELEASE from luci-app-quickfile/Makefile"
fi
[ "$VERSION" = "$QUICKFILE_VERSION" ] ||
	fail "PKG_VERSION mismatch: luci-app-quickfile=$VERSION vs quickfile=$QUICKFILE_VERSION (bump both Makefiles together)"
[ -n "$QUICKFILE_HASH" ] || fail "cannot read PKG_HASH from quickfile/Makefile"

### Verify the vendored tarball (the actual build input)

VENDORED_TARBALL="$VENDOR_DIR/quickfile-${VERSION}-${ARCH}.tar.gz"
[ -f "$VENDORED_TARBALL" ] || fail "missing vendored tarball: $VENDORED_TARBALL"
echo "::group::Verifying vendored tarball"
(cd "$VENDOR_DIR" && sha256sum -c SHA256SUMS) || fail "vendor/quickfile/SHA256SUMS does not match the vendored tarballs"

VENDORED_DIR="$TEMP_DIR/vendored"
mkdir -p "$VENDORED_DIR"
tar -xzf "$VENDORED_TARBALL" -C "$VENDORED_DIR"
BINARY="$VENDORED_DIR/quickfile-${VERSION}/quickfile.${ARCH}"
[ -f "$BINARY" ] || fail "quickfile.${ARCH} not found in $VENDORED_TARBALL"
VENDORED_BIN_SHA="$(sha256sum "$BINARY" | cut -d' ' -f1)"
echo "vendored quickfile.${ARCH} sha256: $VENDORED_BIN_SHA"
echo "::endgroup::"

### Verify that the vendored binary is the one PKG_HASH describes

if [ "${QUICKFILE_SKIP_UPSTREAM_VERIFY:-0}" = "1" ]; then
	echo "::warning::QUICKFILE_SKIP_UPSTREAM_VERIFY=1: skipping the PKG_HASH check against upstream"
else
	echo "::group::Verifying against upstream (PKG_HASH)"
	UPSTREAM_TARBALL="$TEMP_DIR/upstream-quickfile.tar.gz"
	curl -fsSL --retry 3 --max-time 300 -o "$UPSTREAM_TARBALL" \
		"https://r2.cooluc.com/source/quickfile-${VERSION}.tar.gz" ||
		fail "cannot download quickfile-${VERSION}.tar.gz from upstream"
	echo "${QUICKFILE_HASH}  ${UPSTREAM_TARBALL}" | sha256sum -c - >/dev/null ||
		fail "PKG_HASH does not match the upstream quickfile-${VERSION}.tar.gz"

	mkdir -p "$TEMP_DIR/upstream"
	tar -xzf "$UPSTREAM_TARBALL" -C "$TEMP_DIR/upstream" "quickfile-${VERSION}/quickfile.${ARCH}" ||
		fail "quickfile.${ARCH} not found in the upstream tarball"
	UPSTREAM_BIN_SHA="$(sha256sum "$TEMP_DIR/upstream/quickfile-${VERSION}/quickfile.${ARCH}" | cut -d' ' -f1)"
	echo "upstream quickfile.${ARCH} sha256: $UPSTREAM_BIN_SHA"
	[ "$UPSTREAM_BIN_SHA" = "$VENDORED_BIN_SHA" ] ||
		fail "vendored quickfile.${ARCH} differs from the upstream binary: re-vendor vendor/quickfile/ and refresh SHA256SUMS"
	echo "vendored binary matches upstream and PKG_HASH"
	echo "::endgroup::"
fi

# apk-tools v3 uses "-r<N>"; ipkg uses "-<N>"
if [ "$PKG_MGR" = "apk" ]; then
	PKGVER="${VERSION}-r${RELEASE}"
else
	PKGVER="${VERSION}-${RELEASE}"
fi
echo "Building ${PKG_MGR} packages for version ${PKGVER} (arch: ${ARCH}, noarch: $( [ "$PKG_MGR" = apk ] && echo "$NOARCH_APK" || echo "$NOARCH_IPK" ))"
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
install -m0755 "$BINARY" "$QF_DIR/usr/bin/quickfile"
install -m0755 "$REPO_DIR/quickfile/files/quickfile.init" "$QF_DIR/etc/init.d/quickfile"
install -m0644 "$REPO_DIR/quickfile/files/quickfile.locations" "$QF_DIR/etc/nginx/conf.d/quickfile.locations"
install -m0644 "$REPO_DIR/quickfile/LICENSE" "$QF_DIR/usr/share/licenses/quickfile/LICENSE"
install -m0644 "$REPO_DIR/quickfile/NOTICE" "$QF_DIR/usr/share/licenses/quickfile/NOTICE"

### Maintainer scripts for luci-app-quickfile (shared by apk + ipk)

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
# Nothing to undo: the package only ensures that conf.d/*.locations is
# included, which is stock behaviour shared with other packages.
default_prerm $0 $@
PRERM

### Packaging helpers

function build_apk() { # <pkg_dir> <name> <version> <arch> <desc> <depends> <scripts>
	local pkg_dir="$1" name="$2" version="$3" arch="$4" desc="$5" depends="$6" scripts="$7"

	mkdir -p "$pkg_dir/lib/apk/packages"
	find "$pkg_dir" -type f,l -printf '/%P\n' | sort > "$pkg_dir/lib/apk/packages/$name.list"

	local script_args=()
	if [ "$scripts" == "yes" ]; then
		script_args+=(--script "post-install:$TEMP_DIR/app-post-install")
		script_args+=(--script "post-upgrade:$TEMP_DIR/app-post-upgrade")
		script_args+=(--script "pre-deinstall:$TEMP_DIR/app-pre-deinstall")
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

function build_ipk() { # <pkg_dir> <name> <version> <arch> <section> <desc> <depends> <scripts>
	local pkg_dir="$1" name="$2" version="$3" arch="$4" section="$5" desc="$6" depends="$7" scripts="$8"

	mkdir -p "$pkg_dir/CONTROL"
	cat > "$pkg_dir/CONTROL/control" <<-EOF
		Package: $name
		Version: $version
		Depends: $depends
		Source: https://github.com/szwjp/luci-app-quickfile
		SourceName: $name
		Section: $section
		SourceDateEpoch: $PKG_SOURCE_DATE_EPOCH
		License: Apache-2.0
		Maintainer: sbwml <admin@cooluc.com>
		Architecture: $arch
		Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
		Description: $desc
	EOF
	chmod 0644 "$pkg_dir/CONTROL/control"

	if [ "$scripts" == "yes" ]; then
		cat > "$pkg_dir/CONTROL/postinst" <<'POSTINST'
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
		chmod 0755 "$pkg_dir/CONTROL/postinst"

		cat > "$pkg_dir/CONTROL/prerm" <<'PRERM'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
PRERM
		chmod 0755 "$pkg_dir/CONTROL/prerm"
	fi

	ipkg-build -m "" "$pkg_dir" "$TEMP_DIR"
	mv "$TEMP_DIR/${name}_${version}_${arch}.ipk" "$OUT_DIR/${name}_${version}_${arch}.ipk"
}

### Build

if [ "$PKG_MGR" == "apk" ]; then
	build_apk "$APP_DIR" "luci-app-quickfile" "$PKGVER" "$NOARCH_APK" \
		"LuCI File Manager module" "libc luci-nginx quickfile" "yes"
	build_apk "$I18N_DIR" "luci-i18n-quickfile-zh-cn" "$PKGVER" "$NOARCH_APK" \
		"QuickFile - Chinese translation" "luci-app-quickfile" "no"
	build_apk "$QF_DIR" "quickfile" "$PKGVER" "$ARCH" \
		"Lightweight web-based file manager for OpenWrt" "libc" "no"
else
	build_ipk "$APP_DIR" "luci-app-quickfile" "$PKGVER" "$NOARCH_IPK" "luci" \
		"LuCI File Manager module" "libc, luci-nginx, quickfile" "yes"
	build_ipk "$I18N_DIR" "luci-i18n-quickfile-zh-cn" "$PKGVER" "$NOARCH_IPK" "luci" \
		"QuickFile - Chinese translation" "luci-app-quickfile" "no"
	build_ipk "$QF_DIR" "quickfile" "$PKGVER" "$ARCH" "net" \
		"Lightweight web-based file manager for OpenWrt" "libc" "no"
fi

echo "Artifacts in $OUT_DIR:"
ls -l "$OUT_DIR"
