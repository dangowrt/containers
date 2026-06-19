include $(TOPDIR)/rules.mk

PKG_NAME:=pihole
PKG_VERSION:=2024.07.0
PKG_RELEASE:=1

CONTAINER_IMAGE:=pihole/pihole
CONTAINER_IMAGE_DIGEST:=sha256:0def896a596e8d45780b6359dbf82fc8c75ef05b97e095452e67a0a4ccc95377
CONTAINER_PLATFORMS:=linux/amd64 linux/arm64 linux/arm/v7 linux/386
CONTAINER_STANDALONE:=1
# pihole ships ~13MB in /etc/pihole (gravity.db blocklists + config) and writes
# gravity.db, pihole-FTL.db and config back there; a volume would hide the image
# content (no seeding), so /etc/pihole stays on a persistent overlay sized for
# the gravity db. Logs go to a separate volume so they cannot fill the overlay.
CONTAINER_OVERLAY:=persistent:20m
CONTAINER_VOLUMES:=log:/var/log/pihole:16m
# pihole's s6 init forks a large fleet of shell helpers (bash + coreutils,
# capsh, dig, cron, ...) and chowns/chmods /etc/pihole and rewrites config in
# place (sed -i, logrotate), which preserves ownership and copies xattrs; the
# single-static-binary floor denies the syscalls they need. Derived from
# `uxc complain` + `uxc audit`.
CONTAINER_SECCOMP_ALLOW:=mprotect execve fork vfork set_tid_address set_robust_list prlimit64 prctl setpriority socket mknod chmod fchmod fchmodat chown fchownat lchown fchown fsetxattr getxattr lgetxattr fgetxattr
# bridged on the LAN with its own address via the in-jail netifd
CONTAINER_NET:=bridged:lan
CONTAINER_NETIFD:=1
# rootless: map the container ids into a private host range. The image runs FTL
# and chowns /etc/pihole to the pihole user (999:1000) and serves the web ui as
# www-data (33), so those ids must be mapped too.
CONTAINER_USERID:=pihole=458752:pihole=458752
CONTAINER_USERNS_IDS:=33 999 1000
# root-phase caps: the entrypoint chowns state to the pihole user and s6 drops
# privileges to it and www-data
CONTAINER_CAPS:=CHOWN DAC_OVERRIDE FOWNER SETUID SETGID SETPCAP
# FTL binds :53 and lighttpd :80, and FTL reads the ARP/network tables, all after
# s6 has setuid'd them off root; these caps must be ambient to survive that drop
CONTAINER_CAPS_AMBIENT:=NET_BIND_SERVICE NET_ADMIN NET_RAW
# pihole-FTL links a shared library carrying a text relocation; the dynamic
# loader has to make that segment writable to apply it, which the W^X floor bans
CONTAINER_MDWE:=0
# two rootfs fixups: (1) s6 drops FTL to the pihole user with capsh before it
# binds :53, but nnp neuters the binary's file capability and capsh's setuid
# clears the ambient set, so rewrite the drop to hold securebits (no-setuid-fixup)
# and re-raise the ambient cap so the granted NET_BIND_SERVICE survives into FTL;
# (2) /run is a fresh tmpfs and lighttpd's run script, unlike FTL's, never creates
# its fastcgi socket dir, so make it before lighttpd starts
CONTAINER_ROOTFS_FIXUP:= \
	sed -i 's|capsh \(--user=[^ ]*\) --keep=1|capsh --secbits=20 --addamb=cap_net_bind_service \1|' etc/s6-overlay/s6-rc.d/pihole-FTL/run && \
	grep -q -- --secbits=20 etc/s6-overlay/s6-rc.d/pihole-FTL/run && \
	sed -i 's|^lighttpd -D|mkdir -p /run/lighttpd; chown www-data:www-data /run/lighttpd; lighttpd -D|' etc/s6-overlay/s6-rc.d/lighttpd/run && \
	grep -q /run/lighttpd etc/s6-overlay/s6-rc.d/lighttpd/run
CONTAINER_TITLE:=Pi-hole network-wide ad blocker (DNS)
CONTAINER_URL:=https://pi-hole.net
CONTAINER_DESCRIPTION:=Pi-hole DNS sinkhole that blocks ads network-wide. Runs as a bridged container with its own LAN address; serves DNS on :53 and the admin web interface on :80. The image ships no DHCP client, so it relies on the in-jail netifd to obtain its address.

PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>
PKG_LICENSE:=EUPL-1.2

include $(TOPDIR)/feeds/containers/container.mk

$(eval $(call BuildContainer,pihole))
