include $(TOPDIR)/rules.mk

PKG_NAME:=homeassistant
PKG_VERSION:=2026.6.1
PKG_RELEASE:=1

CONTAINER_IMAGE:=ghcr.io/home-assistant/home-assistant
CONTAINER_IMAGE_DIGEST:=sha256:59aa8824955c9db491b75d2eebe42bd68494f80c2ec69ec0d66d9dae37d37514
CONTAINER_PLATFORMS:=linux/amd64 linux/arm64 linux/arm/v7
CONTAINER_STANDALONE:=1

# flat L2 on the IoT network for device discovery, address via the in-jail
# netifd; the iot zone has no wan forward, so HA cannot reach the internet
CONTAINER_NET:=bridged:iot
CONTAINER_NETIFD:=1

# /config holds the whole HA state and is the only writable surface; minimum
# viable size, grow on hardware with the resources for a larger recorder db
CONTAINER_VOLUMES:=config:/config:128m
CONTAINER_MEMORY:=768m

# run rootless: container uid 0 maps to an unprivileged host base, so an s6/HA
# break-out lands as host uid 524288.. and not real root. The in-container uids
# (s6 plus the service users HA drops to) are derived from the image mtree.
CONTAINER_USERID:=homeassistant=524288:homeassistant=524288

# s6-overlay v3 runs as root and, in stage2, chowns and fixes permissions on the
# runtime tree and /config and switches uid/gid where services drop privileges;
# HA itself opens raw/admin sockets for local device discovery
CONTAINER_CAPS:=CHOWN DAC_OVERRIDE FOWNER SETUID SETGID SETPCAP NET_ADMIN NET_RAW NET_BIND_SERVICE
# HA bundles Python C extensions that may carry text relocations the W^X floor bans
CONTAINER_MDWE:=0
# s6-overlay execs a fleet of helpers and HA touches xattrs, inotify and numa
# memory policy; derived from `uxc complain`. The single-static-binary floor
# denies these by default.
CONTAINER_SECCOMP_ALLOW:=execve fork vfork set_tid_address prctl prlimit64 mprotect mknod chmod fchmod chown fchown lchown listxattr inotify_init1 inotify_add_watch pidfd_open get_mempolicy mbind

# USB ZigBee/Bluetooth dongles, if any (ttyUSB* c:188:*, ttyACM* c:166:*):
# CONTAINER_DEVICES:=c:188:0 c:166:0

CONTAINER_TITLE:=Home Assistant
CONTAINER_URL:=https://www.home-assistant.io
CONTAINER_DESCRIPTION:=Home Assistant home automation hub. Runs bridged on the IoT network for local device discovery with no internet access; all state persists on the /config volume.

PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/containers/container.mk

$(eval $(call BuildContainer,homeassistant))
