#!/usr/bin/env ucode
// Render the OCI linux.seccomp profile for one target platform.
//
// Three profile modes (CONTAINER_SECCOMP_PROFILE):
//   tight   (default) base.json resolved for the arch, MINUS tighten.list, PLUS
//           CONTAINER_SECCOMP_ALLOW. The shared hardened floor.
//   relaxed base.json resolved for the arch with NO tightening - the full Podman
//           default (cap-gated groups still dropped, the floor holds zero caps).
//           For do-anything containers like a shell + package manager (termux).
//   custom  a packager-supplied seccomp-object file (CONTAINER_SECCOMP_PROFILE set
//           to its path): the OCI linux.seccomp object is used verbatim, so it may
//           carry per-argument filters and per-syscall actions. architectures are
//           pinned to the target and CONTAINER_SECCOMP_ALLOW is appended. The
//           loader/init startup set is supplied by ujail's phase bases, so a
//           container-exact file need only list the workload's runtime syscalls.
//
// Allow-list model: defaultAction is SCMP_ACT_ERRNO, so a syscall is denied
// unless a group lists it. CONTAINER_SECCOMP_ALLOW additions take precedence:
// they are removed from the base groups and re-added as ALLOW, so a listed
// syscall is permitted even if tighten.list would otherwise drop it
// (publisher-trusted opt-in, like the LICENSE field).
//
// Imported by oci-policy.uc; render() returns the linux.seccomp object.
'use strict';

import { readfile } from 'fs';

let read_json = function(p) {
	let r = readfile(p);
	if (r == null)
		die("seccomp: cannot read " + p);
	return json(r);
};

let platmap = {
	"linux/amd64":    { scmp: "SCMP_ARCH_X86_64",     arch: "amd64",   subarch: [] },
	"linux/arm64":    { scmp: "SCMP_ARCH_AARCH64",    arch: "arm64",   subarch: [] },
	"linux/arm/v7":   { scmp: "SCMP_ARCH_ARM",        arch: "arm",     subarch: [] },
	"linux/arm/v6":   { scmp: "SCMP_ARCH_ARM",        arch: "arm",     subarch: [] },
	"linux/arm":      { scmp: "SCMP_ARCH_ARM",        arch: "arm",     subarch: [] },
	"linux/386":      { scmp: "SCMP_ARCH_X86",        arch: "x86",     subarch: [] },
	"linux/riscv64":  { scmp: "SCMP_ARCH_RISCV64",    arch: "riscv64", subarch: [] },
};

export function render(base_path, tighten_path, platform, allow, mode, custom_path) {
	let p = platmap[platform];
	if (!p)
		die("seccomp: unsupported platform '" + platform + "' (known: " + join(", ", keys(platmap)) + ")");

	let base = read_json(base_path);
	let default_errno = base.defaultErrnoRet;

	let arches = [ p.scmp ];
	for (let s in p.subarch)
		push(arches, s);

	if (mode == null || mode == "")
		mode = "tight";
	if (mode != "tight" && mode != "relaxed" && mode != "custom")
		die("seccomp: unknown profile mode '" + mode + "' (tight, relaxed, or a file)");

	let add = {}, add_list = [];
	for (let n in (allow ?? [])) {
		if (n != null && n != "" && !add[n]) {
			add[n] = true;
			push(add_list, n);
		}
	}

	// custom: a packager-supplied OCI linux.seccomp object (the workload's runtime
	// profile; the loader/init startup set is supplied by ujail's phase bases and
	// revoked at main). Used verbatim - it may carry per-argument filters and
	// per-syscall actions - with the architectures pinned to this platform and the
	// CONTAINER_SECCOMP_ALLOW additions appended as one ALLOW group.
	if (mode == "custom") {
		if (!custom_path)
			die("seccomp: custom profile selected but no file given");
		let obj = read_json(custom_path);
		delete obj._comment;
		obj.architectures = arches;
		if (obj.defaultAction == null)
			obj.defaultAction = "SCMP_ACT_ERRNO";
		if (default_errno != null && obj.defaultErrnoRet == null)
			obj.defaultErrnoRet = default_errno;
		if (length(add_list)) {
			if (obj.syscalls == null)
				obj.syscalls = [];
			push(obj.syscalls, { names: add_list, action: "SCMP_ACT_ALLOW" });
		}
		return obj;
	}

	let drop = {};
	if (mode != "relaxed") {
		let raw = readfile(tighten_path) ?? "";
		for (let line in split(raw, "\n")) {
			let t = trim(line);
			if (t == "" || substr(t, 0, 1) == "#")
				continue;
			let tok = split(t, /[ \t]+/)[0];
			if (tok != null && tok != "" && substr(tok, 0, 1) != "@")
				drop[tok] = true;
		}
	}

	let arch_ok = function(inc) {
		if (!inc || !length(inc.arches))
			return true;
		for (let a in inc.arches)
			if (a == p.arch)
				return true;
		return false;
	};

	let out_syscalls = [];
	for (let g in base.syscalls) {
		let inc = g.includes ?? {};

		if (length(inc.caps))
			continue;
		if (!arch_ok(inc))
			continue;

		let names = [];
		for (let n in g.names)
			if (!drop[n] && !add[n])
				push(names, n);
		if (!length(names))
			continue;

		let entry = { names: names, action: g.action };
		if (g.errnoRet != null)
			entry.errnoRet = g.errnoRet;
		if (length(g.args))
			entry.args = g.args;

		push(out_syscalls, entry);
	}

	if (length(add_list))
		push(out_syscalls, { names: add_list, action: "SCMP_ACT_ALLOW" });

	let out = {
		defaultAction: "SCMP_ACT_ERRNO",
		architectures: arches,
		syscalls: out_syscalls,
	};
	if (default_errno != null)
		out.defaultErrnoRet = default_errno;

	return out;
}
