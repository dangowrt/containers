# SPDX-License-Identifier: GPL-2.0-only
#
# compose.mk — build a container composition ("stack") package: stack-<app>.
#
# A stack is the Docker-Compose layer: a ucode template (+ optional provisioning
# files) over container-* image DEPENDS, applied on the target by uxc-stack, which
# renders the template and brings up the named instances + backhaul + secrets. It
# ships no rootfs and has no OCI source (so it does NOT include container.mk).
#
# Knobs (set before including this file):
#   STACK_DEPENDS      the container-* images the stack instantiates (+container-X ...)
#   STACK_TEMPLATE     the ucode composition template (package-local file; default <pkg>.uc)
#   STACK_PROVISION    provisioning files mounted into instances (package-local)
#   STACK_TITLE / STACK_DESCRIPTION

STACK_DEPENDS ?=
STACK_TEMPLATE ?= $(PKG_NAME).uc
STACK_PROVISION ?=
STACK_TITLE ?= $(PKG_NAME) container stack
STACK_DESCRIPTION ?= A zero-touch container composition (stack).

PKG_RELEASE ?= 1

# package-local template/provisioning paths (resolved like container.mk's seccomp file)
STACK_MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
STACK_PKG_DIR := $(STACK_MK_DIR)$(PKG_NAME)
_stk_tmpl := $(STACK_PKG_DIR)/$(STACK_TEMPLATE)
_stk_prov := $(foreach f,$(STACK_PROVISION),$(STACK_PKG_DIR)/$(f))

include $(INCLUDE_DIR)/package.mk

define BuildCompose
  define Package/stack-$(1)
    SECTION:=containers
    CATEGORY:=Containers
    TITLE:=$(STACK_TITLE)
    DEPENDS:=@m +uxc $(STACK_DEPENDS)
    PKGARCH:=all
  endef

  define Package/stack-$(1)/description
$(STACK_DESCRIPTION)
  endef

  define Build/Compile
  endef

  define Package/stack-$(1)/install
	$$(INSTALL_DIR) $$(1)/usr/share/uxc/stacks/$(1)
	$$(INSTALL_DATA) $(_stk_tmpl) $$(1)/usr/share/uxc/stacks/$(1).uc
	$(if $(_stk_prov),$$(INSTALL_DATA) $(_stk_prov) $$(1)/usr/share/uxc/stacks/$(1)/)
  endef

  define Package/stack-$(1)/postinst
#!/bin/sh
[ -s /lib/functions/uxc.sh ] || exit 0
. /lib/functions/uxc.sh
uxc_stack_postinst $(1)
exit 0
  endef

  define Package/stack-$(1)/prerm
#!/bin/sh
[ -s /lib/functions/uxc.sh ] || exit 0
. /lib/functions/uxc.sh
uxc_stack_prerm $(1)
exit 0
  endef

  $$(eval $$(call BuildPackage,stack-$(1)))
endef
