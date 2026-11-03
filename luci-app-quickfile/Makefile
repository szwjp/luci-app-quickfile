# This is free software, licensed under the Apache License, Version 2.0.
# The repository root LICENSE covers this package and the backend it ships;
# the backend's own license and NOTICE are installed by the quickfile package.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-quickfile
PKG_VERSION:=2.0.9
PKG_RELEASE:=1

PKG_MAINTAINER:=sbwml <admin@cooluc.com>
PKG_LICENSE:=Apache-2.0

LUCI_TITLE:=LuCI File Manager module
# "all" for opkg; the CI build emits "noarch" for apk, because apk only
# accepts the exact architecture name or "noarch".
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+luci-nginx +quickfile

include $(TOPDIR)/feeds/luci/luci.mk

# Package description — referenced by LuCI buildroot
define Package/luci-app-quickfile/description
	LuCI support for the Quickfile web-based file manager.
	Provides the /cgi-bin/luci/admin/services/quickfile page and
	integration with the lightweight quickfile HTTP backend.
endef

# call BuildPackage - OpenWrt buildroot signature
