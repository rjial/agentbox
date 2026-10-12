#!/system/bin/sh
# Dijalankan KernelSU saat module dihapus. WAJIB: stop gateway + umount + verifikasi
# sebelum menghapus apa pun di bawah rootfs (agar /sdcard tidak ikut terhapus).
MODDIR=${0%/*}
# shellcheck source=lib/common.sh
. "$MODDIR/lib/common.sh"

ab_log INFO "uninstall dimulai"
/system/bin/sh "$MODDIR/lib/gateway.sh" stop >/dev/null 2>&1

if ! ab_umount || grep -q " ${ROOTFS}[ /]" /proc/mounts; then
	ab_log ERROR "uninstall: mount tersisa di $ROOTFS, data TIDAK dihapus"
	exit 1
fi
for d in sdcard proc sys dev/pts; do
	if [ -d "$ROOTFS/$d" ] && [ -n "$(ls -A "$ROOTFS/$d" 2>/dev/null)" ]; then
		ab_log ERROR "uninstall: $ROOTFS/$d tidak kosong, data TIDAK dihapus"
		exit 1
	fi
done

# Stub Termux yang dibuat service.sh.
TERMUX_BIN=/data/data/com.termux/files/usr/bin
for n in agentbox claude hermes; do
	grep -q 'agentbox-termux-stub' "$TERMUX_BIN/$n" 2>/dev/null && rm -f "$TERMUX_BIN/$n"
done

# Hapus semua kecuali backup (bila berisi), agar arsip home agent tidak hilang.
for p in "$ROOTFS" "$AB_DIR/rootfs.tmp" "$AB_CONFIG" "$AB_STATE" "$AB_RUN" "$AB_CACHE" "$AB_LOGS"; do
	ab_path_safe "$p" || continue
	rm -rf "$p"
done
if [ -z "$(ls -A "$AB_BACKUP" 2>/dev/null)" ]; then
	rmdir "$AB_BACKUP" 2>/dev/null
	rmdir "$AB_DIR" 2>/dev/null
fi
exit 0
