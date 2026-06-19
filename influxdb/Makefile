include $(TOPDIR)/rules.mk

PKG_NAME:=influxdb
PKG_VERSION:=2.7.10
PKG_RELEASE:=1

CONTAINER_IMAGE:=influxdb
CONTAINER_IMAGE_DIGEST:=sha256:b4cd4b71bc8528c5cb6b9dede79091a234f9f565a3177b8fc4c2cc835bf5c142
CONTAINER_PLATFORMS:=linux/amd64 linux/arm64
CONTAINER_VOLUMES:=data:/var/lib/influxdb2:64m
CONTAINER_NET:=bridged:lan
CONTAINER_NETIFD:=1
CONTAINER_INITENV:=DOCKER_INFLUXDB_INIT_MODE=setup DOCKER_INFLUXDB_INIT_USERNAME=admin DOCKER_INFLUXDB_INIT_PASSWORD=generate DOCKER_INFLUXDB_INIT_ORG=owrt DOCKER_INFLUXDB_INIT_BUCKET=default
# the image entrypoint drops privileges with gosu/su-exec, which needs these
CONTAINER_CAPS:=CHOWN DAC_OVERRIDE FOWNER SETUID SETGID
# /entrypoint.sh is a large shell wrapper that forks+execs coreutils
# (dirname/id/mkdir/chmod/chown/find/date/tee) and gosu's influxd; each re-exec
# needs syscalls the single-static-binary app-phase floor denies. Via uxc complain.
CONTAINER_SECCOMP_ALLOW:=execve set_tid_address set_robust_list mprotect prlimit64 fchown fchownat fchmodat
# rootless: map the container ids into a private host range. The OCI process is
# root (0) and the entrypoint gosu's influxd to 1000, so 1000 must be mapped too.
CONTAINER_USERID:=influxdb=262144:influxdb=262144
CONTAINER_USERNS_IDS:=1000
# the monitoring stack provisions a DBRP-init script (maps db=metrics -> the
# bucket for the prometheus remote_write v1 endpoint); seal a stub for it
CONTAINER_PROVISION:=/docker-entrypoint-initdb.d/dbrp.sh
CONTAINER_TITLE:=InfluxDB time series database
CONTAINER_URL:=https://www.influxdata.com
CONTAINER_DESCRIPTION:=InfluxDB 2.x time series database. Runs as a bridged container serving its HTTP API on :8086; the time series and config persist on per-container volumes. Used as the long-term storage backend for the prometheus demo.

PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>
PKG_LICENSE:=MIT

include $(TOPDIR)/feeds/containers/container.mk

$(eval $(call BuildContainer,influxdb))
