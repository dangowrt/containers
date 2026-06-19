#!/bin/sh
# strip-rootfs.sh <rootfs> <class>...   (the 'strip' class is done via $(RSTRIP))
root="$1"; shift

# never operate on an empty or system path: a stray empty $root would otherwise
# turn "rm -rf $root/usr/share/man" into deleting the host's /usr/share/man
[ -n "$root" ] && [ -d "$root" ] || { echo "strip-rootfs: not a directory: '$root'" >&2; exit 1; }
case "$root" in
/ | /usr | /etc | /var | /lib | /bin | /sbin)
	echo "strip-rootfs: refusing system root: '$root'" >&2
	exit 1
	;;
esac

for class in "$@"; do
	case "$class" in
	docs)
		rm -rf "$root/usr/share/man" "$root/usr/share/info" \
		       "$root/usr/share/doc" "$root/usr/share/doc-base" \
		       "$root/usr/share/gtk-doc"
		;;
	locales)
		[ -d "$root/usr/share/locale" ] && find "$root/usr/share/locale" \
			-mindepth 1 -maxdepth 1 -type d \
			! -name C ! -name POSIX ! -name en ! -name 'en_*' \
			-exec rm -rf {} + || true
		rm -f "$root/usr/lib/locale/locale-archive"
		;;
	headers)
		rm -rf "$root/usr/include"
		find "$root/usr/lib" \( -name '*.h' -o -name '*.hpp' \) -type f -delete 2>/dev/null || true
		;;
	static-libs)
		find "$root" \( -name '*.a' -o -name '*.la' \) -type f -delete 2>/dev/null || true
		;;
	pkgmgr)
		rm -rf "$root/var/lib/apt" "$root/var/lib/dpkg" "$root/var/cache/apt" \
		       "$root/var/cache/debconf" "$root/var/lib/apk" "$root/lib/apk" \
		       "$root/etc/apk" "$root/etc/apt"
		;;
	sourcemaps)
		find "$root" \( -name '*.js.map' -o -name '*.css.map' -o -name '*.mjs.map' \) \
			-type f -delete 2>/dev/null || true
		;;
	dedup)
		find "$root" -type f -size +4096c -links 1 -print0 2>/dev/null | \
			xargs -0 -r sha256sum 2>/dev/null | sort | \
			awk '{ h=$1; sub(/^[^ ]*  /,""); if (h==ph) printf "%s\n%s\0", pf, $0; else { ph=h; pf=$0 } }' | \
			xargs -0 -r -n2 sh -c 'ln -f "$0" "$1"' 2>/dev/null || true
		;;
	*)
		echo "strip-rootfs: unknown class '$class'" >&2
		exit 1
		;;
	esac
done
