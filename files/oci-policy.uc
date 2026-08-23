#!/usr/bin/env ucode
// Apply the container policy floor + per-package exceptions over the generated
// OCI config.json (gen-config.uc). The floor is deliberately tight; the package
// Makefile's CONTAINER_* knobs (rendered into the key=value policy file) relax
// specific points. Floor:
//   - zero capabilities
//   - noNewPrivileges
//   - all namespaces (incl. user)
//   - user namespace mapping enumerated container ids to static host ids (USERID)
//   - a memory limit (if given)
//   - deny-by-default device cgroup (ujail re-adds the standard nodes)
//
//   - an arch-rendered seccomp allow-list (floor + CONTAINER_SECCOMP_ALLOW)
//
//   oci-policy.uc <config.json> <policy.kv> <platform> <seccomp-base.json> <seccomp-tighten.list>
'use strict';

import { readfile, writefile } from 'fs';
import { render as render_seccomp } from './seccomp-render.uc';
import { expand_devices } from './devices.uc';

let cfg_path = ARGV[0];
let pol_path = ARGV[1];
let platform = ARGV[2];
let seccomp_base = ARGV[3];
let seccomp_tighten = ARGV[4];
let owners_path = ARGV[5];
let vol_out = ARGV[6];

if (!cfg_path || !pol_path)
	die("usage: oci-policy.uc <config.json> <policy.kv> <platform> <seccomp-base.json> <seccomp-tighten.list> [owners.txt]");

let read_json = function(p) {
	let r = readfile(p);
	if (r == null)
		die("cannot read " + p);
	return json(r);
};

let read_policy = function(p) {
	let raw = readfile(p) ?? "";
	let pol = {};
	for (let line in split(raw, "\n")) {
		let eq = index(line, "=");
		if (eq < 0)
			continue;
		pol[substr(line, 0, eq)] = trim(substr(line, eq + 1));
	}
	return pol;
};

let words = function(s) {
	let out = [];
	if (!s)
		return out;
	for (let w in split(trim(s), /[ \t]+/))
		if (w != "")
			push(out, w);
	return out;
};

let cfg = read_json(cfg_path);
let pol = read_policy(pol_path);

let owner_ids = [];
if (owners_path) {
	let raw = readfile(owners_path) ?? "";
	for (let line in split(raw, "\n")) {
		let f = split(trim(line), /[ \t]+/);
		for (let n in f) {
			let v = int(n);
			if (v != null && v >= 0)
				push(owner_ids, v);
		}
	}
}

cfg.process = cfg.process ?? {};
cfg.linux = cfg.linux ?? {};
cfg.linux.resources = cfg.linux.resources ?? {};
cfg.annotations = cfg.annotations ?? {};

cfg.process.noNewPrivileges = (pol.nnp != "0");

// override the image's baked entrypoint args (e.g. prometheus agent mode); baked
// into the content-addressed config so it stays deterministic
if (pol.command && pol.command != "")
	cfg.process.args = words(pol.command);

// W^X floor: deny gaining executable mappings (mprotect PROT_EXEC on writable
// memory, mmap PROT_WRITE|PROT_EXEC). Inherited across forks (no no_inherit), so
// the whole process tree is covered. Opt out with CONTAINER_MDWE=0 for a JIT/
// interpreter image that genuinely needs writable-executable memory.
if (pol.mdwe != "0")
	cfg.annotations["org.openwrt.ujail.mdwe"] = "refuse_exec_gain";

cfg.process.oomScoreAdj = pol.oom_score_adj ? int(pol.oom_score_adj) : 500;

cfg.process.rlimits = [ { type: "RLIMIT_CORE", hard: 0, soft: 0 } ];
let nofile = pol.nofile ? int(pol.nofile) : 1024;
if (nofile > 0)
	push(cfg.process.rlimits, { type: "RLIMIT_NOFILE", hard: nofile, soft: nofile });

let caps = [];
for (let c in words(pol.caps)) {
	c = uc(c);
	if (substr(c, 0, 4) != "CAP_")
		c = "CAP_" + c;
	push(caps, c);
}
// caps a workload still needs after it drops privileges to its own user inside
// the container (e.g. an s6/init image whose daemon binds a privileged port and
// then setuids): these go in the ambient set so they survive the drop, and are
// granted to the root phase too. A container that already runs non-root keeps
// its whole declared set ambient.
let acaps = [];
for (let c in words(pol.caps_ambient)) {
	c = uc(c);
	if (substr(c, 0, 4) != "CAP_")
		c = "CAP_" + c;
	push(acaps, c);
	if (index(caps, c) < 0)
		push(caps, c);
}
let nonroot = (cfg.process.user?.uid ?? 0) != 0;
cfg.process.capabilities = {
	bounding: caps,
	permitted: caps,
	effective: caps,
	inheritable: nonroot ? caps : acaps,
	ambient: nonroot ? caps : acaps,
};

let want_ns = [ "pid", "mount", "ipc", "uts", "network", "user", "cgroup", "time" ];
if (pol.net == "host")
	want_ns = filter(want_ns, function(t) { return t != "network"; });
cfg.linux.namespaces = cfg.linux.namespaces ?? [];
let have_ns = {};
for (let n in cfg.linux.namespaces)
	have_ns[n.type] = true;
for (let t in want_ns)
	if (!have_ns[t])
		push(cfg.linux.namespaces, { type: t });

let parse_userid = function(s) {
	if (!s)
		return null;
	let parts = split(s, ":");
	let u = split(parts[0] ?? "", "=");
	let g = split(parts[1] ?? parts[0] ?? "", "=");
	let ub = int(length(u) > 1 ? u[1] : u[0]);
	let gb = int(length(g) > 1 ? g[1] : g[0]);
	if (ub == null || ub < 0)
		return null;
	return [ ub, (gb == null || gb < 0) ? ub : gb ];
};

let base = parse_userid(pol.userid);
if (base) {
	let ids = [ 0 ], seen = { "0": true };
	let add_id = function(n) {
		if (n == null || n < 0)
			return;
		let k = "" + n;
		if (!seen[k]) {
			push(ids, n);
			seen[k] = true;
		}
	};
	for (let x in words(pol.userns_ids))
		add_id(int(x));
	for (let n in owner_ids)
		add_id(n);
	sort(ids, function(a, b) { return a - b; });
	let umap = [], gmap = [], i = 0;
	for (let cid in ids) {
		push(umap, { containerID: cid, hostID: base[0] + i, size: 1 });
		push(gmap, { containerID: cid, hostID: base[1] + i, size: 1 });
		i++;
	}
	cfg.linux.uidMappings = umap;
	cfg.linux.gidMappings = gmap;
} else {
	warn("oci-policy: no CONTAINER_USERID set; container will NOT be rootless\n");
	let ns = [];
	for (let n in cfg.linux.namespaces)
		if (n.type != "user")
			push(ns, n);
	cfg.linux.namespaces = ns;
}

if (pol.memory) {
	let m = pol.memory, last = substr(m, length(m) - 1);
	if (last == "%") {
		cfg.annotations["org.openwrt.cgroup.memory.pct"] = substr(m, 0, length(m) - 1);
	} else {
		let mult = 1048576, numstr = m;
		if (last == "k" || last == "K") { mult = 1024; numstr = substr(m, 0, length(m) - 1); }
		else if (last == "m" || last == "M") { mult = 1048576; numstr = substr(m, 0, length(m) - 1); }
		else if (last == "g" || last == "G") { mult = 1073741824; numstr = substr(m, 0, length(m) - 1); }
		let num = int(numstr);
		if (num != null && num > 0) {
			cfg.linux.resources.memory = cfg.linux.resources.memory ?? {};
			cfg.linux.resources.memory.limit = num * mult;
			cfg.linux.resources.memory.swap = num * mult;
		}
	}
}

let pids = pol.pids ? int(pol.pids) : 256;
if (pids > 0) {
	cfg.linux.resources.pids = cfg.linux.resources.pids ?? {};
	cfg.linux.resources.pids.limit = pids;
}

if (pol.cpu || pol.cpuset) {
	cfg.linux.resources.cpu = cfg.linux.resources.cpu ?? {};
	if (pol.cpu) {
		let c = pol.cpu;
		let pct = int(substr(c, length(c) - 1) == "%" ? substr(c, 0, length(c) - 1) : c);
		if (pct != null && pct > 0) {
			cfg.linux.resources.cpu.period = 100000;
			cfg.linux.resources.cpu.quota = pct * 1000;
		}
	}
	if (pol.cpuset)
		cfg.linux.resources.cpu.cpus = pol.cpuset;
}

let devs = [ { allow: false, type: "a", access: "rwm" } ];
let dev_specs = words(pol.devices);
// with the kernel devices.txt available, resolve every form (type:major[:minor],
// /dev/name, /dev/glob*) to explicit numeric grants; without it, only the
// already-numeric form can be honoured.
let dev_txt = (length(dev_specs) && pol.devices_txt) ? readfile(pol.devices_txt) : null;
if (dev_txt != null) {
	for (let g in expand_devices(dev_specs, pol.devices_txt)) {
		let dev = { allow: true, type: g.type, major: g.major, access: "rwm" };
		if (g.minor >= 0)
			dev.minor = g.minor;
		push(devs, dev);
	}
} else {
	for (let d in dev_specs) {
		let m = match(d, /^([cb]):([0-9]+)(:([0-9]+))?$/);
		if (!m) {
			warn(sprintf("oci-policy: device '%s' needs the kernel devices.txt to resolve a name/glob; only type:major[:minor] works without it\n", d));
			continue;
		}
		let dev = { allow: true, type: m[1], major: int(m[2]), access: "rwm" };
		if (m[4] != null)
			dev.minor = int(m[4]);
		push(devs, dev);
	}
}
cfg.linux.resources.devices = devs;

if (platform) {
	if (!seccomp_base || !seccomp_tighten)
		die("oci-policy: platform given but seccomp base/tighten path missing");
	cfg.linux.seccomp = render_seccomp(seccomp_base, seccomp_tighten, platform,
		words(pol.seccomp_allow), pol.seccomp_profile, pol.seccomp_file);
}

// security paths floor: hide sensitive kernel interfaces and force the standard
// /proc control subtrees read-only (the runc/Podman default set), plus the
// per-package additions. The container already gets a private procfs; these
// close the residual host-kernel views and write paths.
let masked = [
	"/proc/asound", "/proc/acpi", "/proc/kcore", "/proc/keys",
	"/proc/latency_stats", "/proc/timer_list", "/proc/timer_stats",
	"/proc/sched_debug", "/proc/scsi", "/sys/firmware",
	"/sys/devices/virtual/powercap",
];
for (let p in words(pol.mask))
	push(masked, p);
cfg.linux.maskedPaths = masked;

let ro_paths = [ "/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger" ];
for (let p in words(pol.ro_paths))
	push(ro_paths, p);
cfg.linux.readonlyPaths = ro_paths;

// sysctl: space-separated key=value pairs into the OCI sysctl table
let sysctls = words(pol.sysctl);
if (length(sysctls)) {
	cfg.linux.sysctl = cfg.linux.sysctl ?? {};
	for (let kv in sysctls) {
		let eq = index(kv, "=");
		if (eq > 0)
			cfg.linux.sysctl[substr(kv, 0, eq)] = substr(kv, eq + 1);
	}
}

// Landlock path allow-lists (colon-joined for ujail's annotation parser)
if (length(words(pol.landlock_ro)))
	cfg.annotations["org.openwrt.ujail.landlock.ro"] = join(":", words(pol.landlock_ro));
if (length(words(pol.landlock_rx)))
	cfg.annotations["org.openwrt.ujail.landlock.rx"] = join(":", words(pol.landlock_rx));
if (length(words(pol.landlock_rw)))
	cfg.annotations["org.openwrt.ujail.landlock.rw"] = join(":", words(pol.landlock_rw));

// writable surface: data volumes, persistent overlay, scratch tmpfs
let san_id = function(path) {
	let parts = split(path, "/"), b = "vol";
	for (let p in parts)
		if (p != "")
			b = p;
	return lc(replace(b, /[^A-Za-z0-9_-]/g, "_"));
};

let volumes = {}, vorder = [];
let add_vol = function(id, path, size) {
	if (!volumes[id])
		push(vorder, id);
	volumes[id] = { path: path, size: size };
};

let imgvols = cfg.annotations["org.openwrt.image.volumes"];
if (imgvols)
	for (let p in split(imgvols, ",")) {
		if (p == "")
			continue;
		let id = san_id(p), uid = id, n = 1;
		while (volumes[uid])
			uid = id + "_" + (n++);
		add_vol(uid, p, null);
	}
delete cfg.annotations["org.openwrt.image.volumes"];

for (let spec in split(pol.volumes ?? "", ",")) {
	spec = trim(spec);
	if (spec == "")
		continue;
	let f = split(spec, ":");
	if (!f[0] || !f[1]) {
		warn(sprintf("oci-policy: bad CONTAINER_VOLUMES entry '%s' (want id:mnt:size)\n", spec));
		continue;
	}
	if (!match(f[0], /^[A-Za-z0-9_][A-Za-z0-9._-]*$/)) {
		warn(sprintf("oci-policy: bad CONTAINER_VOLUMES id '%s'\n", f[0]));
		continue;
	}
	for (let k in vorder)
		if (volumes[k] && volumes[k].path == f[1] && k != f[0])
			delete volumes[k];
	add_vol(f[0], f[1], (f[2] && f[2] != "") ? f[2] : null);
}

// uxc-managed spec -> side file for the registration, not the OCI config
let spec = { "data-volumes": [] };
for (let id in vorder) {
	if (!volumes[id])
		continue;
	push(spec["data-volumes"], {
		name: id,
		mountpoint: volumes[id].path,
		size: (volumes[id].size && volumes[id].size != "") ? volumes[id].size : "64m",
	});
}
if (pol.overlay_mode == "persistent")
	spec["overlay-size"] = (pol.overlay_size && pol.overlay_size != "") ? pol.overlay_size : "64m";

let initenv = {};
for (let tok in words(pol.initenv)) {
	let eq = index(tok, "=");
	if (eq < 0)
		continue;
	initenv[substr(tok, 0, eq)] = substr(tok, eq + 1);
}
if (length(keys(initenv)))
	spec.initenv = initenv;

if (vol_out && (length(spec["data-volumes"]) || spec["overlay-size"] || spec.initenv))
	if (writefile(vol_out, sprintf("%.J\n", spec)) == null)
		die("cannot write " + vol_out);

// networking: uxc-net reads these from config.json at runtime
if (pol.net && pol.net != "" && pol.net != "none")
	cfg.annotations["org.openwrt.network.attach"] = pol.net;
if (pol.egress && pol.egress != "")
	cfg.annotations["org.openwrt.network.egress"] = pol.egress;
if (pol.ingress && pol.ingress != "")
	cfg.annotations["org.openwrt.network.ingress"] = pol.ingress;
if (pol.net_proto && pol.net_proto != "")
	cfg.annotations["org.openwrt.network.proto"] = pol.net_proto;
if (pol.net_proto6 && pol.net_proto6 != "")
	cfg.annotations["org.openwrt.network.proto6"] = pol.net_proto6;
if (pol.net_ip6ifaceid && pol.net_ip6ifaceid != "")
	cfg.annotations["org.openwrt.network.ip6ifaceid"] = pol.net_ip6ifaceid;
if (pol.netifd == "1")
	cfg.annotations["org.openwrt.procd.netifd"] = "true";

// one-shot init: a self-gating OCI startContainer hook
if (pol.init && pol.init != "") {
	let sentinel = (pol.init_sentinel && pol.init_sentinel != "") ? pol.init_sentinel : "/.uxc-initialized";
	let script = sprintf("[ -e '%s' ] || { %s && touch '%s'; }", sentinel, pol.init, sentinel);
	cfg.hooks = cfg.hooks ?? {};
	cfg.hooks.startContainer = [ { path: "/bin/sh", args: [ "/bin/sh", "-c", script ], timeout: 300 } ];
}

if (pol.tmpfs && pol.tmpfs != "") {
	cfg.mounts = cfg.mounts ?? [];
	let have = {};
	for (let m in cfg.mounts)
		have[m.destination] = true;
	let scratch = [ [ "/tmp", "1777" ], [ "/run", "0755" ] ];
	for (let s in scratch)
		if (!have[s[0]])
			push(cfg.mounts, { destination: s[0], type: "tmpfs", source: "tmpfs",
					   options: [ "nosuid", "nodev", "mode=" + s[1], "size=" + pol.tmpfs ] });
}

if (writefile(cfg_path, sprintf("%.J\n", cfg)) == null)
	die("cannot write " + cfg_path);
