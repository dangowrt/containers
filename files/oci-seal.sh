#!/bin/sh
# Flatten an OCI image layout into a sealed rootfs filesystem image, run entirely
# under one fakeroot session so the image's true per-file ownership (faked on
# disk by tar's libc lchown) flows straight into mksquashfs/mkfs.erofs -- no
# pseudo-file, no Go unpack tool. Invoked as:
#
#   fakeroot oci-seal.sh <layout> <bundle> <out-image> <policy.kv> \
#                        <platform> <seccomp-base> <seccomp-tighten> <hostname>
#
# Tool paths and reduction options come from the environment (set by container.mk):
#   UCODE OCI_META_UC GEN_CONFIG_UC OCI_POLICY_UC TAR
#   MKFS_TYPE MKSQUASHFS MKEROFS
#   STRIP_SH STRIP_CLASSES DO_STRIP DO_DEDUP CONTAINER_RM CROSS SSTRIP RSTRIP_SH
set -e

# A jobserver-dispatched worker pass (see the strip section below): classify and
# strip one NUL-delimited batch of candidate paths. STRIP1/SSTRIP1 and the
# file(1) shim on PATH are inherited from the dispatching run.
if [ "$1" = "--strip-batch" ]; then
	set +e
	xargs -0 -a "$2" file -N 2>/dev/null | \
	sed -n 's/^\(.*\):.*ELF.*\(executable\|shared object\).*/\1/p' | \
	while IFS= read -r f; do
		[ -f "$f" ] || continue
		m=$(stat -c %a "$f")
		$STRIP1 "$f" 2>/dev/null
		[ -n "$SSTRIP1" ] && $SSTRIP1 "$f" 2>/dev/null
		n=$(stat -c %a "$f"); [ "$m" = "$n" ] || chmod "$m" "$f"
	done
	exit 0
fi

layout="$1"; bundle="$2"; out="$3"; polkv="$4"
platform="$5"; sccbase="$6"; scctighten="$7"; hostname="$8"
rootfs="$bundle/rootfs"

[ -n "$layout" ] && [ -n "$bundle" ] && [ -n "$out" ] || {
	echo "oci-seal: missing arguments" >&2; exit 1; }

rm -rf "$bundle"
mkdir -p "$rootfs"

# resolve config blob + ordered layer blobs from the layout
"$UCODE" "$OCI_META_UC" "$layout" "$platform" > "$bundle/.meta"
cfgblob="$(sed -n 1p "$bundle/.meta")"
layers="$(sed 1d "$bundle/.meta")"

# anchor SOURCE_DATE_EPOCH to the image's own creation date: the rootfs mtimes
# then clamp to a content-derived constant, so clean and incremental builds seal
# byte-identically (the generic version.date heuristic otherwise drifts in-tree)
created_epoch="$("$UCODE" -e 'import { readfile } from "fs";
let c = json(readfile(ARGV[0]));
let m = c.created ? match(c.created, /^([0-9]+)-([0-9]+)-([0-9]+)T([0-9]+):([0-9]+):([0-9]+)/) : null;
if (m) print(timegm({ year:+m[1], mon:+m[2], mday:+m[3], hour:+m[4], min:+m[5], sec:+m[6] }));
' -- "$cfgblob" 2>/dev/null)"
if [ -n "$created_epoch" ]; then
	export SOURCE_DATE_EPOCH="$created_epoch"
fi

# flatten the layers, lowest first, honouring OCI whiteouts
for layer in $layers; do
	"$TAR" -tf "$layer" 2>/dev/null | while IFS= read -r entry; do
		case "$entry" in
		*/.wh..wh..opq | .wh..wh..opq)
			dir="${entry%.wh..wh..opq}"
			[ -d "$rootfs/$dir" ] && \
				find "$rootfs/$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
			;;
		*/.wh.* | .wh.*)
			base="${entry##*/}"; dir="${entry%"$base"}"
			rm -rf "$rootfs/$dir${base#.wh.}"
			;;
		esac
	done
	"$TAR" -xf "$layer" -C "$rootfs" --exclude='.wh.*' --exclude='*/.wh.*' 2>/dev/null || true
done

# enumerate the image's true (faked) owner set for the userns mapping
find "$rootfs" -printf '%U %G\n' | sort -u > "$bundle/owners.txt"

# build the runtime config.json, then stamp the security floor on top. The
# uxc-managed volume/overlay spec lands outside the bundle (not sealed) for the
# registration step.
volout="$(dirname "$out")/uxc-volumes.json"
portstag="$(dirname "$out")/exposed-ports.tag"
rm -f "$volout" "$portstag"
"$UCODE" "$GEN_CONFIG_UC" "$cfgblob" "$rootfs" "$hostname" "$bundle/config.json" "$portstag"
"$UCODE" "$OCI_POLICY_UC" "$bundle/config.json" "$polkv" "$platform" \
	"$sccbase" "$scctighten" "$bundle/owners.txt" "$volout"

# Every top-level directory mount the config declares must already exist as a
# mountpoint in the read-only sealed rootfs: ujail cannot create it at runtime on
# squashfs. Minimal images (e.g. prom/prometheus) ship no /run, so the policy's
# scratch tmpfs would fail to mount. Create any missing top-level mount targets
# (root-owned, mode 0755; mksquashfs clamps the mtime to SOURCE_DATE_EPOCH).
"$UCODE" -e 'import { readfile } from "fs";
let cfg = json(readfile(ARGV[0]));
for (let m in (cfg.mounts ?? []))
	if (match(m.destination, /^\/[^\/]+$/))
		print(m.destination + "\n");
' -- "$bundle/config.json" | while IFS= read -r d; do
	[ -n "$d" ] || continue
	[ -e "$rootfs$d" ] || mkdir -p "$rootfs$d"
done

# A container running its own netifd resolves its backhaul peers through
# /etc/hosts, bound read-only at runtime - but that bind needs the target to
# exist on the read-only rootfs, and minimal images ship none. When the policy
# enables a container-private netifd (CONTAINER_NETIFD), seal an empty
# root-owned, world-readable /etc/hosts for the bind to land on.
if [ "$(sed -n 's/^netifd=//p' "$polkv")" = "1" ] && [ ! -e "$rootfs/etc/hosts" ]; then
	mkdir -p "$rootfs/etc"
	: > "$rootfs/etc/hosts"
	chown 0:0 "$rootfs/etc/hosts"
	chmod 0644 "$rootfs/etc/hosts"
fi

# A stack provisions config/credential files at runtime by binding them read-only;
# that bind needs an existing target on the read-only rootfs. Seal an empty
# root-owned stub for each CONTAINER_PROVISION path the image does not already
# ship (the runtime bind overrides it).
for prov in $(sed -n 's/^provision=//p' "$polkv"); do
	[ -n "$prov" ] || continue
	case "$prov" in /*) ;; *) continue ;; esac
	[ -e "$rootfs$prov" ] && continue
	mkdir -p "$rootfs$(dirname "$prov")"
	: > "$rootfs$prov"
	chown 0:0 "$rootfs$prov"
	chmod 0644 "$rootfs$prov"
done

# patch shipped scripts to cooperate with the policy floor, then reduce the
# rootfs (same classes as Container/Reduce, in-session)
if [ -n "$CONTAINER_ROOTFS_FIXUP" ]; then ( cd "$rootfs" && eval "$CONTAINER_ROOTFS_FIXUP" ); fi
[ -n "$CONTAINER_RM" ] && ( cd "$rootfs" && rm -rf $CONTAINER_RM ) || true
sh "$STRIP_SH" "$rootfs" $STRIP_CLASSES
if [ -n "$DO_STRIP" ]; then
	# file(1)'s seccomp sandbox aborts (SIGSYS) under fakeroot's syscall
	# interposition; shadow it with --no-sandbox. sstrip then drops the ELF
	# section header table (fine for glibc/musl, rejected by bionic's linker).
	shim="$bundle/.shim"
	mkdir -p "$shim"
	printf '#!/bin/sh\nexec %s --no-sandbox "$@"\n' "$(command -v file)" > "$shim/file"
	chmod +x "$shim/file"
	export PATH="$shim:$PATH"
	export STRIP1="${CROSS}strip --strip-unneeded --remove-section=.comment --remove-section=.note"
	[ -n "$DO_SSTRIP" ] && export SSTRIP1="$SSTRIP" || export SSTRIP1=""

	# Strip in parallel, but draw the workers from the build's make jobserver
	# rather than fanning out to the host's thread count: under an outer -jN
	# several containers seal at once, so a per-seal nproc fan-out oversubscribes
	# the host and exhausts fakeroot's fds/sockets. Group the candidates into
	# 256-entry batches, emit one make target per batch, and let the jobserver
	# bound the total work across every seal running concurrently.
	batchdir="$bundle/.strip"
	rm -rf "$batchdir"; mkdir -p "$batchdir"
	find "$rootfs" -not -path '*/lib/firmware/*' -type f -print0 | \
	"$UCODE" -e 'import { stdin, open } from "fs";
	let bd = ARGV[0], self = ARGV[1];
	let files = split(stdin.read("all") ?? "", "\0");
	let n = 0, b = 0, fh = null, names = [];
	for (let f in files) {
		if (f == "") continue;
		if (n % 256 == 0) {
			if (fh) fh.close();
			let nm = sprintf("%06d", b++);
			push(names, nm);
			fh = open(bd + "/" + nm, "w");
		}
		fh.write(f); fh.write("\0");
		n++;
	}
	if (fh) fh.close();
	let mk = open(bd + "/Makefile", "w");
	mk.write(".PHONY: all " + join(" ", names) + "\n");
	mk.write("all: " + join(" ", names) + "\n");
	for (let nm in names)
		mk.write(sprintf("%s:\n\t@sh \"%s\" --strip-batch \"%s/%s\"\n", nm, self, bd, nm));
	mk.close();
	' -- "$batchdir" "$0"
	if [ -n "$SEAL_JOBSERVER" ]; then
		MAKEFLAGS="$SEAL_JOBSERVER" "$SEAL_MAKE" -f "$batchdir/Makefile" all
	else
		"$SEAL_MAKE" -j1 -f "$batchdir/Makefile" all
	fi
	rm -rf "$shim" "$batchdir"
fi
[ -n "$DO_DEDUP" ] && sh "$STRIP_SH" "$rootfs" dedup || true

rm -f "$bundle/.meta" "$bundle/owners.txt" "$out"

# Hand the single mkfs pass as many worker threads as the build's jobserver has
# free right now: claim the currently-available tokens and size -processors to
# them (+1 for this recipe's own slot), so the compressor inherits the build's
# job allocation instead of fanning out to the host thread count. The tokens are
# returned immediately after - and on any exit via the trap - so none are lost.
seal_procs=1
js_tokfile=""
case "$SEAL_JOBSERVER" in
*--jobserver-auth=fifo:*)
	js_fifo="${SEAL_JOBSERVER#*--jobserver-auth=fifo:}"; js_fifo="${js_fifo%% *}"
	if [ -p "$js_fifo" ]; then
		# keep the token file outside the bundle: mksquashfs seals the bundle,
		# and a stray file there would change the image content (and its hash).
		js_tokfile="$(dirname "$out")/.jstokens"
		: > "$js_tokfile"
		exec 8<"$js_fifo" 9>"$js_fifo"
		# arm the return path before claiming anything, so a failure mid-claim
		# cannot leak tokens. The nonblocking drain ends in EAGAIN once empty,
		# a non-zero exit that is expected here (hence || true under set -e).
		trap 'cat "$js_tokfile" >&9 2>/dev/null' EXIT INT TERM
		dd bs=1 count=4096 iflag=nonblock <&8 of="$js_tokfile" 2>/dev/null || true
		seal_procs=$(( $(wc -c < "$js_tokfile" 2>/dev/null || echo 0) + 1 ))
	fi
	;;
esac

case "$MKFS_TYPE" in
squashfs) "$MKSQUASHFS" "$bundle" "$out" -nopad -noappend -comp xz -no-xattrs -processors "$seal_procs" ;;
erofs)    "$MKEROFS" "--workers=$seal_procs" -zlz4hc "$out" "$bundle" ;;
*)        echo "oci-seal: unknown MKFS_TYPE '$MKFS_TYPE'" >&2; exit 1 ;;
esac

if [ -n "$js_tokfile" ]; then
	cat "$js_tokfile" >&9 2>/dev/null
	exec 8<&- 9>&-
	trap - EXIT INT TERM
	rm -f "$js_tokfile"
fi
