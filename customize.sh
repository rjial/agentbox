#!/system/bin/sh
# Dijalankan KernelSU saat flash. Ringan saja: cek arch, buat direktori, set permission.
# Rootfs TIDAK diunduh di sini (flash bisa timeout); itu tugas `agentbox setup`.
# shellcheck disable=SC2034  # dibaca installer KernelSU
SKIPUNZIP=0

[ "$ARCH" = arm64 ] || abort "! agentbox hanya mendukung arm64 (terdeteksi: $ARCH)"

MODDIR="$MODPATH"
# shellcheck source=lib/common.sh
. "$MODPATH/lib/common.sh"

ui_print "- Membuat direktori $AB_DIR"
for d in "$AB_DIR" "$AB_CONFIG" "$AB_LOGS" "$AB_RUN" "$AB_STATE" "$AB_CACHE" "$AB_BACKUP"; do
	mkdir -p "$d"
	chown 0:0 "$d"
	chmod 700 "$d"
done
[ -f "$AB_ENV" ] && chmod 600 "$AB_ENV"

ui_print "- Set permission"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/system/bin" 0 2000 0755 0755
set_perm "$MODPATH/lib/gateway.sh" 0 0 0755
set_perm "$MODPATH/lib/tty.sh" 0 0 0755
set_perm "$MODPATH/rootfs-setup/setup.sh" 0 0 0755

if [ ! -d /data/adb/metamodule ]; then
	ui_print "! Metamodule tidak terdeteksi: overlay system/bin mungkin tidak aktif."
	ui_print "  Setelah reboot, perintah tetap bisa dipanggil lewat:"
	ui_print "  su -c /data/adb/modules/agentbox/system/bin/agentbox"
	ui_print "  (Termux: stub agentbox/claude/hermes dibuat otomatis saat boot)"
fi

ui_print ""
ui_print "- Selesai. Reboot, lalu dari Termux / adb shell -t jalankan:"
ui_print "    su -c 'agentbox setup'"
