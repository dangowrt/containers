#!/usr/bin/env ucode
// emit the uxc registration, merging base fields with the volume/overlay spec
//   gen-registration.uc <out> <spec> <name> <image> <digest> <path> <tmpfs> <autostart>
'use strict';

import { readfile, writefile } from 'fs';

let out = ARGV[0];
let spec_path = ARGV[1];

if (!out)
	die("usage: gen-registration.uc <out> <spec> <name> <image> <digest> <path> <tmpfs> <autostart>");

let reg = {
	name: ARGV[2],
	image: ARGV[3],
	"image-digest": ARGV[4],
	path: ARGV[5],
	origin: "package",
	autostart: (ARGV[7] == "true"),
};

if (ARGV[6] && ARGV[6] != "")
	reg["temp-overlay-size"] = ARGV[6];

if (spec_path && spec_path != "") {
	let raw = readfile(spec_path);
	if (raw != null) {
		let spec = json(raw);
		for (let k, v in spec)
			reg[k] = v;
	}
}

if (writefile(out, sprintf("%.J\n", reg)) == null)
	die("cannot write " + out);
