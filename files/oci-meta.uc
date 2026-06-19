#!/usr/bin/env ucode
// Resolve an OCI image layout to the blob paths the sealer needs, without any
// Go tooling. Selects the platform's manifest from the index, then prints:
//   line 1      - absolute path to the image config blob
//   lines 2..n  - absolute paths to the layer blobs, lowest layer first
//
//   oci-meta.uc <layout-dir> [platform]   (platform e.g. "linux/amd64")
'use strict';

import { readfile } from 'fs';

let layout = ARGV[0];
let platform = ARGV[1];

if (!layout)
	die("usage: oci-meta.uc <layout-dir> [os/arch]");

let read_json = function(p) {
	let raw = readfile(p);
	if (raw == null)
		die("cannot read " + p);
	return json(raw);
};

let blob = function(digest) {
	let parts = split(digest, ":");
	return layout + "/blobs/" + parts[0] + "/" + parts[1];
};

let index = read_json(layout + "/index.json");
let manifests = index.manifests ?? [];
if (!length(manifests))
	die("no manifests in index.json");

let want_os, want_arch;
if (platform) {
	let p = split(platform, "/");
	want_os = p[0];
	want_arch = p[1];
}

let chosen = null;
for (let m in manifests) {
	let pl = m.platform ?? {};
	if (want_arch == null || (pl.os == want_os && pl.architecture == want_arch)) {
		chosen = m;
		break;
	}
}
chosen ??= manifests[0];

let manifest = read_json(blob(chosen.digest));
if (!manifest.config || !manifest.layers)
	die("manifest has no config/layers");

print(blob(manifest.config.digest) + "\n");
for (let l in manifest.layers)
	print(blob(l.digest) + "\n");
