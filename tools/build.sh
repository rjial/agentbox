#!/bin/sh
# Build zip module agentbox.
#
#   sh tools/build.sh release   log debug mati (untuk dibagikan)
#   sh tools/build.sh debug     log debug aktif: logs/debug.log, trace setup.sh, installer Hermes --verbose
#
# Hasil: dist/agentbox-<versi>-<tipe>.zip. Build debug memberi akhiran "-debug" pada versi di
# module.prop agar terlihat di KernelSU Manager. Bisa dijalankan di PC (butuh `zip` atau python3)
# maupun di device (memakai python3 milik Termux bila `zip` tidak ada).
set -e

usage() {
	echo "Pemakaian: sh tools/build.sh release|debug" >&2
	exit 2
}

case "${1:-}" in
release) debug=0 ;;
debug) debug=1 ;;
-h | --help) usage ;;
*) usage ;;
esac
type=$1

root=$(cd "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^version=//p' "$root/module.prop")
[ -n "$version" ] || {
	echo "versi tidak ditemukan di module.prop" >&2
	exit 1
}
# File yang masuk zip (daftar eksplisit: CLAUDE.md, tools/, dist/ tidak pernah ikut).
INCLUDE="module.prop customize.sh post-fs-data.sh service.sh uninstall.sh lib system rootfs-setup webroot"

tmp_base=${TMPDIR:-/tmp}
[ -d "$tmp_base" ] || tmp_base=/data/local/tmp
stage=$(mktemp -d "$tmp_base/agentbox-build.XXXXXX")
case "$stage" in
"$tmp_base"/agentbox-build.*) ;;
*)
	echo "direktori staging tidak valid: '$stage'" >&2
	exit 1
	;;
esac
trap 'rm -rf "$stage"' EXIT

for p in $INCLUDE; do
	cp -R "$root/$p" "$stage/"
done
rm -f "$stage/lib/build.conf"
printf '# Ditulis tools/build.sh, jangan diedit manual.\nAB_BUILD=%s\nAB_DEBUG=%s\n' "$type" "$debug" \
	>"$stage/lib/build.conf"
if [ "$debug" = 1 ]; then
	sed -i "s/^version=.*/version=$version-debug/" "$stage/module.prop"
fi
find "$stage" -type f -exec chmod 644 {} +
find "$stage" -type d -exec chmod 755 {} +
chmod 755 "$stage"/*.sh "$stage"/system/bin/* "$stage"/lib/gateway.sh "$stage"/lib/tty.sh "$stage"/rootfs-setup/setup.sh

mkdir -p "$root/dist"
out="$root/dist/agentbox-$version-$type.zip"
rm -f "$out"

if command -v zip >/dev/null 2>&1; then
	(cd "$stage" && zip -qr -X "$out" .)
else
	py=""
	py_env=""
	if command -v python3 >/dev/null 2>&1; then
		py=python3
	elif [ -x /data/data/com.termux/files/usr/bin/python3 ]; then
		py=/data/data/com.termux/files/usr/bin/python3
		py_env="LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib"
	else
		echo "butuh 'zip' atau 'python3' untuk membuat zip" >&2
		exit 1
	fi
	# Permission diambil dari file di staging (sudah di-chmod di atas).
	env $py_env "$py" -I - "$stage" "$out" <<'EOF'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            info = zipfile.ZipInfo.from_file(p, os.path.relpath(p, src))
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(p, "rb") as fh:
                z.writestr(info, fh.read())
EOF
fi

echo "OK: $out ($type, log debug $([ "$debug" = 1 ] && echo aktif || echo mati))"
