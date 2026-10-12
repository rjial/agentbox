# shellcheck shell=sh
# shellcheck disable=SC2034  # variabel dipakai oleh skrip yang men-source file ini
# Path dan helper bersama agentbox. File ini di-source, bukan dieksekusi.
# Semua path agentbox didefinisikan di sini saja.

MODDIR="${MODDIR:-/data/adb/modules/agentbox}"
AB_DIR=/data/adb/agentbox
ROOTFS="$AB_DIR/rootfs"
AB_CONFIG="$AB_DIR/config"
AB_ENV="$AB_CONFIG/env"
AB_LOGS="$AB_DIR/logs"
AB_RUN="$AB_DIR/run"
AB_STATE="$AB_DIR/state"
AB_CACHE="$AB_DIR/cache"
AB_BACKUP="$AB_DIR/backup"
BUSYBOX=/data/adb/ksu/bin/busybox
# Penyimpanan internal user 0 tanpa FUSE; di-bind ke /sdcard di dalam chroot.
AB_SDCARD_SRC=/data/media/0
AGENT=agent
AGENT_HOME=/home/agent
# UID/GID tetap 8061: rentang 8000-8999 tidak dipakai AID Android. useradd default (1000)
# bentrok dengan AID_SYSTEM di kernel host (dan /dev/binder ikut ter-bind). UID >= 10000 yang
# bukan aplikasi diblokir netd (tanpa izin INTERNET), jadi harus di bawah 10000.
AGENT_UID=8061
# Grup Android yang dibutuhkan agent: inet/net_raw (paranoid network, tanpa ini socket
# jaringan ditolak kernel) dan media_rw (tulis ke /sdcard).
AB_ANDROID_GROUPS="aid_inet:3003 aid_net_raw:3004 media_rw:1023"
AB_PATH_ROOT=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
AB_PATH_AGENT="$AGENT_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
AB_PATH_ANDROID=/system/bin:/system/xbin:/data/adb/ksu/bin

ab_log() {
	mkdir -p "$AB_LOGS"
	echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" >>"$AB_LOGS/agentbox.log"
}

# Mode build: lib/build.conf ditulis tools/build.sh (AB_BUILD=release|debug, AB_DEBUG=0|1).
# Tanpa file itu (menjalankan langsung dari repo): mode dev, debug mati.
AB_BUILD=dev
AB_DEBUG=0
# shellcheck source=/dev/null
[ -f "$MODDIR/lib/build.conf" ] && . "$MODDIR/lib/build.conf"
# Override saat runtime, mis. menelusuri masalah di build release:
#   su -c 'AGENTBOX_DEBUG=1 agentbox setup'
case "${AGENTBOX_DEBUG:-}" in 0 | 1) AB_DEBUG=$AGENTBOX_DEBUG ;; esac
AB_DEBUG_LOG="$AB_LOGS/debug.log"
AB_DEBUG_MAX=5242880

# Log debug (hanya bila AB_DEBUG=1). JANGAN pernah mengoper nilai dari config/env ke sini.
ab_debug() {
	[ "$AB_DEBUG" = 1 ] || return 0
	mkdir -p "$AB_LOGS"
	(
		umask 077
		echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $*" >>"$AB_DEBUG_LOG"
	)
}

# Salin isi file (mis. trace dari dalam chroot) ke debug.log dengan header, lalu hapus file-nya.
ab_debug_file() {
	[ -f "$2" ] || return 0
	if [ "$AB_DEBUG" = 1 ]; then
		ab_debug "----- $1 -----"
		(
			umask 077
			cat "$2" >>"$AB_DEBUG_LOG"
		)
		ab_debug "----- akhir $1 -----"
	fi
	rm -f "$2"
}

# Rotasi debug.log saat > 5 MB (cukup dipanggil sekali per eksekusi CLI).
ab_debug_rotate() {
	[ -f "$AB_DEBUG_LOG" ] || return 0
	[ "$(wc -c <"$AB_DEBUG_LOG")" -gt "$AB_DEBUG_MAX" ] || return 0
	mv -f "$AB_DEBUG_LOG" "$AB_DEBUG_LOG.1"
}

ab_is_mounted() {
	grep -q " $1 " /proc/mounts
}

ab_rootfs_ok() {
	[ -d "$ROOTFS/usr" ] && [ -e "$ROOTFS/bin/sh" ]
}

ab_has_agent() {
	grep -q "^$AGENT:" "$ROOTFS/etc/passwd" 2>/dev/null
}

# Path aman untuk operasi destruktif: tidak kosong, di bawah /data/adb/agentbox/, tanpa "..".
ab_path_safe() {
	case "$1" in
	*..*) return 1 ;;
	"$AB_DIR"/?*) return 0 ;;
	esac
	return 1
}

# Bind mount yang dibutuhkan chroot. Idempoten.
ab_mount() {
	[ -d "$ROOTFS/usr" ] || return 1
	for ab_d in dev dev/pts proc sys; do
		mkdir -p "$ROOTFS/$ab_d"
		ab_is_mounted "$ROOTFS/$ab_d" || mount -o bind "/$ab_d" "$ROOTFS/$ab_d" || return 1
	done
	mkdir -p "$ROOTFS/dev/shm"
	ab_is_mounted "$ROOTFS/dev/shm" ||
		mount -t tmpfs -o mode=1777,size=64m tmpfs "$ROOTFS/dev/shm" || return 1
	# Sumber /data/media/0 (bukan /sdcard): /sdcard adalah FUSE MediaProvider yang menolak uid agent.
	# Di dalam chroot tetap muncul sebagai /sdcard. Bind FUSE lama (versi sebelumnya) diganti.
	mkdir -p "$ROOTFS/sdcard"
	if grep -q " $ROOTFS/sdcard fuse " /proc/mounts; then
		umount "$ROOTFS/sdcard" 2>/dev/null || umount -l "$ROOTFS/sdcard" || return 1
	fi
	ab_is_mounted "$ROOTFS/sdcard" || mount -o bind "$AB_SDCARD_SRC" "$ROOTFS/sdcard" || return 1
	[ -s "$ROOTFS/etc/resolv.conf" ] || ab_write_resolv
	return 0
}

# Mount minimal untuk rescue mode: hanya /proc dan /dev.
ab_mount_min() {
	[ -d "$ROOTFS" ] || return 1
	for ab_d in dev proc; do
		mkdir -p "$ROOTFS/$ab_d"
		ab_is_mounted "$ROOTFS/$ab_d" || mount -o bind "/$ab_d" "$ROOTFS/$ab_d" || return 1
	done
	return 0
}

# Umount dalam urutan terbalik, lalu verifikasi tidak ada yang tersisa.
# WAJIB dipanggil (dan sukses) sebelum operasi hapus apa pun di bawah $ROOTFS.
ab_umount() {
	for ab_d in sdcard dev/shm sys proc dev/pts dev; do
		if ab_is_mounted "$ROOTFS/$ab_d"; then
			umount "$ROOTFS/$ab_d" 2>/dev/null || umount -l "$ROOTFS/$ab_d" || true
		fi
	done
	if grep -q " $ROOTFS/" /proc/mounts; then
		ab_log ERROR "masih ada mount di bawah $ROOTFS"
		return 1
	fi
	return 0
}

ab_write_resolv() {
	[ -d "$ROOTFS/etc" ] || return 1
	# resolv.conf bawaan rootfs bisa berupa symlink; ganti dengan file biasa.
	rm -f "$ROOTFS/etc/resolv.conf"
	printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$ROOTFS/etc/resolv.conf"
}

# Ada proses (selain diri sendiri) yang root-nya di dalam rootfs?
ab_chroot_busy() {
	for ab_p in /proc/[0-9]*; do
		[ "${ab_p#/proc/}" = "$$" ] && continue
		[ "$(readlink "$ab_p/root" 2>/dev/null)" = "$ROOTFS" ] && return 0
	done
	return 1
}

# Kutip satu argumen untuk sh: abc'd -> 'abc'\''d'
ab_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Nama variabel di config/env, dipisah koma (untuk `su -w`).
ab_env_keys() {
	[ -f "$AB_ENV" ] || return 0
	sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$AB_ENV" | tr '\n' ',' | sed 's/,$//'
}

# Petakan cwd Android ke path di dalam chroot (hanya penyimpanan internal), selain itu home agent.
ab_chroot_cwd() {
	ab_cwd=$(pwd 2>/dev/null)
	for ab_pre in /sdcard /storage/emulated/0 /storage/self/primary /data/media/0; do
		case "$ab_cwd" in
		"$ab_pre" | "$ab_pre"/*)
			echo "/sdcard${ab_cwd#"$ab_pre"}"
			return 0
			;;
		esac
	done
	echo "$AGENT_HOME"
}

# Jalankan program sebagai agent di chroot dengan env bersih (pengganti proses ini).
#   ab_exec_agent <cwd_di_chroot> <program> [argumen...]
# Isi config/env dimuat lewat environment, tidak pernah lewat argv (argv terbaca semua user di /proc).
# shellcheck disable=SC2016  # dievaluasi oleh sh anak
ab_exec_agent() {
	exec /system/bin/env -i \
		PATH="$AB_PATH_ANDROID" TERM="${TERM:-xterm-256color}" \
		AB_R="$ROOTFS" AB_E="$AB_ENV" AB_U="$AGENT" AB_H="$AGENT_HOME" AB_P="$AB_PATH_AGENT" \
		/system/bin/sh -c '
		if [ -f "$AB_E" ]; then set -a; . "$AB_E"; set +a; fi
		r=$AB_R
		export HOME="$AB_H" USER="$AB_U" LOGNAME="$AB_U" SHELL=/bin/bash LANG=C.UTF-8 PATH="$AB_P"
		u=$AB_U
		unset AB_R AB_E AB_U AB_H AB_P
		exec chroot "$r" /usr/bin/setpriv --reuid="$u" --regid="$u" --init-groups \
			/bin/sh -c "cd \"\$1\" 2>/dev/null || cd; shift; exec \"\$@\"" sh "$@"
	' sh "$@"
}

# Wrapper bersama untuk system/bin/claude dan system/bin/hermes.
ab_wrapper() {
	ab_w_name=$1
	shift
	if ! ab_rootfs_ok; then
		echo "$ab_w_name: rootfs belum ada. Jalankan: su -c 'agentbox setup'" >&2
		exit 1
	fi
	if ! ab_has_agent; then
		echo "$ab_w_name: user agent belum dibuat. Jalankan: su -c 'agentbox setup user'" >&2
		exit 1
	fi
	# Bisa berupa symlink absolut (installer Claude) yang hanya valid di dalam chroot.
	ab_w_bin="$ROOTFS$AGENT_HOME/.local/bin/$ab_w_name"
	if [ ! -L "$ab_w_bin" ] && [ ! -x "$ab_w_bin" ]; then
		echo "$ab_w_name: belum terpasang. Jalankan: su -c 'agentbox setup $ab_w_name'" >&2
		exit 1
	fi
	if ! ab_mount; then
		echo "$ab_w_name: mount chroot gagal. Cek dengan: su -c 'agentbox doctor'" >&2
		exit 1
	fi
	ab_exec_agent "$(ab_chroot_cwd)" "$AGENT_HOME/.local/bin/$ab_w_name" "$@"
}

# ---- Hermes (dibaca dari sisi Android, tanpa menjalankan hermes yang lambat)

ab_hermes_installed() {
	[ -e "$ROOTFS$AGENT_HOME/.local/bin/hermes" ] || [ -L "$ROOTFS$AGENT_HOME/.local/bin/hermes" ]
}

# Nilai key di blok `model:` config.yaml Hermes (awk, tanpa menjalankan hermes yang butuh ~2-3 detik).
# Hanya karakter aman yang dikembalikan (dipakai di JSON).
ab_hermes_model_key() {
	awk -v k="$1" '
		/^model:/ { f = 1; next }
		f && /^[^ #]/ { exit }
		f && $0 ~ "^  " k ":" { sub("^  " k ":[ ]*", ""); gsub(/["\047]/, ""); sub(/[ ]+#.*$/, ""); print; exit }
	' "$ROOTFS$AGENT_HOME/.hermes/config.yaml" 2>/dev/null | tr -cd 'A-Za-z0-9._/:@-'
}

# Template installer berisi provider "auto"; wizard (hermes setup / hermes model) selalu menulis
# provider eksplisit. Jadi "sudah diatur" = provider ada dan bukan auto.
ab_hermes_model_set() {
	ab_hm_p=$(ab_hermes_model_key provider)
	[ -n "$ab_hm_p" ] && [ "$ab_hm_p" != auto ]
}

# Nilai satu variabel di ~/.hermes/.env (tanpa men-source file; satu lapis kutip dibuang).
# JANGAN di-log atau di-echo mentah: isinya rahasia. Tampilkan hanya lewat penyamaran.
ab_hermes_env_get() {
	sed -n "s/^$1=//p" "$ROOTFS$AGENT_HOME/.hermes/.env" 2>/dev/null | tail -n 1 |
		sed "s/^\"\\(.*\\)\"\$/\\1/; s/^'\\(.*\\)'\$/\\1/"
}
