#!/usr/bin/env ucode
// Resolve a CONTAINER_DEVICES spec into explicit {type,major,minor} grants at
// build time, using the target kernel's Documentation/admin-guide/devices.txt as
// the authority. Forms:
//   type:major[:minor]   c:4 / c:4:64 / b:8   -> passthrough (minor omitted = -1)
//   /dev/name            /dev/null            -> resolved to type:major:minor
//   /dev/glob*           /dev/ttyS*           -> every documented matching node,
//                                               enumerated to explicit minors
// devices.txt is the source of truth: a left-margin "NNN char|block Description"
// sets the current (major,type); indented "M = /dev/name" lines give minor->name;
// an indented "..." between two name lines interpolates the range when the names
// carry an integer suffix with a constant stride.
//
// Kept narrow on purpose (spec -> [{type,major,minor}]) so a future rst/yaml
// device source can replace parse_devices() without touching the callers.
'use strict';

import { readfile } from 'fs';

function glob_to_re(g) {
	let re = "^";
	for (let i = 0; i < length(g); i++) {
		let c = substr(g, i, 1);
		if (c == "*")
			re += ".*";
		else if (c == "?")
			re += ".";
		else if (index(".^$+{}()[]|\\/", c) >= 0)
			re += "\\" + c;
		else
			re += c;
	}
	return regexp(re + "$");
}

// split a node name into [prefix, integer-suffix] or null when no integer tail
function name_split(n) {
	let i = length(n);
	while (i > 0 && index("0123456789", substr(n, i - 1, 1)) >= 0)
		i--;
	if (i == length(n))
		return null;
	return [ substr(n, 0, i), int(substr(n, i)) ];
}

// parse devices.txt into one node per documented minor; an interpolated "..."
// range between two integer-suffixed names becomes one node per stride step.
function expand(path) {
	let raw = readfile(path);
	if (raw == null)
		die("cannot read " + path);

	let out = [];
	let type = null, major = null, prev = null, ell = false;

	let interp = function(a, b) {
		// a, b: { minor, name, split }; emit a..b inclusive
		if (a.split && b.split && a.split[0] == b.split[0]) {
			let dn = b.split[1] - a.split[1];
			let dm = b.minor - a.minor;
			if (dn > 0 && dm % dn == 0) {
				let step = dm / dn;
				for (let k = 0; k <= dn; k++)
					push(out, { type: type, major: major,
						minor: a.minor + k * step,
						name: a.split[0] + (a.split[1] + k) });
				return true;
			}
		}
		// non-numeric / irregular series: keep only the documented anchors
		push(out, { type: type, major: major, minor: a.minor, name: a.name });
		push(out, { type: type, major: major, minor: b.minor, name: b.name });
		return false;
	};

	for (let line in split(raw, "\n")) {
		let h = match(line, /^[ \t]*([0-9]+)[ \t]+(char|block)\b/);
		if (h) {
			major = int(h[1]);
			type = (h[2] == "block") ? "b" : "c";
			prev = null; ell = false;
			continue;
		}
		if (type == null)
			continue;

		let e = match(line, /^[ \t]+([0-9]+)[ \t]*=[ \t]*\/dev\/(\S+)/);
		if (e) {
			let cur = { minor: int(e[1]), name: e[2], split: name_split(e[2]) };
			if (ell && prev)
				interp(prev, cur);
			else
				push(out, { type: type, major: major, minor: cur.minor, name: cur.name });
			prev = cur; ell = false;
			continue;
		}

		if (match(line, /^[ \t]+\.\.\.[ \t]*$/) && prev) {
			ell = true;
			continue;
		}

		if (match(line, /^[ \t]*$/)) {
			prev = null; ell = false;
		}
	}

	return out;
}

// resolve a single spec word against the (lazily parsed) node table.
// returns a list of { type, major, minor } (minor == -1 means wildcard).
function resolve(spec, nodes) {
	let m = match(spec, /^([cb]):([0-9]+)(:([0-9]+))?$/);
	if (m)
		return [ { type: m[1], major: int(m[2]),
			minor: (m[4] != null) ? int(m[4]) : -1 } ];

	let dev = match(spec, /^\/dev\/(.+)$/);
	if (!dev)
		die(sprintf("devices: unrecognised CONTAINER_DEVICES entry '%s'", spec));
	let pat = dev[1];

	let globby = (index(pat, "*") >= 0 || index(pat, "?") >= 0);
	let out = [], seen = {};

	if (!globby) {
		for (let n in nodes)
			if (n.name == pat)
				return [ { type: n.type, major: n.major, minor: n.minor } ];
		die(sprintf("devices: '/dev/%s' not found in devices.txt", pat));
	}

	let re = glob_to_re(pat);
	for (let n in nodes) {
		if (!match(n.name, re))
			continue;
		let key = n.type + ":" + n.major + ":" + n.minor;
		if (seen[key])
			continue;
		seen[key] = true;
		push(out, { type: n.type, major: n.major, minor: n.minor });
	}
	if (!length(out))
		die(sprintf("devices: glob '/dev/%s' matched no node in devices.txt", pat));
	sort(out, function(a, b) {
		if (a.major != b.major) return a.major - b.major;
		return a.minor - b.minor;
	});
	return out;
}

// public entry point. spec is one CONTAINER_DEVICES word; devpath is the
// devices.txt path. returns [ { type, major, minor } ] (minor -1 = whole major).
export function expand_device(spec, devpath) {
	return resolve(spec, expand(devpath));
}

// expand many specs in one pass over devices.txt (preferred by oci-policy.uc).
export function expand_devices(specs, devpath) {
	let nodes = expand(devpath), out = [];
	for (let s in specs)
		for (let g in resolve(s, nodes))
			push(out, g);
	return out;
}
