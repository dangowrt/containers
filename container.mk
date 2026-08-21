# SPDX-License-Identifier: GPL-2.0-only
#
# Build an OCI container image into an apk package shipping a content-addressed
# read-only rootfs as a uvol layer plus a uxc registration.
#
# Knobs (set before including this file):
#   CONTAINER_IMAGE        - registry repository, e.g. "traefik/whoami"
#   CONTAINER_IMAGE_DIGEST - pinned "sha256:..." manifest digest
#   CONTAINER_NAME         - container name (default: $(PKG_NAME))
#   CONTAINER_ROOTFS_TYPE  - squashfs (default) or erofs
#   CONTAINER_OVERLAY      - whole-root writable layer: none (default) |
#                            tmpfs[:size] | persistent[:size]
#   CONTAINER_VOLUMES      - id:mountpoint:size,... persistent data volumes
#                            (the image's own VOLUMEs are auto-derived too)
#   CONTAINER_TMPFS        - scratch tmpfs size for /tmp,/run (default 16m)
#   CONTAINER_STANDALONE   - 1 to bring the default instance up on install (a
#                            100%-standalone app, e.g. pihole/whoami). Default off:
#                            the default instance is registered (for dev/test and
#                            as the layer a stack draws from) but stays dormant, so
#                            an image pulled in only as a stack dependency never
#                            double-runs alongside the stack's own instance.
#   CONTAINER_IMAGE_TAG    - tag for the canonical ref (default PKG_VERSION)
#   CONTAINER_IMAGE_REF    - normalised domain/path (default derived per docker)
#   CONTAINER_PLATFORMS    - OCI platforms the image publishes (empty = any)
#   CONTAINER_STRIP        - rootfs reductions are ALL applied by default;
#                            list explicit opt-outs here: no-strip no-sstrip
#                            no-dedup keep-docs keep-locales keep-headers
#                            keep-static-libs keep-pkgmgr keep-sourcemaps
#   CONTAINER_RM           - extra rootfs paths to delete
#   CONTAINER_ROOTFS_FIXUP - shell run against the unpacked rootfs (cwd = its
#                            root) before reductions, to patch shipped scripts
#                            into cooperating with the policy floor

CONTAINER_NAME ?= $(PKG_NAME)
CONTAINER_ROOTFS_TYPE ?= squashfs
CONTAINER_OVERLAY ?= none
CONTAINER_VOLUMES ?=
CONTAINER_TMPFS ?= 16m
CONTAINER_STANDALONE ?=

_ci_ov_mode := $(word 1,$(subst :,$(space),$(CONTAINER_OVERLAY)))
_ci_ov_size := $(word 2,$(subst :,$(space),$(CONTAINER_OVERLAY)))
_ci_ov_size := $(if $(_ci_ov_size),$(_ci_ov_size),64m)
_ci_tmpfs_reg := $(if $(filter tmpfs,$(_ci_ov_mode)),$(_ci_ov_size),)

CONTAINER_SECTION ?= containers
CONTAINER_CATEGORY ?= Containers
CONTAINER_TITLE ?= $(PKG_NAME) container image
CONTAINER_URL ?= https://hub.docker.com/r/$(CONTAINER_IMAGE)
CONTAINER_DESCRIPTION ?= $(CONTAINER_TITLE) ($(CONTAINER_IMAGE)), shipped as a uvol container image.
CONTAINER_DEPENDS ?=

CONTAINER_STRIP ?=
CONTAINER_RM ?=
CONTAINER_ROOTFS_FIXUP ?=

# every reduction is applied unless explicitly opted out via CONTAINER_STRIP, so a
# newly added transform is on by default for all containers; opt-out is explicit.
_ci_strip_content := docs locales headers static-libs pkgmgr sourcemaps
_ci_strip_classes := $(foreach c,$(_ci_strip_content),$(if $(filter keep-$(c),$(CONTAINER_STRIP)),,$(c)))
_ci_do_strip := $(if $(filter no-strip,$(CONTAINER_STRIP)),,1)
_ci_do_sstrip := $(if $(filter no-sstrip,$(CONTAINER_STRIP)),,1)
_ci_do_dedup := $(if $(filter no-dedup,$(CONTAINER_STRIP)),,1)

# policy knobs (default to the tight floor; each relaxes one point)
CONTAINER_CAPS ?=
# caps that must survive an internal privilege drop (e.g. a daemon that binds a
# privileged port then setuids to its own user): placed in the ambient set and
# granted to the root phase too
CONTAINER_CAPS_AMBIENT ?=
# W^X floor is on by default; set 0 only for a JIT/interpreter that needs W+X
CONTAINER_MDWE ?=
# no-new-privs floor is on by default; set 0 only for a container that must
# regain privileges through a setuid helper, in which case the runtime honours
# the bundle's process.noNewPrivileges instead of the floor forcing it on
CONTAINER_NNP ?= 1
CONTAINER_SECCOMP_ALLOW ?=
# tight (default) | relaxed | a package-local seccomp-object filename (custom)
CONTAINER_SECCOMP_PROFILE ?=
CONTAINER_DEVICES ?=
# kernel-tunable + filesystem-confinement knobs (all additive over the floor)
CONTAINER_SYSCTL ?=
CONTAINER_RO_PATHS ?=
CONTAINER_MASK ?=
CONTAINER_LANDLOCK_RO ?=
CONTAINER_LANDLOCK_RX ?=
CONTAINER_LANDLOCK_RW ?=

# resolve a custom seccomp profile filename to its package-local path. The value
# is a mode keyword (tight/relaxed) or, otherwise, a file shipped beside the
# package Makefile (an OCI linux.seccomp object).
CONTAINER_MK_DIR:=$(dir $(lastword $(MAKEFILE_LIST)))
CONTAINER_PKG_DIR:=$(CONTAINER_MK_DIR)$(PKG_NAME)
_ci_scfile:=$(strip $(filter-out tight relaxed,$(CONTAINER_SECCOMP_PROFILE)))
_ci_scmode:=$(if $(_ci_scfile),custom,$(CONTAINER_SECCOMP_PROFILE))
_ci_scpath:=$(if $(_ci_scfile),$(CONTAINER_PKG_DIR)/$(_ci_scfile))
CONTAINER_MEMORY ?=
CONTAINER_USERID ?=
CONTAINER_USERNS_IDS ?=
CONTAINER_PIDS ?= 256
CONTAINER_NOFILE ?= 1024
CONTAINER_OOM_SCORE_ADJ ?=
CONTAINER_CPU ?=
CONTAINER_CPUSET ?=

# first-run env (KEY=value | KEY=generate) and an optional one-shot init command
CONTAINER_INITENV ?=
CONTAINER_INIT ?=
CONTAINER_INIT_SENTINEL ?=

# override the image's baked entrypoint args (e.g. run prometheus in agent mode);
# and config paths a stack provisions at runtime that the image does not ship -
# sealed as empty stubs so the read-only rootfs has a bind target
CONTAINER_COMMAND ?=
CONTAINER_PROVISION ?=

# networking (uxc-net consumes these at runtime): attach none|bridged:<net>|routed|host,
# egress/ingress zones for routed, net_proto/net_proto6/net_ip6ifaceid the
# address protocols and IPv6 interface identifier for the compiled in-jail
# config. netifd: an in-container netifd manages the jail's network - brings the
# loopback up and applies the config uxc-net compiles. This is the uxc default;
# opt out (0) only for podman-managed networking or a full-OS container running
# its own init + network daemon.
CONTAINER_NET ?= none
CONTAINER_EGRESS ?=
CONTAINER_INGRESS ?=
CONTAINER_NET_PROTO ?=
CONTAINER_NET_PROTO6 ?=
CONTAINER_NET_IP6IFACEID ?=
CONTAINER_NETIFD ?= 1

# Project the enforced requirement surface to versioned apk tags, queryable from
# the signed index before install. Additive by design: mdwe/storage/network keys
# join later (workstreams D/F) without bumping v. apk tag chars exclude space and
# '%', so comma-join lists and encode percent.
_ci_empty:=
_ci_space:=$(_ci_empty) $(_ci_empty)
_ci_comma:=,
CONTAINER_REQ_TAGS:=openwrt.req:v=1 openwrt.req:cap=$(if $(strip $(CONTAINER_CAPS)),$(subst $(_ci_space),$(_ci_comma),$(strip $(CONTAINER_CAPS))),none)
CONTAINER_REQ_TAGS+=openwrt.req:mdwe=$(if $(filter 0,$(CONTAINER_MDWE)),off,on)
CONTAINER_REQ_TAGS+=openwrt.req:nnp=$(if $(filter 0,$(CONTAINER_NNP)),off,on)
ifneq ($(strip $(CONTAINER_MEMORY)),)
  CONTAINER_REQ_TAGS+=openwrt.req:memory=$(subst %,pct,$(CONTAINER_MEMORY))
endif
ifneq ($(strip $(CONTAINER_DEVICES)),)
  CONTAINER_REQ_TAGS+=openwrt.req:device=$(subst $(_ci_space),$(_ci_comma),$(strip $(CONTAINER_DEVICES)))
endif
_ci_storage := $(if $(filter none,$(_ci_ov_mode)),ro,$(_ci_ov_mode))
CONTAINER_REQ_TAGS+=openwrt.req:storage=$(_ci_storage)
ifneq ($(filter-out none,$(CONTAINER_NET)),)
  CONTAINER_REQ_TAGS+=openwrt.req:net=$(CONTAINER_NET)
endif
ifneq ($(strip $(CONTAINER_EGRESS)),)
  CONTAINER_REQ_TAGS+=openwrt.req:egress=$(subst $(_ci_space),$(_ci_comma),$(strip $(CONTAINER_EGRESS)))
endif
ifneq ($(strip $(CONTAINER_INGRESS)),)
  CONTAINER_REQ_TAGS+=openwrt.req:ingress=$(subst $(_ci_space),$(_ci_comma),$(strip $(CONTAINER_INGRESS)))
endif

CONTAINER_PROVIDER_PRIORITY ?= 1

CONTAINER_IMAGE_TAG ?= $(PKG_VERSION)
_ci_first := $(firstword $(subst /, ,$(CONTAINER_IMAGE)))
CONTAINER_IMAGE_REF ?= $(if $(or $(findstring .,$(_ci_first)),$(findstring :,$(_ci_first)),$(filter localhost,$(_ci_first))),$(CONTAINER_IMAGE),docker.io/$(if $(findstring /,$(CONTAINER_IMAGE)),,library/)$(CONTAINER_IMAGE))

CONTAINER_PLATFORMS ?=

_ci_arch := $(call qstrip,$(ARCH))
_ci_armfpu := $(word 2,$(subst +,$(space),$(call qstrip,$(CONFIG_CPU_TYPE))))
CONTAINER_OCI_PLATFORM := $(strip \
  $(if $(filter aarch64,$(_ci_arch)),linux/arm64,\
  $(if $(filter x86_64,$(_ci_arch)),linux/amd64,\
  $(if $(filter i386,$(_ci_arch)),linux/386,\
  $(if $(filter riscv64,$(_ci_arch)),linux/riscv64,\
  $(if $(filter arm,$(_ci_arch)),$(if $(_ci_armfpu),$(if $(filter vfp vfpv2,$(_ci_armfpu)),,linux/arm/v7)),))))))

_ci_gate := $(if $(CONTAINER_PLATFORMS),$(CONTAINER_PLATFORMS),linux/amd64 linux/arm64 linux/arm/v7 linux/386 linux/riscv64)
_ci_archsyms := $(sort $(foreach p,$(_ci_gate),\
  $(if $(filter linux/amd64,$(p)),x86_64)$(if $(filter linux/arm64,$(p)),aarch64)$(if $(filter linux/arm/v7,$(p)),arm)$(if $(filter linux/386,$(p)),i386)$(if $(filter linux/riscv64,$(p)),riscv64)))
CONTAINER_ARCH_DEPENDS := $(if $(_ci_archsyms),@($(subst $(space),||,$(_ci_archsyms))))

PKG_BUILD_DEPENDS += crane/host ucode/host

PKG_SOURCE ?= $(PKG_NAME)-$(PKG_VERSION)-image.tar
PKG_SOURCE_URL ?= oci://$(CONTAINER_IMAGE)
PKG_SOURCE_PROTO:=oci
PKG_HASH:=skip

CRANE:=$(STAGING_DIR_HOSTPKG)/bin/crane
UCODE:=$(STAGING_DIR_HOSTPKG)/bin/ucode
CONTAINER_FAKEROOT:=$(STAGING_DIR_HOST)/bin/fakeroot
CONTAINER_OCI_META:=$(TOPDIR)/feeds/containers/files/oci-meta.uc
CONTAINER_GEN_CONFIG:=$(TOPDIR)/feeds/containers/files/gen-config.uc
CONTAINER_POLICY:=$(TOPDIR)/feeds/containers/files/oci-policy.uc
CONTAINER_OCI_SEAL:=$(TOPDIR)/feeds/containers/files/oci-seal.sh
CONTAINER_SECCOMP_BASE:=$(TOPDIR)/feeds/containers/files/seccomp-base.json
CONTAINER_SECCOMP_TIGHTEN:=$(TOPDIR)/feeds/containers/files/seccomp-tighten.list
CONTAINER_STAGE:=$(TOPDIR)/feeds/containers/files/stage-container.sh
CONTAINER_GEN_REGISTRATION:=$(TOPDIR)/feeds/containers/files/gen-registration.uc
CONTAINER_STRIP_SH:=$(TOPDIR)/feeds/containers/files/strip-rootfs.sh
CONTAINER_PREINST_IN:=$(TOPDIR)/feeds/containers/files/container-preinst.in
# the target kernel's device-number authority, used to resolve name/glob devices
# ($(LINUX_DIR) comes from kernel.mk, included below); deferred so it resolves at
# recipe time. oci-policy falls back to numeric-only when it is not readable.
CONTAINER_DEVICES_TXT=$(LINUX_DIR)/Documentation/admin-guide/devices.txt

define DownloadMethod/oci
	[ -x "$(CRANE)" ] || { \
		echo "crane host tool missing; build package/feeds/containers/crane/host/install first" >&2; \
		false; \
	}; \
	rm -rf "$(DL_DIR)/$(FILE)" "$(DL_DIR)/$(FILE).layout"; \
	$(CRANE) pull --format=oci --platform $(CONTAINER_OCI_PLATFORM) "$(CONTAINER_IMAGE)@$(CONTAINER_IMAGE_DIGEST)" "$(DL_DIR)/$(FILE).layout"; \
	$(TAR) -C "$(DL_DIR)/$(FILE).layout" -cf "$(DL_DIR)/$(FILE)" .; \
	rm -rf "$(DL_DIR)/$(FILE).layout"
endef

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/kernel.mk

define Build/Compile
	$(if $(if $(CONTAINER_PLATFORMS),$(filter $(CONTAINER_OCI_PLATFORM),$(CONTAINER_PLATFORMS)),$(CONTAINER_OCI_PLATFORM)),, \
		echo "container: no image for this target ($(_ci_arch) -> '$(CONTAINER_OCI_PLATFORM)')" >&2; exit 1)
	rm -rf $(PKG_BUILD_DIR)/oci $(PKG_BUILD_DIR)/bundle
	mkdir -p $(PKG_BUILD_DIR)/oci
	$(TAR) -C $(PKG_BUILD_DIR)/oci -xf $(DL_DIR)/$(PKG_SOURCE)
	{ \
		echo "caps=$(CONTAINER_CAPS)"; \
		echo "caps_ambient=$(CONTAINER_CAPS_AMBIENT)"; \
		echo "mdwe=$(CONTAINER_MDWE)"; \
		echo "nnp=$(CONTAINER_NNP)"; \
		echo "seccomp_allow=$(CONTAINER_SECCOMP_ALLOW)"; \
		echo "seccomp_profile=$(_ci_scmode)"; \
		echo "seccomp_file=$(_ci_scpath)"; \
		echo "devices=$(CONTAINER_DEVICES)"; \
		echo "devices_txt=$(CONTAINER_DEVICES_TXT)"; \
		echo "sysctl=$(CONTAINER_SYSCTL)"; \
		echo "ro_paths=$(CONTAINER_RO_PATHS)"; \
		echo "mask=$(CONTAINER_MASK)"; \
		echo "landlock_ro=$(CONTAINER_LANDLOCK_RO)"; \
		echo "landlock_rx=$(CONTAINER_LANDLOCK_RX)"; \
		echo "landlock_rw=$(CONTAINER_LANDLOCK_RW)"; \
		echo "memory=$(CONTAINER_MEMORY)"; \
		echo "userid=$(CONTAINER_USERID)"; \
		echo "userns_ids=$(CONTAINER_USERNS_IDS)"; \
		echo "pids=$(CONTAINER_PIDS)"; \
		echo "nofile=$(CONTAINER_NOFILE)"; \
		echo "oom_score_adj=$(CONTAINER_OOM_SCORE_ADJ)"; \
		echo "cpu=$(CONTAINER_CPU)"; \
		echo "cpuset=$(CONTAINER_CPUSET)"; \
		echo "overlay_mode=$(_ci_ov_mode)"; \
		echo "overlay_size=$(_ci_ov_size)"; \
		echo "volumes=$(CONTAINER_VOLUMES)"; \
		echo "tmpfs=$(CONTAINER_TMPFS)"; \
		echo "initenv=$(CONTAINER_INITENV)"; \
		echo "init=$(CONTAINER_INIT)"; \
		echo "init_sentinel=$(CONTAINER_INIT_SENTINEL)"; \
		echo "command=$(CONTAINER_COMMAND)"; \
		echo "provision=$(CONTAINER_PROVISION)"; \
		echo "net=$(CONTAINER_NET)"; \
		echo "egress=$(CONTAINER_EGRESS)"; \
		echo "ingress=$(CONTAINER_INGRESS)"; \
		echo "net_proto=$(CONTAINER_NET_PROTO)"; \
		echo "net_proto6=$(CONTAINER_NET_PROTO6)"; \
		echo "net_ip6ifaceid=$(CONTAINER_NET_IP6IFACEID)"; \
		echo "netifd=$(CONTAINER_NETIFD)"; \
	} > $(PKG_BUILD_DIR)/policy.kv
	+UCODE="$(UCODE)" \
	SEAL_MAKE="$(MAKE)" \
	SEAL_JOBSERVER="$(MAKE_JOBSERVER)" \
	OCI_META_UC="$(CONTAINER_OCI_META)" \
	GEN_CONFIG_UC="$(CONTAINER_GEN_CONFIG)" \
	OCI_POLICY_UC="$(CONTAINER_POLICY)" \
	TAR="$(TAR)" \
	MKFS_TYPE="$(CONTAINER_ROOTFS_TYPE)" \
	MKSQUASHFS="$(STAGING_DIR_HOST)/bin/mksquashfs4" \
	MKEROFS="$(STAGING_DIR_HOST)/bin/mkfs.erofs" \
	STRIP_SH="$(CONTAINER_STRIP_SH)" \
	STRIP_CLASSES="$(_ci_strip_classes)" \
	DO_STRIP="$(_ci_do_strip)" \
	DO_SSTRIP="$(_ci_do_sstrip)" \
	DO_DEDUP="$(_ci_do_dedup)" \
	CONTAINER_RM="$(CONTAINER_RM)" \
	CONTAINER_ROOTFS_FIXUP="$(CONTAINER_ROOTFS_FIXUP)" \
	CROSS="$(TARGET_CROSS)" \
	SSTRIP="$(STAGING_DIR_HOST)/bin/sstrip" \
	RSTRIP_SH="$(SCRIPT_DIR)/rstrip.sh" \
	SOURCE_DATE_EPOCH="$(PKG_SOURCE_DATE_EPOCH)" \
	$(CONTAINER_FAKEROOT) $(SHELL) $(CONTAINER_OCI_SEAL) \
		$(PKG_BUILD_DIR)/oci $(PKG_BUILD_DIR)/bundle $(PKG_BUILD_DIR)/image.bin \
		$(PKG_BUILD_DIR)/policy.kv $(CONTAINER_OCI_PLATFORM) \
		$(CONTAINER_SECCOMP_BASE) $(CONTAINER_SECCOMP_TIGHTEN) "$(CONTAINER_NAME)"
	$(MKHASH) sha256 $(PKG_BUILD_DIR)/image.bin > $(PKG_BUILD_DIR)/image.hash
	UCODE="$(UCODE)" GEN_REGISTRATION="$(CONTAINER_GEN_REGISTRATION)" \
	PREINST_IN="$(CONTAINER_PREINST_IN)" PREINST_OUT="$(PKG_BUILD_DIR)/container-preinst" \
	$(SHELL) $(CONTAINER_STAGE) \
		$(PKG_BUILD_DIR)/image.bin $(PKG_BUILD_DIR)/image.hash $(PKG_BUILD_DIR)/stage \
		"$(CONTAINER_NAME)" "$(CONTAINER_IMAGE_REF):$(CONTAINER_IMAGE_TAG)" \
		"$(CONTAINER_IMAGE_DIGEST)" "$(_ci_tmpfs_reg)" \
		"$(if $(filter 1,$(CONTAINER_STANDALONE)),true,false)" \
		$(PKG_BUILD_DIR)/uxc-volumes.json
endef

define Container/Install
	[ -d $(PKG_BUILD_DIR)/stage ] || { echo "container stage missing; Build/Compile must run before install" >&2; exit 1; }
	$(INSTALL_DIR) $(1)
	$(CP) $(PKG_BUILD_DIR)/stage/. $(1)/
endef

# the hook logic lives in /lib/functions/uxc.sh (shipped by uxc); the package
# scripts only source it and call the helper, like default_postinst() and friends
define Container/PostInstall
#!/bin/sh
[ -s /lib/functions/uxc.sh ] || exit 0
. /lib/functions/uxc.sh
uxc_postinst $(CONTAINER_NAME)
exit 0
endef

define Container/PreRm
#!/bin/sh
[ -s /lib/functions/uxc.sh ] || exit 0
. /lib/functions/uxc.sh
uxc_prerm $(CONTAINER_NAME)
exit 0
endef

define Container/PostRm
#!/bin/sh
[ -s /lib/functions/uxc.sh ] || exit 0
. /lib/functions/uxc.sh
uxc_postrm $(CONTAINER_NAME)
exit 0
endef

define ContainerPackage
  define Package/$(1)
    SECTION:=$(CONTAINER_SECTION)
    CATEGORY:=$(CONTAINER_CATEGORY)
    TITLE:=$(CONTAINER_TITLE)
    URL:=$(CONTAINER_URL)
    DEPENDS:=@m @USE_APK $(CONTAINER_ARCH_DEPENDS) +uxc +blockd $(CONTAINER_DEPENDS)
    PKGARCH:=$(ARCH)
  endef

  define Package/$(1)/description
$(CONTAINER_DESCRIPTION)
  endef
endef

# container packages are named container-<name> (like kmod-<name>): the wrapper
# prefixes the name and the inner macro does the work with it, while PKG_BUILD_DIR
# and the CONTAINER_* knobs stay keyed on the unprefixed PKG_NAME.
define BuildContainer
  $$(eval $$(call BuildContainerPkg,container-$(1)))
endef

define BuildContainerPkg
  ifndef Package/$(1)
    $$(eval $$(call ContainerPackage,$(1)))
  endif

  ifndef Package/$(1)/install
    define Package/$(1)/install
		$$(call Container/Install,$$(1))
    endef
  endif

  ifeq ($(CONTAINER_STANDALONE),1)
    ifndef Package/$(1)/postinst
      Package/$(1)/postinst=$$(Container/PostInstall)
    endif
  endif

  ifndef Package/$(1)/prerm
    Package/$(1)/prerm=$$(Container/PreRm)
  endif

  ifndef Package/$(1)/postrm
    Package/$(1)/postrm=$$(Container/PostRm)
  endif

  $$(eval $$(call BuildPackage,$(1)))

  Package/$(1)/PROVIDES=uvol:sha256-$$$$(cat $(PKG_BUILD_DIR)/image.hash) oci:$(CONTAINER_IMAGE_REF)=$(CONTAINER_IMAGE_TAG)
  Package/$(1)/PRIORITY:=$(CONTAINER_PROVIDER_PRIORITY)
  APK_TAGS_$(1)+=$(CONTAINER_REQ_TAGS)
  # image-derived ingress hint (the image's ExposedPorts), written by the seal
  APK_TAGS_$(1)+=$$$$(cat $(PKG_BUILD_DIR)/exposed-ports.tag 2>/dev/null)
  APK_SCRIPTS_$(1)+=--script "pre-install:$(PKG_BUILD_DIR)/container-preinst"
  APK_SCRIPTS_$(1)+=--script "pre-upgrade:$(PKG_BUILD_DIR)/container-preinst"
endef
