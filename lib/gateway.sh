#!/system/bin/sh
# Kontrol Hermes messaging gateway (Telegram, dsb.) tanpa runit.
#
#   gateway.sh start | stop | restart
#   gateway.sh status [--json]
#   gateway.sh log [jumlah_baris]
#   gateway.sh autostart on | off | status
#   gateway.sh supervise          (internal, dipanggil oleh start)
#
# Supervisor berupa loop shell di sisi Android: menjalankan `hermes gateway` di chroot
# sebagai user agent, me-restart bila crash (backoff 10 s s/d 5 menit), dan berhenti
# bila ada file stop. Dipakai oleh service.sh (boot), CLI agentbox, dan WebUI.

GW_SCRIPT=$(cd "${0%/*}" && pwd)/${0##*/}
MODDIR=$(cd "${0%/*}/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$MODDIR/lib/common.sh"

HERMES="$AGENT_HOME/.local/bin/hermes"
GW_LOG="$AB_LOGS/gateway.log"
GW_SUP_PID="$AB_RUN/gateway-supervisor.pid"
GW_CHILD_PID="$AB_RUN/gateway.pid"
GW_STARTED="$AB_RUN/gateway.started"
GW_STOP="$AB_RUN/gateway.stop"
GW_AUTOSTART="$AB_CONFIG/gateway.autostart"
GW_LOG_MAX=1048576

gw_log() {
	mkdir -p "$AB_LOGS"
	echo "$(date '+%Y-%m-%d %H:%M:%S') [agentbox] $1" >>"$GW_LOG"
}

gw_installed() {
	[ -d "$ROOTFS/usr" ] && chroot "$ROOTFS" /usr/bin/test -x "$HERMES" 2>/dev/null
}

# .env saja tidak cukup: installer Hermes selalu membuatnya dari template. Penanda gateway.done
# ditulis agentbox setelah `hermes gateway setup` sukses (setup gateway / config gateway).
gw_configured() {
	[ -f "$ROOTFS$AGENT_HOME/.hermes/.env" ] && [ -f "$AB_STATE/gateway.done" ]
}

# Hidup = proses ada dan bukan zombie.
gw_alive() {
	[ -n "$1" ] && [ -r "/proc/$1/stat" ] || return 1
	gw_st=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -c1)
	[ -n "$gw_st" ] && [ "$gw_st" != Z ]
}

gw_sup_pid() {
	[ -f "$GW_SUP_PID" ] || return 1
	gw_p=$(cat "$GW_SUP_PID" 2>/dev/null)
	gw_alive "$gw_p" || return 1
	tr '\0' ' ' <"/proc/$gw_p/cmdline" 2>/dev/null | grep -q 'gateway.sh supervise' || return 1
	echo "$gw_p"
}

gw_child_pid() {
	[ -f "$GW_CHILD_PID" ] || return 1
	gw_c=$(cat "$GW_CHILD_PID" 2>/dev/null)
	gw_alive "$gw_c" || return 1
	echo "$gw_c"
}

# sleep yang bisa diinterupsi trap.
gw_nap() {
	sleep "$1" &
	gw_nap_pid=$!
	wait "$gw_nap_pid" 2>/dev/null
	kill "$gw_nap_pid" 2>/dev/null
}

# Copy-truncate: aman karena gateway menulis dengan O_APPEND (>>).
gw_rotate_log() {
	[ -f "$GW_LOG" ] || return 0
	gw_size=$(wc -c <"$GW_LOG" 2>/dev/null || echo 0)
	[ "$gw_size" -gt "$GW_LOG_MAX" ] || return 0
	[ -f "$GW_LOG.1" ] && mv -f "$GW_LOG.1" "$GW_LOG.2"
	cp -f "$GW_LOG" "$GW_LOG.1" && : >"$GW_LOG"
}

gw_wait_dns() {
	gw_i=0
	while [ "$gw_i" -lt 30 ] && [ ! -f "$GW_STOP" ]; do
		chroot "$ROOTFS" /usr/bin/getent hosts api.telegram.org >/dev/null 2>&1 && return 0
		gw_i=$((gw_i + 1))
		gw_nap 2
	done
	gw_log "DNS belum siap setelah 60 detik, tetap mencoba start"
}

# TERM ke seluruh process group gateway, KILL bila belum mati dalam 15 detik.
gw_kill_child() {
	kill -TERM -"$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null
	gw_k=0
	while gw_alive "$1" && [ "$gw_k" -lt 15 ]; do
		sleep 1
		gw_k=$((gw_k + 1))
	done
	if gw_alive "$1"; then
		gw_log "gateway tidak berhenti dalam 15 detik, dipaksa (KILL)"
		kill -KILL -"$1" 2>/dev/null || kill -KILL "$1" 2>/dev/null
	fi
}

gw_supervise() {
	mkdir -p "$AB_RUN" "$AB_LOGS"
	echo "$$" >"$GW_SUP_PID"
	trap 'touch "$GW_STOP"' TERM INT HUP
	gw_backoff=5
	gw_log "supervisor mulai (pid $$)"

	while [ ! -f "$GW_STOP" ]; do
		if ! ab_mount; then
			gw_log "mount gagal, coba lagi dalam 30 detik"
			gw_nap 30
			continue
		fi
		if ! gw_installed || ! gw_configured; then
			gw_log "Hermes belum terpasang atau gateway belum dikonfigurasi, supervisor berhenti"
			break
		fi
		gw_wait_dns
		[ -f "$GW_STOP" ] && break
		gw_rotate_log

		gw_start_ts=$(date +%s)
		"$BUSYBOX" setsid chroot "$ROOTFS" /usr/bin/setpriv \
			--reuid="$AGENT" --regid="$AGENT" --init-groups \
			/usr/bin/env -i \
			HOME="$AGENT_HOME" USER="$AGENT" LOGNAME="$AGENT" \
			LANG=en_US.UTF-8 PYTHONUNBUFFERED=1 \
			PATH="$AGENT_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
			"$HERMES" gateway </dev/null >>"$GW_LOG" 2>&1 &
		gw_child=$!
		echo "$gw_child" >"$GW_CHILD_PID"
		echo "$gw_start_ts" >"$GW_STARTED"
		gw_log "gateway start (pid $gw_child)"

		while gw_alive "$gw_child"; do
			if [ -f "$GW_STOP" ]; then
				gw_kill_child "$gw_child"
				break
			fi
			gw_nap 10
			gw_rotate_log
		done
		wait "$gw_child" 2>/dev/null
		gw_rc=$?
		rm -f "$GW_CHILD_PID" "$GW_STARTED"

		if [ -f "$GW_STOP" ]; then
			gw_log "gateway dihentikan"
			break
		fi

		gw_ran=$(($(date +%s) - gw_start_ts))
		if [ "$gw_ran" -ge 120 ]; then
			gw_backoff=10
		else
			gw_backoff=$((gw_backoff * 2))
			[ "$gw_backoff" -gt 300 ] && gw_backoff=300
		fi
		gw_log "gateway keluar (kode $gw_rc), restart dalam $gw_backoff detik"
		gw_nap "$gw_backoff"
	done

	rm -f "$GW_SUP_PID" "$GW_CHILD_PID" "$GW_STARTED"
	gw_log "supervisor berhenti"
}

gw_start() {
	if gw_sup_pid >/dev/null; then
		echo "Gateway sudah berjalan."
		return 0
	fi
	gw_installed || { echo "Hermes belum terpasang. Jalankan: agentbox setup hermes" >&2; return 2; }
	gw_configured || { echo "Gateway belum dikonfigurasi. Jalankan: agentbox config gateway" >&2; return 3; }
	ab_mount || { echo "Mount chroot gagal. Cek dengan: agentbox doctor" >&2; return 4; }

	mkdir -p "$AB_RUN" "$AB_LOGS"
	rm -f "$GW_STOP"
	"$BUSYBOX" setsid /system/bin/sh "$GW_SCRIPT" supervise </dev/null >/dev/null 2>&1 &

	gw_w=0
	while [ "$gw_w" -lt 10 ]; do
		gw_sup_pid >/dev/null && { echo "Gateway dijalankan."; return 0; }
		sleep 1
		gw_w=$((gw_w + 1))
	done
	echo "Supervisor gagal start. Lihat log: $GW_LOG" >&2
	return 1
}

gw_stop() {
	mkdir -p "$AB_RUN"
	touch "$GW_STOP"
	gw_sp=$(gw_sup_pid) || gw_sp=""
	gw_cp=$(gw_child_pid) || gw_cp=""
	if [ -z "$gw_sp" ] && [ -z "$gw_cp" ]; then
		rm -f "$GW_SUP_PID" "$GW_CHILD_PID" "$GW_STARTED"
		echo "Gateway sudah berhenti."
		return 0
	fi
	[ -n "$gw_sp" ] && kill -TERM "$gw_sp" 2>/dev/null

	gw_w=0
	while [ "$gw_w" -lt 25 ]; do
		gw_sup_pid >/dev/null || gw_child_pid >/dev/null || break
		sleep 1
		gw_w=$((gw_w + 1))
	done

	# Cadangan bila supervisor tidak merespons.
	gw_cp=$(gw_child_pid) && gw_kill_child "$gw_cp"
	gw_sp=$(gw_sup_pid) && kill -KILL "$gw_sp" 2>/dev/null
	rm -f "$GW_SUP_PID" "$GW_CHILD_PID" "$GW_STARTED"
	echo "Gateway dihentikan."
}

gw_status() {
	gw_state=stopped
	gw_pid=""
	gw_uptime=0
	if gw_sup_pid >/dev/null; then
		if gw_pid=$(gw_child_pid); then
			gw_state=running
			[ -f "$GW_STARTED" ] && gw_uptime=$(($(date +%s) - $(cat "$GW_STARTED")))
		else
			gw_state=restarting
			gw_pid=""
		fi
	fi
	gw_auto=false
	[ -f "$GW_AUTOSTART" ] && gw_auto=true
	gw_inst=false
	gw_installed && gw_inst=true
	gw_conf=false
	gw_configured && gw_conf=true

	if [ "$1" = "--json" ]; then
		printf '{"state":"%s","pid":%s,"uptime":%s,"autostart":%s,"installed":%s,"configured":%s}\n' \
			"$gw_state" "${gw_pid:-null}" "$gw_uptime" "$gw_auto" "$gw_inst" "$gw_conf"
	else
		echo "state:      $gw_state"
		echo "pid:        ${gw_pid:--}"
		echo "uptime:     ${gw_uptime}s"
		echo "autostart:  $gw_auto"
		echo "installed:  $gw_inst"
		echo "configured: $gw_conf"
	fi
}

gw_autostart() {
	case "$1" in
	on)
		mkdir -p "$AB_CONFIG"
		touch "$GW_AUTOSTART"
		echo "Autostart aktif."
		;;
	off)
		rm -f "$GW_AUTOSTART"
		echo "Autostart nonaktif."
		;;
	status | "")
		if [ -f "$GW_AUTOSTART" ]; then echo on; else echo off; fi
		;;
	*)
		echo "Pemakaian: gateway.sh autostart on|off|status" >&2
		return 1
		;;
	esac
}

case "$1" in
start) gw_start ;;
stop) gw_stop ;;
restart) gw_stop >/dev/null && gw_start ;;
status) gw_status "$2" ;;
log) [ -f "$GW_LOG" ] && tail -n "${2:-200}" "$GW_LOG" ;;
autostart) gw_autostart "$2" ;;
supervise) gw_supervise ;;
*)
	echo "Pemakaian: gateway.sh start|stop|restart|status [--json]|log [n]|autostart on|off|status" >&2
	exit 1
	;;
esac
