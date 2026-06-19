# Providing uvol storage for containers

Container packages keep their image and data on **uvol** volumes. Before any
container can be installed, the device needs a uvol *storage backend*. If none is
configured, `apk add container-<name>` aborts with:

```
uxc: cannot install '<name>': the uvol metadata volume is not mounted at /tmp/run/uvol/.meta
uxc: no usable uvol backend; install 'autopart' (block), or provision an LVM VG / UBI space for uvol
```

uvol (pulled in as a dependency of every container package) needs somewhere to
create volumes. It supports two backend types:

- **LVM**, on block storage (eMMC, SD, SATA, USB, NVMe). uvol uses a volume group
  (VG). It auto-detects a VG on the *boot* device; a VG on any *other* device must
  be named in UCI.
- **UBI**, on raw NAND. uvol uses the *free* eraseblocks of the UBI device, so
  some UBI space must be left unallocated by `rootfs_data`.

Pick the path that matches your storage. Once a backend exists, uvol creates its
metadata volume automatically on the next boot (the `/tmp/run/uvol/.meta`
symlink appears) and container installs succeed.

---

## 1. `autopart` on the boot device (eMMC / SD / SATA)

The simplest path when the system boots from a block device that has unused
space. The `autopart` package claims that free space for uvol automatically.

```sh
apk update && apk add autopart
reboot
```

On the next boot its one-shot uci-default (`/etc/uci-defaults/30-autopart`)
finds the boot disk, claims the first free region (at least 100 MB) as an LVM
partition named `owrt-volumes`, and creates a VG `owrt-volumes-<diskhash>` on it.
uvol auto-detects a VG on the boot device, so no further configuration is needed.

Requirements and notes:

- There must be **unpartitioned free space** on the boot disk. Images leave room
  only if the root partition was not grown to fill the disk; if the disk is full,
  shrink/repartition to leave at least 100 MB free first.
- The uci-default runs once and is then removed (whether or not it succeeded). To
  re-run it after making space, re-extract the package with `apk fix autopart`
  and reboot, or create the VG by hand (see path 2).

---

## 2. A manual VG on additional storage (USB, NVMe, ...), configured in UCI

Use this for storage that is **not** the boot device. uvol only auto-detects a VG
on the boot device, so a VG anywhere else must be declared in UCI.

Create the VG (install `lvm2` if it is not already present):

```sh
apk add lvm2
pvcreate /dev/sda            # a whole disk, or a partition such as /dev/sda1
vgcreate containers /dev/sda
```

Point uvol at it in `/etc/config/fstab`:

```
config uvol
	option vg_name 'containers'
```

A `vg_name` configured here takes priority over boot-device auto-detection, so
this also works to select a specific VG on a multi-disk system. Reboot (or
re-run `uvol boot`) and verify with `uvol list`.

Notes:

- The device must be attached and the VG visible at boot, before uvol comes up,
  otherwise `.meta` cannot be created on it.

---

## 3. `rootfs_data_max` on raw NAND (UBI)

On UBI devices uvol uses the UBI device's free eraseblocks. By default the
`rootfs_data` volume is created at *maximum* size (`ubimkvol -m`), filling the UBI
and leaving nothing for uvol. The `rootfs_data_max` U-Boot environment variable
caps it, freeing the remainder for uvol.

It is honoured in two places, so it does not depend on a particular bootloader:

- **OpenWrt's NAND sysupgrade** (`/lib/upgrade/nand.sh`): when it (re)creates
  `rootfs_data` it reads `rootfs_data_max` and uses `ubimkvol -s <size>` instead
  of `-m`, falling back to `-m` if the sized create fails.
- **Some bootloaders** (notably MediaTek U-Boot): `ubi create rootfs_data
  $rootfs_data_max dynamic` when the volume does not yet exist.

Set it with `fw_setenv` (a byte size, decimal or hex). Where this applies the
tools are already in place: `uboot-envtools` is part of the default install on
these targets and writes `/etc/fw_env.config` automatically.

```sh
fw_setenv rootfs_data_max 0x1000000     # cap rootfs_data at 16 MiB (usually enough for config)
```

It applies when `rootfs_data` is recreated. The general way is a **sysupgrade**:
the NAND upgrade removes and recreates `rootfs_data`, sizing it from the
variable, while your settings are preserved by sysupgrade's normal config
backup/restore:

```sh
sysupgrade <image>            # rootfs_data recreated at the capped size
```

On a bootloader that recreates `rootfs_data` at boot, a factory reset is an
alternative (`firstboot && reboot now`).

After it, the freed eraseblocks are available to uvol.

Notes:

- Setting the variable alone does nothing; an existing full-size `rootfs_data`
  is not shrunk until it is recreated.
- Recreating `rootfs_data` resets the overlay (as any sysupgrade/factory reset
  does); only the files sysupgrade backs up are carried over.

---

## Verifying the backend

```sh
uvol list                       # succeeds (list may be empty) once a backend exists;
                                # prints "No backend available" if there is none
ls -l /tmp/run/uvol/.meta       # a symlink into /tmp/run/blockd once uvol has come up
```

For LVM, `vgs` / `lvs` show the VG and volumes; for UBI, `ubinfo -a` shows the
device and its free eraseblocks. Once `/tmp/run/uvol/.meta` exists,
`apk add container-<name>` works.
