include $(TOPDIR)/rules.mk

PKG_NAME:=termux
PKG_VERSION:=2026.06.07
PKG_RELEASE:=1

CONTAINER_IMAGE:=termux/termux-docker
CONTAINER_IMAGE_DIGEST:=sha256:76262dd04f266f27e5713422f9af79aff22ee8907c863ccbef59d474b32d9e26
CONTAINER_PLATFORMS:=linux/amd64 linux/arm64 linux/arm/v7
CONTAINER_NAME:=termux
CONTAINER_STANDALONE:=1
CONTAINER_USERID:=termux=196608:termux=196608
CONTAINER_CAPS:=DAC_OVERRIDE SETUID SETGID
# a shell + package manager can run anything the user installs, so ship the full
# Podman default profile rather than the hardened floor (still zero-cap gated)
CONTAINER_SECCOMP_PROFILE:=relaxed
# bionic's linker rejects section-header-stripped ELFs (invalid e_shstrndx),
# so opt out of the sstrip pass that drops section headers (all else still applied)
CONTAINER_STRIP:=no-sstrip
CONTAINER_MEMORY:=128m
CONTAINER_CPU:=50
CONTAINER_TITLE:=Termux bionic userland
CONTAINER_URL:=https://github.com/termux/termux-docker
CONTAINER_DESCRIPTION:=The Termux Android (bionic libc) userland shipped as a container. Exercises the seccomp tracer's startup phase markers on a bionic runtime, distinct from the glibc and static-Go cases.

PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/containers/container.mk

$(eval $(call BuildContainer,termux))
