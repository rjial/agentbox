#!/system/bin/sh
# Dijalankan KernelSU setelah boot (late_start service). Jangan blocking lama.
MODDIR=${0%/*}
# shellcheck source=lib/common.sh
. "$MODDIR/lib/common.sh"

until [ "$(getprop sys.boot_completed)" = 1 ]; do
	sleep 2
done

# Fallback bila overlay system/bin tidak aktif: stub di $PREFIX/bin Termux yang naik ke root
# lewat su lalu menjalankan skrip module. Stub lama milik agentbox selalu ditulis ulang.
termux_stubs() {
	tx_bin=/data/data/com.termux/files/usr/bin
	[ -d "$tx_bin" ] || return 0
	[ -x /system/bin/agentbox ] && return 0
	tx_uid=$(stat -c %u /data/data/com.termux) || return 0
	tx_ctx=$(stat -c %C "$tx_bin" 2>/dev/null)
	for n in agentbox claude hermes; do
		tx_f="$tx_bin/$n"
		if [ -e "$tx_f" ] && ! grep -q 'agentbox-termux-stub' "$tx_f" 2>/dev/null; then
			ab_log WARN "stub Termux $n dilewati: $tx_f sudah ada dan bukan milik agentbox"
			continue
		fi
		cat >"$tx_f" <<STUB
#!/data/data/com.termux/files/usr/bin/sh
# agentbox-termux-stub: dibuat otomatis oleh agentbox (overlay system/bin tidak aktif).
q="sh '$MODDIR/system/bin/$n'"
for a in "\$@"; do
	q="\$q '\$(printf '%s' "\$a" | sed "s/'/'\\\\\\\\''/g")'"
done
exec su -c "cd '\$(pwd | sed "s/'/'\\\\\\\\''/g")' 2>/dev/null; exec \$q"
STUB
		chown "$tx_uid:$tx_uid" "$tx_f"
		chmod 755 "$tx_f"
		[ -n "$tx_ctx" ] && [ "$tx_ctx" != "?" ] && chcon "$tx_ctx" "$tx_f" 2>/dev/null
	done
}
termux_stubs

[ -d "$ROOTFS/usr" ] || exit 0
if ! ab_mount; then
	ab_log ERROR "mount saat boot gagal"
	exit 0
fi

if [ -f "$AB_CONFIG/gateway.autostart" ]; then
	/system/bin/sh "$MODDIR/lib/gateway.sh" start >/dev/null 2>&1
	# Terapkan cron job deklaratif (config/cron.d) ke Hermes. Diam-diam: declarative
	# yang gagal tidak boleh menggagalkan boot. Idempoten, jadi aman tiap boot.
	[ -d "$AB_CONFIG/cron.d" ] && /system/bin/sh "$MODDIR/lib/cron.sh" sync >/dev/null 2>&1
fi
