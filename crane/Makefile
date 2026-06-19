include $(TOPDIR)/rules.mk

PKG_NAME:=crane
PKG_VERSION:=0.20.2
PKG_RELEASE:=1

PKG_SOURCE:=go-containerregistry-v$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/google/go-containerregistry/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=064e9c47e3dac49acddccb4afe908b9d835725d371ee9a471fd445d134fbbf1d
PKG_BUILD_DIR:=$(BUILD_DIR)/go-containerregistry-$(PKG_VERSION)
HOST_BUILD_DIR:=$(BUILD_DIR_HOST)/go-containerregistry-$(PKG_VERSION)

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>

PKG_HOST_ONLY:=1

HOST_BUILD_DEPENDS:=golang/host
GO_PKG:=github.com/google/go-containerregistry
GO_PKG_BUILD_PKG:=github.com/google/go-containerregistry/cmd/crane
GO_PKG_LDFLAGS_X:=github.com/google/go-containerregistry/cmd/crane/cmd.Version=v$(PKG_VERSION)

include $(INCLUDE_DIR)/host-build.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-host-build.mk
include $(INCLUDE_DIR)/package.mk

define Package/crane
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=crane (go-containerregistry) host tool for OCI image handling
  URL:=https://github.com/google/go-containerregistry
  BUILDONLY:=1
endef

define Package/crane/description
  crane is a tool for interacting with remote container images and registries.
  Built as a host tool so the container image feed can pull and flatten OCI
  images at build time.
endef

$(eval $(call GoBinHostBuild,crane))
$(eval $(call BuildPackage,crane))
$(eval $(call HostBuild))
