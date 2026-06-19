include $(TOPDIR)/rules.mk

PKG_NAME:=prometheus
PKG_VERSION:=2.53.1
PKG_RELEASE:=1

CONTAINER_IMAGE:=prom/prometheus
CONTAINER_IMAGE_DIGEST:=sha256:f20d3127bf2876f4a1df76246fca576b41ddf1125ed1c546fbd8b16ea55117e6
CONTAINER_PLATFORMS:=linux/amd64 linux/arm64 linux/arm/v7
CONTAINER_RM:=usr/bin/promtool bin/promtool
CONTAINER_VOLUMES:=data:/prometheus:32m
# rootless: map the container ids into a private host range (runs as nobody)
CONTAINER_USERID:=prometheus=327680:prometheus=327680
CONTAINER_USERNS_IDS:=65534
# remote_write agent: no local TSDB (so it fits a small volume), forwards to
# influxdb. The monitoring stack provisions prometheus.yml + the token; seal a
# stub for the bound token so the read-only rootfs has a bind target.
CONTAINER_COMMAND:=/bin/prometheus --enable-feature=agent --config.file=/etc/prometheus/prometheus.yml --storage.agent.path=/prometheus
CONTAINER_PROVISION:=/etc/prometheus/influx-token
CONTAINER_TITLE:=Prometheus monitoring and time series
CONTAINER_URL:=https://prometheus.io
CONTAINER_DESCRIPTION:=Prometheus metrics collection and alerting. Runs as a bridged container serving its web UI and API on :9090; its TSDB persists on a per-container volume. Composed with influxdb + grafana by the monitoring stack.

PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/containers/container.mk

$(eval $(call BuildContainer,prometheus))
