#!/system/bin/sh
# PROTOTIPE: terminal untuk WebUI tanpa port jaringan.
#
#   tty.sh start <profil> <kolom> <baris>   mulai sesi (satu sesi sekaligus)
#   tty.sh write <base64>                   kirim ketikan (byte mentah, base64)
#   tty.sh read <offset>                    output sejak offset, JSON:
#                                           {"off":N,"alive":bool,"rc":N|null,"profile":"..","data":"<base64>"}
#   tty.sh resize <kolom> <baris>
#   tty.sh stop
#   tty.sh status                           JSON tanpa data
#   tty.sh profiles                         status tiap profil (sudah/belum/butuh prasyarat), JSON
#   tty.sh _run ...                         (internal, dijalankan start)
#
# Cara kerja: `script` (util-linux, di chroot) menyediakan pty; di dalamnya `su -l -P agent` menjalankan
# perintah dari daftar profil tetap (tidak ada shell bebas). Profil "cli" (mis. hermes-install) menjalankan
# `agentbox <argumen tetap>` sebagai root di pty busybox sisi Android. Input masuk lewat FIFO, output ditulis ke
# file yang dibaca bertahap oleh WebUI (polling ksu.exec). Semua file sesi ada di run/tty (700, root).

TTY_SCRIPT=$(cd "${0%/*}" && pwd)/${0##*/}
MODDIR=$(cd "${0%/*}/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$MODDIR/lib/common.sh"

TTY_DIR="$AB_RUN/tty"
TTY_IN="$TTY_DIR/in"
TTY_OUT="$TTY_DIR/out"
TTY_PID="$TTY_DIR/pid"
TTY_RC="$TTY_DIR/rc"
TTY_PROFILE="$TTY_DIR/profile"
# Path pty untuk resize: profil agent menulisnya dari dalam chroot, profil cli dari sisi Android.
TTY_PTS_IN=/run/agentbox-tty.pts
TTY_PTS="$TTY_DIR/pts"
TTY_CLI_RC="$TTY_DIR/cli.rc"
TTY_READ_MAX=65536

tty_err() {
	echo "$*" >&2
	exit 1
}

# Perintah (dijalankan bash login sebagai agent) untuk tiap profil.
tty_profile_cmd() {
	case "$1" in
	demo)
		# shellcheck disable=SC2016  # dievaluasi bash di chroot
		printf '%s\n' 'echo "Demo terminal agentbox ($(tput cols)x$(tput lines))"; read -r -p "Nama: " n; echo "Halo, $n"; echo "Link uji (ketuk untuk buka di browser): https://example.com/?dari=agentbox"; PS3="Pilih nomor: "; select x in satu dua tiga; do echo "Dipilih: $x"; break; done; read -r -s -n1 -p "Tekan satu tombol (tanpa Enter)..." k; echo; printf "kode tombol: %q\n" "$k"'
		;;
	hermes-setup) echo 'hermes setup' ;;
	hermes-model) echo 'hermes model' ;;
	gateway-setup) echo 'hermes gateway setup' ;;
	# Login langganan Claude (Pro/Max/Team) tanpa TUI; menulis ~/.claude/.credentials.json (diperbarui otomatis).
	claude-login) echo 'claude auth login --claudeai' ;;
	# OAuth Anthropic milik Hermes sendiri (tampilkan URL, tempel kode); cadangan bila tidak menautkan login Claude Code.
	hermes-auth) echo 'hermes auth add anthropic' ;;
	*) return 1 ;;
	esac
}

# Profil "cli": argumen `agentbox` (dijalankan sebagai root di sisi Android, pty busybox). Logika
# setup tetap di CLI (dependensi, penanda state, log), bukan diduplikasi di sini. Daftar tetap juga.
tty_cli_args() {
	case "$1" in
	hermes-install) echo 'setup hermes' ;;
	hermes-reinstall) echo 'setup --force hermes' ;;
	setup) echo 'setup' ;;
	*) return 1 ;;
	esac
}

# ---- status profil (untuk WebUI): apakah langkahnya sudah dilakukan / prasyaratnya terpenuhi.

# Helper Hermes (ab_hermes_*) ada di common.sh, dipakai bersama CLI.

# {"id","state":"done|todo|blocked|none","need":"<profil prasyarat>","detail":"..."}
tty_profile_entry() {
	printf '{"id":"%s","state":"%s","need":"%s","detail":"%s"}' "$1" "$2" "$3" "$4"
}

tty_profiles() {
	tp_inst=0
	ab_rootfs_ok && ab_hermes_installed && tp_inst=1
	tp_model_detail=""
	if [ "$tp_inst" = 1 ]; then
		tp_model_detail="provider: $(ab_hermes_model_key provider), model: $(ab_hermes_model_key default)"
	fi

	if [ "$tp_inst" = 1 ] && [ -f "$AB_STATE/hermes.done" ]; then st="done"; else st=todo; fi
	printf '{"profiles":['
	tty_profile_entry hermes-install "$st" "" ""
	# Setup menyeluruh (menu komponen agentbox): selalu bisa dijalankan.
	printf ','
	tty_profile_entry setup none "" ""

	for tp_id in hermes-setup hermes-model; do
		if [ "$tp_inst" != 1 ]; then
			st=blocked
		elif ab_hermes_model_set; then
			st="done"
		else
			st=todo
		fi
		printf ','
		tty_profile_entry "$tp_id" "$st" "hermes-install" "$tp_model_detail"
	done

	# Pasang ulang: hanya bila sudah terpasang; tanpa status selesai (bisa diulang kapan saja).
	if [ "$tp_inst" = 1 ]; then st=none; else st=blocked; fi
	printf ','
	tty_profile_entry hermes-reinstall "$st" "hermes-install" ""

	if [ "$tp_inst" != 1 ]; then
		st=blocked
	elif [ -f "$AB_STATE/gateway.done" ]; then
		st="done"
	else
		st=todo
	fi
	printf ','
	tty_profile_entry gateway-setup "$st" "hermes-install" ""

	# Login Claude Code: selesai bila credentials.json ada; butuh Claude Code terpasang.
	if ! ab_rootfs_ok || { [ ! -e "$ROOTFS$AGENT_HOME/.local/bin/claude" ] && [ ! -L "$ROOTFS$AGENT_HOME/.local/bin/claude" ]; }; then
		st=blocked
	elif [ -f "$ROOTFS$AGENT_HOME/.claude/.credentials.json" ]; then
		st="done"
	else
		st=todo
	fi
	printf ','
	tty_profile_entry claude-login "$st" "setup" ""

	if [ "$tp_inst" = 1 ]; then st=none; else st=blocked; fi
	printf ','
	tty_profile_entry hermes-auth "$st" "hermes-install" ""

	if ab_rootfs_ok && ab_has_agent; then st=none; else st=blocked; fi
	printf ','
	tty_profile_entry demo "$st" "hermes-install" ""
	printf ']}\n'
}

tty_profile_ok() {
	tty_profile_cmd "$1" >/dev/null || tty_cli_args "$1" >/dev/null
}

tty_num() {
	case "$1" in "" | *[!0-9]*) return 1 ;; esac
	return 0
}

tty_alive() {
	[ -f "$TTY_PID" ] || return 1
	ta_p=$(cat "$TTY_PID" 2>/dev/null)
	tty_num "$ta_p" || return 1
	[ -r "/proc/$ta_p/cmdline" ] || return 1
	tr '\0' ' ' <"/proc/$ta_p/cmdline" 2>/dev/null | grep -q 'tty.sh _run'
}

tty_json() {
	if tty_alive; then tj_alive=true; else tj_alive=false; fi
	tj_rc=null
	[ -f "$TTY_RC" ] && tj_rc=$(cat "$TTY_RC")
	tty_num "$tj_rc" || tj_rc=null
	tj_prof=$(cat "$TTY_PROFILE" 2>/dev/null)
	printf '{"off":%s,"alive":%s,"rc":%s,"profile":"%s","data":"%s"}\n' \
		"$1" "$tj_alive" "$tj_rc" "$tj_prof" "$2"
}

tty_start() {
	tty_profile_ok "$1" || tty_err "profil tidak dikenal: $1"
	if ! tty_num "$2" || ! tty_num "$3"; then tty_err "ukuran tidak valid"; fi
	tty_alive && tty_err "sesi lain masih berjalan (stop dulu)"
	# Profil cli (mis. setup) memeriksa dan menyiapkan dependensinya sendiri.
	if ! tty_cli_args "$1" >/dev/null; then
		ab_rootfs_ok || tty_err "rootfs belum ada. Jalankan: agentbox setup"
		ab_has_agent || tty_err "user agent belum dibuat. Jalankan: agentbox setup user"
		ab_mount || tty_err "mount chroot gagal. Cek: agentbox doctor"
	fi

	mkdir -p "$TTY_DIR"
	chmod 700 "$TTY_DIR"
	rm -f "$TTY_IN" "$TTY_PID" "$TTY_RC" "$TTY_PTS" "$TTY_CLI_RC"
	[ -d "$ROOTFS/run" ] && rm -f "$ROOTFS$TTY_PTS_IN"
	mkfifo -m 600 "$TTY_IN" || tty_err "mkfifo gagal"
	: >"$TTY_OUT"
	chmod 600 "$TTY_OUT"
	echo "$1" >"$TTY_PROFILE"
	ab_log INFO "tty: mulai profil $1 (${2}x$3)"
	"$BUSYBOX" setsid /system/bin/sh "$TTY_SCRIPT" _run "$1" "$2" "$3" </dev/null >/dev/null 2>&1 &

	ts_w=0
	while [ "$ts_w" -lt 20 ]; do
		tty_alive && {
			tty_json 0 ""
			return 0
		}
		sleep 0.1
		ts_w=$((ts_w + 1))
	done
	tty_err "sesi gagal dimulai"
}

tty_run() {
	echo "$$" >"$TTY_PID"
	# Pegang FIFO dalam mode baca-tulis: `script` tidak pernah melihat EOF, dan penulis tidak blok.
	exec 3<>"$TTY_IN"
	if tr_args=$(tty_cli_args "$1"); then
		# busybox script tidak meneruskan exit code anak -> disimpan lewat file. Android tidak punya
		# /bin/sh, jadi SHELL wajib diset. $tr_args berasal dari daftar tetap (sengaja di-split).
		tr_inner="stty cols $2 rows $3 2>/dev/null; tty >'$TTY_PTS'; /system/bin/sh '$MODDIR/system/bin/agentbox' $tr_args; echo \$? >'$TTY_CLI_RC'"
		/system/bin/env -i PATH="$AB_PATH_ANDROID" SHELL=/system/bin/sh HOME=/data/local/tmp \
			TERM=xterm-256color LANG=C.UTF-8 \
			"$BUSYBOX" script -qc "$tr_inner" /dev/null <&3 >>"$TTY_OUT" 2>&1
		tr_rc=$(cat "$TTY_CLI_RC" 2>/dev/null)
		tty_num "$tr_rc" || tr_rc=1
	else
		tr_cmd=$(tty_profile_cmd "$1") || exit 1
		tr_inner="stty cols $2 rows $3 2>/dev/null; tty >$TTY_PTS_IN; exec su -l -P $AGENT -s /bin/bash -w TERM,LANG -c $(ab_quote "$tr_cmd")"
		/system/bin/env -i PATH="$AB_PATH_ANDROID" chroot "$ROOTFS" /usr/bin/env -i \
			HOME=/root TERM=xterm-256color LANG=C.UTF-8 PATH="$AB_PATH_ROOT" \
			/usr/bin/script -qfec "$tr_inner" /dev/null <&3 >>"$TTY_OUT" 2>&1
		tr_rc=$?
	fi
	if [ "$1" = claude-login ] || [ "$1" = hermes-auth ]; then
		# Tampilkan hasil cek kredensial langsung ke Anthropic setelah login.
		tty_note "cek kredensial ke Anthropic..."
		tty_post /system/bin/sh "$MODDIR/system/bin/agentbox" config auth-check
		[ "$1" = claude-login ] && [ "$tr_rc" = 0 ] &&
			tty_note "Agar Hermes ikut memakai model Claude lewat login ini: Konfigurasi → Pakai Claude (agentbox config hermes-link-claude)."
	fi
	if [ "$1" = gateway-setup ]; then
		if [ "$tr_rc" = 0 ]; then
			tty_note "pasca-proses gateway..."
			# Logika ada di CLI (satu sumber dengan `agentbox setup/config gateway`).
			tty_post /system/bin/sh "$MODDIR/system/bin/agentbox" config gateway --finish || tr_rc=$?
			[ "$tr_rc" = 0 ] && tty_note "selesai. Status gateway terlihat di halaman Gateway."
		else
			tty_note "wizard keluar dengan kode $tr_rc; pasca-proses gateway dilewati"
		fi
	fi
	echo "$tr_rc" >"$TTY_RC"
	ab_log INFO "tty: profil $1 selesai (kode $tr_rc)"
}

# Pesan agentbox ke layar terminal (xterm butuh \r\n).
tty_note() {
	printf '\r\n\033[1m[agentbox]\033[0m %s\r\n' "$1" >>"$TTY_OUT"
}

# Jalankan perintah sisi Android, outputnya ditampilkan di terminal (LF -> CRLF), pertahankan exit code.
tty_post() {
	tp_tmp="$TTY_DIR/post.out"
	"$@" >"$tp_tmp" 2>&1
	tp_rc=$?
	sed 's/$/\r/' "$tp_tmp" >>"$TTY_OUT"
	rm -f "$tp_tmp"
	return "$tp_rc"
}

tty_write() {
	case "$1" in
	"" | *[!A-Za-z0-9+/=]*) tty_err "data harus base64" ;;
	esac
	tty_alive || tty_err "tidak ada sesi berjalan"
	# timeout: bila sesi mati tepat saat ini, open() FIFO tanpa pembaca akan blok selamanya.
	# shellcheck disable=SC2016  # $0/$1 milik sh anak
	printf '%s' "$1" | "$BUSYBOX" timeout 3 "$BUSYBOX" sh -c '"$0" base64 -d >"$1"' "$BUSYBOX" "$TTY_IN"
}

tty_read() {
	tty_num "$1" || tty_err "offset tidak valid"
	tr_off=$1
	tr_size=$(wc -c <"$TTY_OUT" 2>/dev/null) || tr_size=0
	# File diganti (sesi baru) -> mulai dari awal.
	[ "$tr_off" -gt "$tr_size" ] && tr_off=0
	tr_n=$((tr_size - tr_off))
	[ "$tr_n" -gt "$TTY_READ_MAX" ] && tr_n=$TTY_READ_MAX
	tr_data=""
	if [ "$tr_n" -gt 0 ]; then
		tr_data=$("$BUSYBOX" tail -c +$((tr_off + 1)) "$TTY_OUT" | "$BUSYBOX" head -c "$tr_n" | "$BUSYBOX" base64 -w 0)
	fi
	tty_json $((tr_off + tr_n)) "$tr_data"
}

tty_resize() {
	if ! tty_num "$1" || ! tty_num "$2"; then tty_err "ukuran tidak valid"; fi
	tty_alive || return 0
	if [ -f "$TTY_PTS" ]; then
		tz_pts=$(cat "$TTY_PTS")
	else
		tz_pts=$(cat "$ROOTFS$TTY_PTS_IN" 2>/dev/null)
	fi
	case "$tz_pts" in /dev/pts/[0-9]*) ;; *) tty_err "pty belum siap" ;; esac
	# TIOCSWINSZ -> kernel mengirim SIGWINCH ke proses foreground; su -P meneruskannya ke pty dalam.
	"$BUSYBOX" stty -F "$tz_pts" cols "$1" rows "$2"
}

tty_stop() {
	if tty_alive; then
		tp_p=$(cat "$TTY_PID")
		kill -TERM -"$tp_p" 2>/dev/null || kill -TERM "$tp_p" 2>/dev/null
		tp_w=0
		while tty_alive && [ "$tp_w" -lt 20 ]; do
			sleep 0.1
			tp_w=$((tp_w + 1))
		done
		tty_alive && kill -KILL -"$tp_p" 2>/dev/null
		ab_log INFO "tty: sesi dihentikan"
	fi
	echo "Sesi dihentikan."
}

case "$1" in
start) tty_start "$2" "$3" "$4" ;;
_run) tty_run "$2" "$3" "$4" ;;
write) tty_write "$2" ;;
read) tty_read "${2:-0}" ;;
resize) tty_resize "$2" "$3" ;;
stop) tty_stop ;;
status) tty_json 0 "" ;;
profiles) tty_profiles ;;
*)
	echo "Pemakaian: tty.sh start <profil> <kolom> <baris> | write <b64> | read <off> | resize <k> <b> | stop | status | profiles" >&2
	exit 2
	;;
esac
