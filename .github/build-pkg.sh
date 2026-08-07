#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build quickfile packages (ipk/apk) without the OpenWrt SDK.
# Usage: fakeroot bash build-pkg.sh <apk|ipk>

set -o errexit
set -o pipefail

PKG_MGR="${1:-apk}"

export PKG_SOURCE_DATE_EPOCH="$(date "+%s")"
export SOURCE_DATE_EPOCH="$PKG_SOURCE_DATE_EPOCH"

BASE_DIR="$(cd "$(dirname $0)"; pwd)"
REPO_DIR="$BASE_DIR/.."
ARCH="x86_64"

QUICKFILE_SOURCE_URL="https://r2.cooluc.com/source/quickfile-@VERSION@.tar.gz"
QUICKFILE_SOURCE_HASH="b4cd9d5a8497ed247fc5fa802b55e88d859b56cad3ad7775e1210ba7690510c1"

function get_mk_value() {
	awk -F "$1:=" '{print $2}' "$2" | xargs
}

QUICKFILE_VERSION="$(get_mk_value "PKG_VERSION" "$REPO_DIR/quickfile/Makefile")"
QUICKFILE_RELEASE="$(get_mk_value "PKG_RELEASE" "$REPO_DIR/quickfile/Makefile")"
APP_VERSION="$(get_mk_value "PKG_VERSION" "$REPO_DIR/luci-app-quickfile/Makefile")"
APP_RELEASE="$(get_mk_value "PKG_RELEASE" "$REPO_DIR/luci-app-quickfile/Makefile")"

if [ "$PKG_MGR" == "apk" ]; then
	QUICKFILE_PKGVER="${QUICKFILE_VERSION}-r${QUICKFILE_RELEASE}"
	APP_PKGVER="${APP_VERSION}-r${APP_RELEASE}"
else
	QUICKFILE_PKGVER="${QUICKFILE_VERSION}-${QUICKFILE_RELEASE}"
	APP_PKGVER="${APP_VERSION}-${APP_RELEASE}"
fi

TEMP_DIR="$(mktemp -d -p "$BASE_DIR")"

# Download the prebuilt quickfile binary
curl -fL -o "$TEMP_DIR/quickfile.tar.gz" "${QUICKFILE_SOURCE_URL/@VERSION@/$QUICKFILE_VERSION}"
echo "$QUICKFILE_SOURCE_HASH  $TEMP_DIR/quickfile.tar.gz" | sha256sum -c -
tar -xzf "$TEMP_DIR/quickfile.tar.gz" -C "$TEMP_DIR" "quickfile-${QUICKFILE_VERSION}/quickfile.${ARCH}"

### Package trees

# 1. quickfile
QF_DIR="$TEMP_DIR/quickfile"
mkdir -p "$QF_DIR/usr/bin" "$QF_DIR/etc/init.d" "$QF_DIR/etc/nginx/conf.d"
install -m0755 "$TEMP_DIR/quickfile-${QUICKFILE_VERSION}/quickfile.${ARCH}" "$QF_DIR/usr/bin/quickfile"
install -m0755 "$REPO_DIR/quickfile/files/quickfile.init" "$QF_DIR/etc/init.d/quickfile"
install -m0644 "$REPO_DIR/quickfile/files/quickfile.locations" "$QF_DIR/etc/nginx/conf.d/quickfile.locations"

# 2. luci-app-quickfile
APP_DIR="$TEMP_DIR/luci-app-quickfile"
mkdir -p "$APP_DIR"
cp -fpR "$REPO_DIR/luci-app-quickfile/htdocs" "$APP_DIR/www"
cp -fpR "$REPO_DIR/luci-app-quickfile/root/"* "$APP_DIR/"

# 3. luci-i18n-quickfile-zh-cn
I18N_DIR="$TEMP_DIR/luci-i18n-quickfile-zh-cn"
mkdir -p "$I18N_DIR/usr/lib/lua/luci/i18n"
po2lmo "$REPO_DIR/luci-app-quickfile/po/zh_Hans/quickfile.po" "$I18N_DIR/usr/lib/lua/luci/i18n/quickfile.zh-cn.lmo"

### Maintainer scripts for luci-app-quickfile

echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-quickfile"
default_postinst
[ -n "${IPKG_INSTROOT}" ] || { rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}' > "$TEMP_DIR/app-post-install"

echo -e '#!/bin/sh
export PKG_UPGRADE=1
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-quickfile"
default_postinst
[ -n "${IPKG_INSTROOT}" ] || { rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}' > "$TEMP_DIR/app-post-upgrade"

echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-quickfile"
default_prerm' > "$TEMP_DIR/app-pre-deinstall"

### Packaging helpers

function build_apk() {
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
		--info "origin:https://github.com/szwjp/luci-app-quickfile" \
		--info "url:https://github.com/sbwml/luci-app-quickfile" \
		--info "maintainer:sbwml <admin@cooluc.com>" \
		--info "depends:$depends" \
		"${script_args[@]}" \
		--files "$pkg_dir" \
		--output "$TEMP_DIR/${name}-${version}.apk"

	mv "$TEMP_DIR/${name}-${version}.apk" "$BASE_DIR/${name}-${version}.apk"
}

function build_ipk() {
	local pkg_dir="$1" name="$2" version="$3" arch="$4" section="$5" desc="$6" depends="$7" scripts="$8"

	mkdir -p "$pkg_dir/CONTROL"
	cat > "$pkg_dir/CONTROL/control" <<-EOF
		Package: $name
		Version: $version
		Depends: $depends
		Source: https://github.com/sbwml/luci-app-quickfile
		SourceName: $name
		Section: $section
		SourceDateEpoch: $PKG_SOURCE_DATE_EPOCH
		Maintainer: sbwml <admin@cooluc.com>
		Architecture: $arch
		Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
		Description: $desc
	EOF
	chmod 0644 "$pkg_dir/CONTROL/control"

	if [ "$scripts" == "yes" ]; then
		echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}' > "$pkg_dir/CONTROL/postinst"
		chmod 0755 "$pkg_dir/CONTROL/postinst"

		echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@' > "$pkg_dir/CONTROL/prerm"
		chmod 0755 "$pkg_dir/CONTROL/prerm"
	fi

	ipkg-build -m "" "$pkg_dir" "$TEMP_DIR"
	mv "$TEMP_DIR/${name}_${version}_${arch}.ipk" "$BASE_DIR/${name}-${version}.ipk"
}

### Build

if [ "$PKG_MGR" == "apk" ]; then
	build_apk "$QF_DIR" "quickfile" "$QUICKFILE_PKGVER" "x86_64" \
		"Lightweight web-based file manager for OpenWrt" "libc" "no"
	build_apk "$APP_DIR" "luci-app-quickfile" "$APP_PKGVER" "noarch" \
		"LuCI File Manager module" "libc luci-nginx quickfile" "yes"
	build_apk "$I18N_DIR" "luci-i18n-quickfile-zh-cn" "$APP_PKGVER" "noarch" \
		"QuickFile - Chinese translation" "luci-app-quickfile" "no"
else
	build_ipk "$QF_DIR" "quickfile" "$QUICKFILE_PKGVER" "x86_64" "net" \
		"Lightweight web-based file manager for OpenWrt" "libc" "no"
	build_ipk "$APP_DIR" "luci-app-quickfile" "$APP_PKGVER" "all" "luci" \
		"LuCI File Manager module" "libc, luci-nginx, quickfile" "yes"
	build_ipk "$I18N_DIR" "luci-i18n-quickfile-zh-cn" "$APP_PKGVER" "all" "luci" \
		"QuickFile - Chinese translation" "luci-app-quickfile" "no"
fi

rm -rf "$TEMP_DIR"
