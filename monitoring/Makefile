include $(TOPDIR)/rules.mk

PKG_NAME:=monitoring
PKG_VERSION:=1
PKG_RELEASE:=1

STACK_DEPENDS:=+container-influxdb +container-grafana
STACK_TITLE:=Monitoring stack (InfluxDB + Grafana)
STACK_DESCRIPTION:=A monitoring stack: influxdb scrapes prometheus-format /metrics endpoints into a bucket and grafana visualises it. The instances are wired over a private backhaul with a generated shared token; only grafana's UI is exposed, on LAN. Scrape targets are configured by the local admin at runtime (InfluxDB scrapers), not provisioned by the package.

PKG_MAINTAINER:=Daniel Golle <daniel@makrotopia.org>
PKG_LICENSE:=GPL-2.0-only

include $(TOPDIR)/feeds/containers/compose.mk

$(eval $(call BuildCompose,monitoring))
