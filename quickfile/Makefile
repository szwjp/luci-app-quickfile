#
# Copyright (C) 2015-2016 OpenWrt.org
# Copyright (C) 2026 sbwml <admin@cooluc.com>
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

PKG_NAME:=quickfile
PKG_VERSION:=1.0.25
PKG_RELEASE:=3

# Upstream multi-arch tarball (x86_64 + aarch64 + arm binaries). Only the
# x86_64 binary is packaged by this repository; see README.
#
# Two consumers, one source of truth:
#   - in-tree/feed builds use PKG_SOURCE_URL + PKG_HASH directly, and
#     Package/quickfile/install below picks quickfile.x86_64.
#   - the out-of-tree CI build (.github/build-pkg.sh) downloads this tarball,
#     verifies PKG_HASH against it, and requires the x86_64 binary inside it to
#     be byte-identical to the vendored
#     vendor/quickfile/quickfile-$(PKG_VERSION)-x86_64.tar.gz. A mismatch
#     aborts the build, so the released binary is always the hashed one.
PKG_SOURCE:=quickfile-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://r2.cooluc.com/source
PKG_HASH:=b4cd9d5a8497ed247fc5fa802b55e88d859b56cad3ad7775e1210ba7690510c1

# The upstream Go sources are Apache-2.0 (upstream LICENSE, same file as the
# repository root LICENSE); LICENSE is shipped inside the package because this
# package redistributes the prebuilt binary.
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_MAINTAINER:=sbwml <admin@cooluc.com>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/quickfile
	SECTION:=net
	CATEGORY:=Network
	SUBMENU:=Web Servers/Proxies
	TITLE:=Lightweight web-based file manager for OpenWrt
	URL:=https://github.com/szwjp/luci-app-quickfile
	DEPENDS:=+libc @TARGET_x86_64
endef

define Package/quickfile/description
	Quickfile is a lightweight web-based file manager for OpenWrt routers.
	This package provides the quickfile HTTP backend, its init script, and the
	nginx location configuration, for x86_64 only. The LuCI web UI is shipped
	separately as luci-app-quickfile.
endef

# Prebuilt Go binary: nothing to compile.
define Build/Compile
endef

define Package/quickfile/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/quickfile.x86_64 $(1)/usr/bin/quickfile
	$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/nginx/conf.d
	$(INSTALL_BIN) $(CURDIR)/files/quickfile.init $(1)/etc/init.d/quickfile
	$(INSTALL_CONF) $(CURDIR)/files/quickfile.locations $(1)/etc/nginx/conf.d/quickfile.locations
	$(INSTALL_CONF) $(CURDIR)/files/quickfile-auth.conf $(1)/etc/nginx/conf.d/quickfile-auth.conf
	$(INSTALL_DIR) $(1)/usr/share/licenses/quickfile
	$(INSTALL_DATA) $(CURDIR)/LICENSE $(1)/usr/share/licenses/quickfile/LICENSE
	$(INSTALL_DATA) $(CURDIR)/NOTICE $(1)/usr/share/licenses/quickfile/NOTICE
endef

$(eval $(call BuildPackage,quickfile))
