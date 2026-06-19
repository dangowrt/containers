# OpenWrt containers feed

A package feed that turns upstream OCI/Docker images into OpenWrt apk packages.
Each container package ships its image as a **content-addressed read-only
volume** (a `uvol` layer) plus a `uxc` registration, so installing the package
makes the container available to `uxc` with declarative networking and storage.

This feed is **APK only** (`DEPENDS:=@USE_APK`); container packages are hidden
in menuconfig when building with opkg.

> **Device prerequisite:** containers store their image and data on `uvol`
> volumes, so the target needs a uvol storage backend before any container can be
> installed. Setting one up (autopart on eMMC, a manual VG on external storage, or
> `rootfs_data_max` on NAND) is covered in [docs/uvol-storage.md](docs/uvol-storage.md).

## How it works

```
crane pull (Download, online)        -> dl/<pkg>-<ver>-image.tar   (docker-archive, pinned by digest)
crane export + gen-oci-config.uc     -> bundle/{config.json,rootfs/} (Compile, offline)
mksquashfs / mkfs.erofs              -> image.<fstype>                (content sealed)
sha256(image)                        -> the volume name (name == H(content))
apk package: uvol/<hash> + /etc/uxc/<name>.json
```

On the device, `apk add` routes the `uvol/<hash>` payload to
`uvol create/write/up`, mounting the bundle at `/tmp/run/uvol/<hash>`. The
shipped `/etc/uxc/<name>.json` registers the container; `uxc start <name>`
assembles the overlay (read-only image lower + ephemeral tmpfs upper), wires the
network from the `config.json` annotations (`uxc-net`), and auto-creates any
per-path persistent volumes declared by the image.

Only the **Download** phase has network access; the image is vendored into
`dl/` by digest, and everything after is reproducible and offline.

## Components

- `crane/`         - host tool (go-containerregistry), built via `golang/host`.
- `files/gen-oci-config.uc` - generates the OCI runtime `config.json` from the
  image config and a per-package `manifest.json`.
- `include/container.mk` (in the OpenWrt tree) - the `BuildContainer` macro and
  the `oci` download method.

## Adding a container

`BuildContainer` is the package template (the container-image analogue of
`GoPackage`/`Py3Package`): set the `PKG_*`/`CONTAINER_*` variables and call it;
the package fields default from the `CONTAINER_*` template knobs, so a Makefile
is just metadata.

Create `<name>/Makefile`:

```make
include $(TOPDIR)/rules.mk
PKG_NAME:=myapp
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
CONTAINER_IMAGE:=org/myapp
CONTAINER_IMAGE_DIGEST:=sha256:...
CONTAINER_TITLE:=My app
include $(INCLUDE_DIR)/container.mk
$(eval $(call BuildContainer,myapp))
```

and `<name>/manifest.json` describing the deployment:

```json
{
  "name": "myapp",
  "hostname": "myapp",
  "network": { "mode": "bridged", "access_interface": "lan", "netifd": true },
  "volumes": { "data": { "path": "/var/lib/myapp", "size": "256M" } }
}
```

Pin the digest with `crane digest org/myapp:tag`. A package may still define its
own `Package/<name>` / `Package/<name>/install` to fully override the template.

### Registries

Any OCI-compliant registry works (verified: Docker Hub, `ghcr.io`, `quay.io`,
`registry.k8s.io`). Put the full path in `CONTAINER_IMAGE`; Docker Hub is the
implicit default when no host is given:

```make
CONTAINER_IMAGE:=ghcr.io/org/myapp        # GitHub Container Registry
CONTAINER_IMAGE:=quay.io/org/myapp        # Quay
CONTAINER_IMAGE:=myapp                     # Docker Hub (library/myapp)
```

### Autostart

By default (`CONTAINER_AUTOSTART:=1`) the package's apk post-install enables the
container on boot and starts it immediately (`uxc enable` + `uxc create` +
`uxc start`, skipped in an offline image-build root). Set
`CONTAINER_AUTOSTART:=0` for the exception: ship the registration but neither
enable nor start it (the operator starts it by hand).

### Knobs

- `CONTAINER_NAME`        - container name (default `$(PKG_NAME)`).
- `CONTAINER_ROOTFS_TYPE` - `squashfs` (default) or `erofs`.
- `CONTAINER_OVERLAY` - whole-root writable layer: `none` (default), `tmpfs[:size]` or `persistent[:size]`.
- `CONTAINER_AUTOSTART`   - `1` (default) enable+start on install; `0` to opt out.
- `CONTAINER_TITLE` / `CONTAINER_URL` / `CONTAINER_DESCRIPTION` / `CONTAINER_DEPENDS`
  - package template fields (extra `DEPENDS` beyond `@USE_APK +uxc +block-mount`).

### A note on in-jail netifd

A Docker image generally does **not** configure its own network - it expects the
orchestrator to set up the interface. Most images (e.g. pihole, inspected: no
DHCP client, nothing touching `eth0`) therefore need `"netifd": true` so the
in-jail netifd acts as the DHCP client and obtains the bridged LAN address. Only
set `"netifd": false` for an image that runs its own DHCP client / network
setup, or a self-contained appliance that does not need an address from the LAN.

### manifest.json fields

- `network.mode`              - `bridged` or `dedicated`.
- `network.access_interface`  - host interface/zone to attach to.
- `network.netifd`            - run the in-jail netifd (DHCP client) when true.
- `network.port_mapping`      - `proto/extPort:intPort` (comma separated), for dedicated.
- `volumes.<id>`              - `{ "path": "...", "size": "64M" }` persistent per-path volume.
- `env`, `args`, `readonly`, `hostname` - process overrides (default from the image).

## Demo containers

- `traefik-whoami` - tiny HTTP echo; the smoke test for the whole pipeline.
- `pihole`         - network-wide DNS ad blocker.
- `influxdb`       - time series database (storage backend).
- `prometheus`     - metrics collection (writes to influxdb).
- `grafana`        - dashboards over prometheus/influxdb.
