# This is free software, licensed under the Apache License, Version 2.0 .
# The repository root LICENSE covers this package; the prebuilt upstream
# binary shipped by the separate "quickfile" package is covered by
# quickfile/LICENSE.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-quickfile
PKG_VERSION:=1.0.25
PKG_RELEASE:=3

PKG_MAINTAINER:=sbwml <admin@cooluc.com>
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI File Manager module
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-nginx +quickfile +openssl-util

include $(TOPDIR)/feeds/luci/luci.mk

# Package description — referenced by LuCI buildroot
define Package/luci-app-quickfile/description
	LuCI support for the Quickfile web-based file manager.
	Provides the /cgi-bin/luci/admin/services/quickfile page and
	integration with the lightweight quickfile HTTP backend.
endef

# call BuildPackage - OpenWrt buildroot signature
