include $(TOPDIR)/rules.mk

PKG_NAME:=traefik-whoami
PKG_VERSION:=1.10.2
PKG_RELEASE:=1

CONTAINER_IMAGE:=traefik/whoami
CONTAINER_IMAGE_DIGEST:=sha256:1474027c316661cdec87df2623e13a41e7e1ce0ba99c24917631de8f300b5420
CONTAINER_PLATFORMS:=linux/amd64 linux/arm64 linux/arm/v7
CONTAINER_NAME:=whoami
CONTAINER_STANDALONE:=1
CONTAINER_NET:=bridged:lan
CONTAINER_NETIFD:=1
CONTAINER_INITENV:=APP_MODE=demo APP_SECRET=generate
CONTAINER_USERID:=whoami=131072:whoami=131072
CONTAINER_CAPS:=NET_BIND_SERVICE
# container-exact seccomp: a dedicated OCI seccomp-object file listing only this
# workload's measured runtime syscalls; the loader/init startup set is supplied
# by ujail's phase bases and revoked at main. See the file's _comment for how it
# was derived. Extend via CONTAINER_SECCOMP_ALLOW if a code path is missed.
CONTAINER_SECCOMP_PROFILE:=whoami.seccomp.json
CONTAINER_MEMORY:=64m
CONTAINER_CPU:=50
CONTAINER_TITLE:=whoami demo container (HTTP echo)
CONTAINER_URL:=https://github.com/traefik/whoami
CONTAINER_DESCRIPTION:=Tiny HTTP server that echoes request information. The smoke test for the declarative container image feed: a content-addressed read-only rootfs shipped as a uvol layer with a generated OCI config and a bridged network.

PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>
PKG_LICENSE:=MIT

include $(TOPDIR)/feeds/containers/container.mk

$(eval $(call BuildContainer,traefik-whoami))
