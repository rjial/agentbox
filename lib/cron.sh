#!/system/bin/sh
# Cron job deklaratif untuk Hermes Agent, dikelola dari agentbox.
#
#   cron.sh add <nama> <jadwal> <prompt> [--deliver T] [--skill S] [--paused]
#   cron.sh list [--json]
#   cron.sh remove <nama>
#   cron.sh sync
#
# Sumber kebenaran ada di dua tempat yang DIPISAH dengan sengaja:
#   - File deklaratif di $AB_CONFIG/cron.d/<nama>.cron  -> apa yang owner modul DINGINKAN
#   - ~/.hermes/cron/jobs.json                          -> state nyata Hermes (dibaca, tidak ditulis)
#
# Cron job bukan env var: butuh schedule, prompt, dan delivery target. config/env hanya
# KEY=VALUE, jadi tidak bisa memuatnya. File .cron tidak pernah ditulis ulang ke jobs.json:
# jobs.json punya next_run_at dan state hasil run, dan Hermes sengaja Mendeteksi edit
# schedule ekspresi tak sinkron sebagai `expr_edit` (cron/jobs.py) supaya tidak lolos/fired
# dua kali. Semua perubahan masuk lewat `hermes cron`, bukan tulis JSON.
#
# Idempoten: sync hanya membuat job yang namanya belum ada di jobs.json. Job yang di-pause
# manual owner tetap paused.

MODDIR=$(cd "${0%/*}/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=common.sh
. "$MODDIR/lib/common.sh"

CRON_DIR="$AB_CONFIG/cron.d"
HERMES_HOME_DIR="$AGENT_HOME/.hermes"
JOBS_JSON="$HERMES_HOME_DIR/cron/jobs.json"

# ------------------------------------------------------------------ helper lokal
# cron.sh berjalan sebagai proses terpisah (dipanggil system/bin/agentbox), jadi
# helper yang hanya ada di file CLI utama tidak terlihat. Definisi minimal di sini,
# sama seperti lib/gateway.sh. Hanya dbg/warn tanpa warna: output dipakai log boot.

say() { printf '%s\n' "$*"; }
err() { printf 'GALAT: %s\n' "$*" >&2; }
die() {
	err "$*"
	exit 1
}
# Sama dengan CLI utama: with_timeout mengisi AB_TMO, agent_run membungkus dirinya dengan tmo
# (busybox timeout tidak bisa menjalankan fungsi shell secara langsung).
with_timeout() {
	AB_TMO=$1
	shift
	"$@"
	wt_rc=$?
	AB_TMO=""
	return "$wt_rc"
}
tmo() {
	if [ -n "${AB_TMO:-}" ]; then "$BUSYBOX" timeout "$AB_TMO" "$@"; else "$@"; fi
}

# Escape string untuk JSON: \\ dan ", buang karakter kontrol.
json_esc() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'
}

# Perintah sebagai agent di chroot (env bersih, tanpa config/env).
agent_run() {
	tmo /system/bin/env -i PATH="$AB_PATH_ANDROID" chroot "$ROOTFS" /usr/bin/setpriv \
		--reuid="$AGENT" --regid="$AGENT" --init-groups /usr/bin/env -i \
		HOME="$AGENT_HOME" USER="$AGENT" LOGNAME="$AGENT" LANG=en_US.UTF-8 \
		TERM="${TERM:-xterm-256color}" PATH="$AB_PATH_AGENT" "$@"
}

hermes_installed() { [ -x "$ROOTFS$AGENT_HOME/.local/bin/hermes" ]; }

need_mount() { ab_mount; }

# ------------------------------------------------------------------ validasi nama

# Nama job = nama file .cron. Hanya [A-Za-z0-9_-], maksimal 40 char, tidak boleh "." atau "..".
cron_valid_name() {
	case "$1" in
	"" | . | .. | *[!A-Za-z0-9_-]*) return 1 ;;
	esac
	[ "${#1}" -le 40 ] || return 1
	return 0
}

cron_need_name() {
	cron_valid_name "${1:-}" ||
		die "nama job tidak valid: '${1:-}' (hanya A-Z a-z 0-9 _ -, maksimal 40 karakter)"
}

# Nama file yang aman: tolak apa pun yang bukan hasil valid_name (anti path traversal).
cron_file() {
	cron_valid_name "$1" || die "nama job tidak valid: $1"
	printf '%s' "$CRON_DIR/$1.cron"
}

# ------------------------------------------------------------------ baca state Hermes

# Nama job yang sudah ada di Hermes. Membaca jobs.json sebagai agent; hanya READ.
# jobs.json ditulis Hermes pretty-print JSON: setiap job punya baris "name": "<nama>"
# pada indentasi tetap. Ambil nilai string-nya (mendukung escape JSON \" dan \\).
# `hermes cron list` tidak punya --json, jadi ini sumber state yang stabil.
cron_existing_names() {
	[ -f "$JOBS_JSON" ] || return 0
	sed -n 's/^[[:space:]]*"name":[[:space:]]*"\([^"]*\)".*$/\1/p' "$JOBS_JSON" 2>/dev/null |
		sed 's/\\"/"/g; s/\\\\/\\/g'
}

# Nama job milik agentbox yang ada di config (file .cron), untuk perbandingan.
cron_declared_names() {
	[ -d "$CRON_DIR" ] || return 0
	for cf in "$CRON_DIR"/*.cron; do
		[ -f "$cf" ] || continue
		bn=${cf##*/}
		printf '%s\n' "${bn%.cron}"
	done
}

# Nilai satu field dari file .cron. Format: KEY=VALUE satu per baris, nilai mungkin
# berisi spasi sehingga dibaca sebagai "sisa baris setelah =".
cron_field() {
	[ -f "$2" ] || return 1
	sed -n "s/^$1=//p" "$2" | head -n1
}

# Prompt mungkin multiline: semua baris setelah 'PROMPT=' sampai baris '---'.
# Disimpan apa adanya supaya prompt panjang tetap utuh (Hermes accepts multiline prompt).
cron_field_multiline() {
	[ -f "$2" ] || return 1
	awk -v key="$1" '
		$0 == key "=BEGIN" { inb = 1; next }
		inb && $0 == "---" { exit }
		inb { print }
	' "$2"
}

# ------------------------------------------------------------------ tulis file deklaratif

cron_write_decl() {
	cw_file=$(cron_file "$1")
	cw_sched="$2"
	cw_prompt="$3"
	cw_deliver="$4"
	shift 4
	cw_skills=""
	for cw_s in "$@"; do
		cw_skills="$cw_skills${cw_skills:+ }$cw_s"
	done

	mkdir -p "$CRON_DIR" || die "gagal membuat $CRON_DIR"
	(
		umask 077
		{
			printf '# Cron job agentbox. Format: KEY=VALUE; PROMPT=BEGIN..--- multi-baris.\n'
			printf '# File ini deklarasi KEINGINAN owner. State nyata ada di %s.\n' "$JOBS_JSON"
			printf 'SCHEDULE=%s\n' "$cw_sched"
			printf 'DELIVER=%s\n' "$cw_deliver"
			[ -n "$cw_skills" ] && printf 'SKILLS=%s\n' "$cw_skills"
			printf 'CREATED=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
			printf 'PROMPT=BEGIN\n%s\n---\n' "$cw_prompt"
		} >"$cw_file"
	) || {
		rm -f "$cw_file"
		die "gagal menulis $cw_file"
	}
}

# ------------------------------------------------------------------ apply ke Hermes

# Satu job deklaratif -> `hermes cron create`, hanya kalau namanya belum ada.
cron_apply_one() {
	ca_name="$1"
	ca_file=$(cron_file "$ca_name")
	[ -f "$ca_file" ] || return 0

	ca_sched=$(cron_field SCHEDULE "$ca_file")
	[ -n "$ca_sched" ] || {
		printf '  LEWATI %-24s SCHEDULE kosong\n' "$ca_name"
		return 0
	}
	ca_deliver=$(cron_field DELIVER "$ca_file")
	[ -n "$ca_deliver" ] || ca_deliver=local
	ca_prompt=$(cron_field_multiline PROMPT "$ca_file")
	if [ -z "$ca_prompt" ]; then
		printf '  LEWATI %-24s PROMPT kosong\n' "$ca_name"
		return 0
	fi

	# Idempotensi: skip kalau nama sudah terdaftar di Hermes.
	if cron_existing_names | grep -qxF "$ca_name"; then
		printf '  ADA   %-24s (tidak diubah; pakai hermes cron untuk pause/resume)\n' "$ca_name"
		return 0
	fi

	printf '  BUAT  %-24s %s -> %s\n' "$ca_name" "$ca_sched" "$ca_deliver"
	# Argumen lewat parameter posisi (bukan string berkutip): prompt bisa berisi spasi dan kutip.
	set -- cron create "$ca_sched" "$ca_prompt" --name "$ca_name" --deliver "$ca_deliver"
	for ca_one in $(cron_field SKILLS "$ca_file"); do
		set -- "$@" --skill "$ca_one"
	done
	ca_out=$(with_timeout 90 agent_run hermes "$@" 2>&1)
	case "$ca_out" in
	*"Created job:"*)
		printf '        %s\n' "$(printf '%s' "$ca_out" | sed -n 's/^Created job: //p' | head -n1)"
		return 0
		;;
	*)
		printf '  GAGAL %-24s\n' "$ca_name"
		printf '%s\n' "$ca_out" | sed 's/^/        /' | head -n5
		return 1
		;;
	esac
}

# Terapkan semua file .cron. Dipakai juga oleh service.sh saat boot.
cron_sync() {
	hermes_installed || return 0
	[ -d "$CRON_DIR" ] || return 0
	need_mount || return 0

	cs_any=0
	cs_rc=0
	for cs_f in "$CRON_DIR"/*.cron; do
		[ -f "$cs_f" ] || continue
		cs_any=1
		cs_n=${cs_f##*/}
		cron_apply_one "${cs_n%.cron}" || cs_rc=1
	done
	[ "$cs_any" = 1 ] || return 0
	ab_log INFO "cron: sync selesai (rc=$cs_rc)"
	return "$cs_rc"
}

# Dipanggil diam-diam dari service.sh: kegagalan tidak boleh menggagalkan boot.
cron_sync_boot() {
	cron_sync >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ list

cron_list_json() {
	printf '{"declared":['
	cl_sep=""
	for cl_f in "$CRON_DIR"/*.cron; do
		[ -f "$cl_f" ] || continue
		cl_n=${cl_f##*/}
		cl_n=${cl_n%.cron}
		cl_present=false
		cron_existing_names | grep -qxF "$cl_n" && cl_present=true
		printf '%s{"name":"%s","schedule":"%s","deliver":"%s","in_hermes":%s}' \
			"$cl_sep" "$(json_esc "$cl_n")" \
			"$(json_esc "$(cron_field SCHEDULE "$cl_f")")" \
			"$(json_esc "$(cron_field DELIVER "$cl_f")")" "$cl_present"
		cl_sep=,
	done
	printf ']}\n'
}

cmd_cron_list() {
	if [ "${1:-}" = --json ]; then
		cron_list_json
		return 0
	fi
	if [ ! -d "$CRON_DIR" ] || [ -z "$(cron_declared_names)" ]; then
		say "Belum ada cron job deklaratif."
		say "Tambah dengan: agentbox config cron add <nama> <jadwal> <prompt>"
		return 0
	fi
	say "Cron job deklaratif (agentbox):"
	say ""
	printf '  %-26s %-18s %-10s %s\n' NAMA JADWAL KIRIM STATUS
	printf '  %-26s %-18s %-10s %s\n' "--------------------------" "------------------" "----------" "------"
	for cl_f in "$CRON_DIR"/*.cron; do
		[ -f "$cl_f" ] || continue
		cl_n=${cl_f##*/}
		cl_n=${cl_n%.cron}
		if cron_existing_names | grep -qxF "$cl_n"; then
			cl_st="aktif"
		else
			cl_st="belum"
		fi
		printf '  %-26s %-18s %-10s %s\n' \
			"$cl_n" \
			"$(cron_field SCHEDULE "$cl_f")" \
			"$(cron_field DELIVER "$cl_f")" \
			"$cl_st"
	done
	say ""
	say "Status 'belum' = file ada tapi job belum dibuat di Hermes. Jalankan: agentbox config cron sync"
	say "Ubah jadwal/prompt: edit file .cron lalu 'agentbox config cron sync'."
}

# ------------------------------------------------------------------ add / remove

cmd_cron_add() {
	[ $# -ge 3 ] || die "pemakaian: agentbox config cron add <nama> <jadwal> <prompt> [--deliver T] [--skill S] [--paused]"

	ca_name="$1"
	ca_sched="$2"
	ca_prompt=""
	shift 2

	# Opsi boleh sebelum atau sesudah positional. Prompt = argumen pertama yang
	# bukan opsi dan bukan nilai opsi.
	ca_deliver=local
	ca_skills=""
	ca_paused=""
	ca_stdin=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--deliver)
			[ -n "${2:-}" ] || die "--deliver butuh nilai"
			ca_deliver="$2"
			shift 2
			;;
		--skill)
			[ -n "${2:-}" ] || die "--skill butuh nilai"
			ca_skills="$ca_skills${ca_skills:+ }$2"
			shift 2
			;;
		--prompt-stdin)
			ca_stdin=1
			shift
			;;
		--paused)
			ca_paused=1
			shift
			;;
		-h | --help)
			usage_cron_add
			return 0
			;;
		-*) die "opsi tidak dikenal: $1 (lihat agentbox config cron --help)" ;;
		*)
			if [ -z "$ca_prompt" ]; then
				ca_prompt="$1"
			else
				ca_prompt="$ca_prompt $1"
			fi
			shift
			;;
		esac
	done

	cron_need_name "$ca_name"
	[ -n "$ca_sched" ] || die "jadwal tidak boleh kosong"

	# Prompt dari stdin (WebUI): nilai tidak pernah masuk argv, jadi karakter shell
	# apa pun aman. NUL dibuang (tidak bisa disimpan di file teks) dan panjang
	# dibatasi 8192 karakter supaya file .cron tetap ringkas.
	if [ -n "$ca_stdin" ]; then
		# Baca seluruh stdin dulu (dd bs=N count=1 akan memotong sebelum bisa
		# diperiksa), buang NUL, baru tolak yang melebihi batas.
		ca_prompt=$(tr -d '\000' | dd bs=65536 count=8 2>/dev/null)
		[ "${#ca_prompt}" -le 8192 ] || die "prompt terlalu panjang (maks 8192 karakter)"
	fi

	[ -n "$ca_prompt" ] || die "prompt tidak boleh kosong"
	case "$ca_deliver" in
	"" | local | all | origin | telegram | discord | signal | bot-chat) : ;;
	*) die "delivery target tidak dikenal: $ca_deliver" ;;
	esac

	cf=$(cron_file "$ca_name")
	if [ -f "$cf" ]; then
		die "job '$ca_name' sudah ada di $cf. Ubah file itu langsung, atau hapus dulu: agentbox config cron remove $ca_name"
	fi

	cron_write_decl "$ca_name" "$ca_sched" "$ca_prompt" "$ca_deliver" "$ca_skills"
	say "Deklarasi tersimpan: $cf"

	if [ "$ca_paused" = 1 ]; then
		say "Job dibuat dalam keadaan PAUSED (aktifkan dengan: agentbox shell -> hermes cron resume <id>)."
		return 0
	fi

	need_mount || die "rootfs belum ter-mount. Jalankan: agentbox mount"
	hermes_installed || die "Hermes belum terpasang. Jalankan: agentbox setup hermes"
	say ""
	cron_apply_one "$ca_name" || die "job gagal dibuat di Hermes"
	say ""
	say "Cek dengan: agentbox config cron list"
}

cmd_cron_remove() {
	[ -n "${1:-}" ] || die "pemakaian: agentbox config cron remove <nama>"
	cron_need_name "$1"
	cf=$(cron_file "$1")
	[ -f "$cf" ] || die "tidak ada deklarasi: $1"

	# Job nyata di Hermes dibiarkan: hapus deklarasi saja._jobs.json adalah state
	# owner, bukan milik modul. Hapus manual dengan: agentbox shell -> hermes cron remove <id>
	rm -f "$cf" || die "gagal menghapus $cf"
	say "Deklarasi '$1' dihapus."
	if cron_existing_names | grep -qxF "$1"; then
		say "CATATAN: job dengan nama ini masih ada di Hermes dan tidak ikut terhapus."
		say "Hapus juga dengan: agentbox shell -> hermes cron list, lalu hermes cron remove <id>"
	fi
}

cmd_cron_sync() {
	[ -d "$CRON_DIR" ] || die "belum ada deklarasi cron. Tambah dengan: agentbox config cron add ..."
	need_mount || die "rootfs belum ter-mount. Jalankan: agentbox mount"
	hermes_installed || die "Hermes belum terpasang. Jalankan: agentbox setup hermes"
	say "Menerapkan deklarasi cron ke Hermes:"
	say ""
	cron_sync || die "sebagian job gagal dibuat (lihat di atas)"
}

# ------------------------------------------------------------------ dispatch

usage_cron_add() {
	cat <<EOF
Pemakaian: agentbox config cron add <nama> <jadwal> <prompt> [opsi]

  <nama>    hanya A-Z a-z 0-9 _ -, maksimal 40 karakter
  <jadwal>  '30m', 'every 2h', 'every monday 9am', atau ekspresi cron 5-field '0 9 * * *'
  <prompt>  instruksi mandiri untuk agent (job berjalan di sesi baru, tanpa konteks chat)

Opsi:
  --deliver T   tujuan keluaran: local (default, simpan saja), all, origin,
                telegram, discord, signal, bot-chat, atau platform:chat_id
  --skill S     muat skill sebelum prompt (boleh diulang)
  --prompt-stdin
                baca prompt dari stdin, bukan dari argumen (dipakai WebUI supaya
                karakter shell di prompt tidak pernah masuk argv); maks 8192 karakter
  --paused      simpan deklarasi tanpa langsung membuat job di Hermes
EOF
}

usage_cron() {
	cat <<EOF
Pemakaian: agentbox config cron <subperintah>

  add <nama> <jadwal> <prompt>   simpan deklarasi, lalu buat job di Hermes
  list [--json]                 daftar cron job deklaratif
  remove <nama>                 hapus deklarasi (job Hermes tidak ikut terhapus)
  sync                          buat job yang belum ada (idempoten, dipanggil saat boot)

Cron job adalah state, bukan env var: jadwal, prompt, dan hasil run tidak muat
dalam config/env. Modul menyimpan deklarasi di $CRON_DIR, Hermes menyimpan
state di $JOBS_JSON. apply selalu lewat 'hermes cron' supaya schedule tetap sinkron.
EOF
}

case "${1:-}" in
add)
	shift
	cmd_cron_add "$@"
	;;
list)
	shift
	cmd_cron_list "$@"
	;;
remove | rm | delete)
	shift
	cmd_cron_remove "$@"
	;;
sync)
	cmd_cron_sync
	;;
-h | --help | "" | *)
	usage_cron
	[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || exit 1
	;;
esac