include $(TOPDIR)/rules.mk

PKG_NAME:=grafana
PKG_VERSION:=11.1.0
PKG_RELEASE:=1

CONTAINER_IMAGE:=grafana/grafana
CONTAINER_IMAGE_DIGEST:=sha256:079600c9517b678c10cda6006b4487d3174512fd4c6cface37df7822756ed7a5
CONTAINER_PLATFORMS:=linux/amd64 linux/arm64 linux/arm/v7
CONTAINER_VOLUMES:=data:/var/lib/grafana:16m
# grafana's /run.sh entrypoint forks and re-execs helper tools (env/grep/sed)
# before grafana itself - a multi-program entrypoint that needs more than the
# single-static-binary floor. Captured via `uxc complain`.
CONTAINER_SECCOMP_ALLOW:=execve fork set_tid_address prlimit64 mprotect
# rootless: map the container ids into a private host range (runs as uid 472)
CONTAINER_USERID:=grafana=393216:grafana=393216
CONTAINER_USERNS_IDS:=472
# the monitoring stack provisions an InfluxDB datasource (token via $INFLUX_TOKEN
# env); seal a stub so the read-only rootfs has a bind target
CONTAINER_PROVISION:=/etc/grafana/provisioning/datasources/influxdb.yaml
CONTAINER_TITLE:=Grafana observability dashboards
CONTAINER_URL:=https://grafana.com
CONTAINER_DESCRIPTION:=Grafana dashboards for metrics and logs. Runs as a bridged container serving its web interface on :3000; dashboards, data sources and the embedded database persist on a per-container volume. Pairs with the prometheus and influxdb containers as data sources.

PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>
PKG_LICENSE:=AGPL-3.0-only

include $(TOPDIR)/feeds/containers/container.mk

$(eval $(call BuildContainer,grafana))
