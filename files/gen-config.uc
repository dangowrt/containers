#!/usr/bin/env ucode
// Build an OCI runtime config.json from an image config blob, reproducing the
// static defaults umoci's runtime-tools generator used (mounts, masked/readonly
// paths) plus the image-derived process fields. process.user is resolved against
// the flattened rootfs so named users (e.g. "nobody") map to the right ids.
// oci-policy.uc stamps the security floor (caps, seccomp, userns, ...) on top.
//
//   gen-config.uc <image-config-blob> <rootfs-dir> <hostname> <out-config.json>
'use strict';

import { readfile, writefile } from 'fs';

let cfg_blob = ARGV[0];
let rootfs = ARGV[1];
let hostname = ARGV[2];
let out_path = ARGV[3];

if (!cfg_blob || !rootfs || !out_path)
	die("usage: gen-config.uc <image-config-blob> <rootfs-dir> <hostname> <out-config.json>");

let read_json = function(p) {
	let raw = readfile(p);
	if (raw == null)
		die("cannot read " + p);
	return json(raw);
};

let str_array = function(val) {
	let out = [];
	if (type(val) == "array")
		for (let v in val)
			push(out, v);
	return out;
};

let all_digits = function(s) {
	if (s == null || s == "")
		return false;
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		if (c < "0" || c > "9")
			return false;
	}
	return true;
};

// look a name up in a colon-separated passwd/group table; return the id field
let lookup_id = function(path, name) {
	let raw = readfile(path);
	if (raw == null)
		return null;
	for (let line in split(raw, "\n")) {
		let f = split(line, ":");
		if (f[0] == name)
			return int(f[2]);
	}
	return null;
};

let resolve_user = function(spec) {
	let u = { uid: 0, gid: 0 };
	if (spec == null || spec == "")
		return u;

	let parts = split(spec, ":");
	let uname = parts[0];
	let gname = parts[1];

	if (all_digits(uname)) {
		u.uid = int(uname);
		u.gid = u.uid;
	} else {
		let raw = readfile(rootfs + "/etc/passwd");
		let found = null;
		for (let line in split(raw ?? "", "\n")) {
			let f = split(line, ":");
			if (f[0] == uname) {
				found = f;
				break;
			}
		}
		if (found) {
			u.uid = int(found[2]);
			u.gid = int(found[3]);
		}
	}

	if (gname != null) {
		if (all_digits(gname))
			u.gid = int(gname);
		else {
			let g = lookup_id(rootfs + "/etc/group", gname);
			if (g != null)
				u.gid = g;
		}
	}

	return u;
};

let full = read_json(cfg_blob);
let image = full.config ?? {};

// surface the image's declared ExposedPorts as an ingress hint for the req-tags
// (read back by container.mk); the actual ingress policy is CONTAINER_INGRESS.
let ports_out = ARGV[4];
if (ports_out && type(image.ExposedPorts) == "object") {
	let ports = sort(keys(image.ExposedPorts));
	if (length(ports))
		writefile(ports_out, "openwrt.req:ports=" + join(",", ports));
}

let args = str_array(image.Entrypoint);
for (let c in str_array(image.Cmd))
	push(args, c);
if (!length(args))
	die("image declares no Entrypoint/Cmd");

let env = str_array(image.Env);
if (!length(env))
	push(env, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");

let cwd = image.WorkingDir;
if (cwd == null || cwd == "")
	cwd = "/";

let annotations = {};
if (type(image.Labels) == "object")
	for (let k, v in image.Labels)
		annotations[k] = v;

if (type(image.Volumes) == "object") {
	let vpaths = [];
	for (let p in image.Volumes)
		push(vpaths, p);
	if (length(vpaths))
		annotations["org.openwrt.image.volumes"] = join(",", vpaths);
}

let cfg = {
	ociVersion: "1.2.1",
	process: {
		terminal: false,
		user: resolve_user(image.User),
		args: args,
		env: env,
		cwd: cwd
	},
	root: {
		path: "rootfs"
	},
	hostname: (hostname && hostname != "") ? hostname : "container",
	mounts: [
		{ destination: "/proc", type: "proc", source: "proc" },
		{ destination: "/dev", type: "tmpfs", source: "tmpfs",
		  options: [ "nosuid", "strictatime", "mode=755", "size=65536k" ] },
		{ destination: "/dev/pts", type: "devpts", source: "devpts",
		  options: [ "nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620" ] },
		{ destination: "/dev/shm", type: "tmpfs", source: "shm",
		  options: [ "nosuid", "noexec", "nodev", "mode=1777", "size=65536k" ] },
		{ destination: "/dev/mqueue", type: "mqueue", source: "mqueue",
		  options: [ "nosuid", "noexec", "nodev" ] },
		{ destination: "/sys", type: "bind", source: "/sys",
		  options: [ "rbind", "nosuid", "noexec", "nodev", "ro" ] }
	],
	annotations: annotations,
	linux: {
		namespaces: [
			{ type: "cgroup" },
			{ type: "pid" },
			{ type: "ipc" },
			{ type: "uts" },
			{ type: "mount" },
			{ type: "user" }
		],
		maskedPaths: [
			"/proc/kcore",
			"/proc/latency_stats",
			"/proc/timer_list",
			"/proc/timer_stats",
			"/proc/sched_debug",
			"/sys/firmware",
			"/proc/scsi"
		],
		readonlyPaths: [
			"/proc/asound",
			"/proc/bus",
			"/proc/fs",
			"/proc/irq",
			"/proc/sys",
			"/proc/sysrq-trigger"
		]
	}
};

if (writefile(out_path, sprintf("%.J\n", cfg)) == null)
	die("cannot write " + out_path);
