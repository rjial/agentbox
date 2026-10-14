# CLAUDE.md — agentbox (KernelSU module)

## Ringkasan proyek

`agentbox` adalah module KernelSU yang menjalankan **Claude Code** (TUI) dan **Hermes Agent** di Android
lewat **chroot Void Linux (aarch64, glibc)**. Android memakai bionic libc, jadi kedua tool tidak dijalankan
langsung di shell Android, melainkan di dalam rootfs Void.

Keputusan yang sudah final (jangan diubah tanpa diskusi):

- Rootfs: **Void Linux aarch64 varian glibc** (bukan `-musl`), package manager `xbps`.
- Isolasi: **chroot** (bukan proot), karena root tersedia via KernelSU.
- Agent berjalan sebagai user non-root **`agent`** di dalam chroot. Jangan pernah menjalankan
  `claude` atau `hermes` sebagai root.
- **Tidak memakai runit.** Hermes gateway diawasi supervisor shell `lib/gateway.sh` di sisi Android,
  di-start dari `service.sh` saat boot (bila autostart aktif) dan dikontrol lewat WebUI/CLI.
- Binary Claude Code **tidak dibundel** di repo atau zip module (proprietary). Selalu diunduh dari installer
  resmi saat setup.

## Struktur repo

```
agentbox/
├── CLAUDE.md
├── module.prop
├── customize.sh          # dijalankan saat flash: ringan saja (cek arch, buat direktori, set permission)
├── post-fs-data.sh       # hindari kerja berat di sini (blocking boot)
├── service.sh            # SUDAH ADA: tunggu boot, mount, start gateway bila autostart aktif
├── uninstall.sh          # WAJIB unmount dulu sebelum hapus apa pun
├── system/bin/
│   ├── agentbox          # CLI utama, lihat bagian "CLI agentbox"
│   ├── claude            # wrapper → chroot → su agent → claude
│   └── hermes            # wrapper → chroot → su agent → hermes
├── lib/
│   ├── common.sh         # SUDAH ADA: path, ab_log, ab_debug, ab_mount, ab_umount (dengan verifikasi)
│   ├── build.conf        # DIBUAT tools/build.sh saat build (AB_BUILD, AB_DEBUG); tidak ada di repo
│   └── gateway.sh        # SUDAH ADA: supervisor + start/stop/restart/status/log/autostart gateway
├── rootfs-setup/
│   └── setup.sh          # dijalankan DI DALAM chroot saat `agentbox setup`
├── tools/                # tidak ikut masuk zip
│   ├── build.sh          # build zip release/debug ke dist/
│   └── bump-version.sh   # semver di module.prop; --check dipakai CI
├── .github/workflows/
│   └── release.yml       # versi berubah di main → lint, build, GitHub Release vX.Y.Z
├── README.md             # README utama (Inggris); README.id.md versi Indonesia
├── LICENSE               # MIT
└── webroot/              # WebUI KernelSU, navigasi bawah: Status · Gateway · Terminal · Konfigurasi
    ├── index.html        # SPA Preact: keempat halaman sebagai route hash (lihat "WebUI: struktur halaman")
    ├── app.css / app.js  # token warna + komponen bersama; ksu.exec, helper, daftar tab (AB.NAV)
    └── vendor/           # lokal, offline: xterm.js + addon (MIT), htm-preact.umd.js (htm Apache-2.0 + Preact MIT)
```

## Path runtime di device

| Path | Isi |
|---|---|
| `/data/adb/modules/agentbox` | file module (`$MODDIR`), ikut terhapus/terganti saat update module |
| `/data/adb/agentbox/rootfs` | rootfs Void, **di luar** folder module agar survive update |
| `/data/adb/agentbox/config/env` | env var (mis. `ANTHROPIC_API_KEY`), `chmod 600`, owner root |
| `/data/adb/agentbox/logs/` | log setup, service, dan mount |
| `/data/adb/ksu/bin/busybox` | busybox bawaan KernelSU, pakai ini untuk applet yang beda di toybox |

Semua path di atas didefinisikan sekali di `lib/common.sh`; jangan hardcode di tempat lain.

## Alur instalasi

1. Flash zip di KernelSU Manager → `customize.sh` hanya validasi `ARCH=arm64`, buat direktori, set permission.
   Jangan mengunduh rootfs di sini (flash bisa timeout/gagal di tengah).
2. User menjalankan `su -c agentbox setup` dari Termux/adb:
   - unduh `void-aarch64-ROOTFS-<tanggal>.tar.xz` dari mirror Void (tanggal di-resolve dari index mirror,
     jangan hardcode),
   - ekstrak pakai `busybox tar` ke `/data/adb/agentbox/rootfs` (bukan toybox tar: hardlink/xattr),
   - tulis `/etc/resolv.conf`, bind mount, lalu jalankan `rootfs-setup/setup.sh` di dalam chroot.
3. `setup.sh` (di dalam chroot): `xbps-install -Syu xbps`, update, install `nodejs python3 git curl bash sudo
   glibc-locales`, aktifkan locale `en_US.UTF-8`, buat user `agent`, install Claude Code via installer resmi
   sebagai `agent`, install `uv` lalu Hermes Agent sebagai `agent`.
4. Setup harus **idempoten**: aman dijalankan ulang, lewati langkah yang sudah selesai.

## CLI `agentbox`

Satu CLI untuk semua operasi. WebUI (bila dibuat) hanya memanggil CLI ini, tidak menduplikasi logika.
Semua subcommand wajib punya `--help`, dan `agentbox` tanpa argumen menampilkan ringkasan perintah.

| Perintah | Fungsi |
|---|---|
| `agentbox shell` | Masuk chroot sebagai user **`agent`** (default, untuk kerja sehari-hari) |
| `agentbox shell --root` | Masuk chroot sebagai **root** untuk perbaikan manual |
| `agentbox shell --safe` | Mode rescue sebagai root, dipakai saat rootfs rusak (lihat di bawah) |
| `agentbox exec <cmd...>` | Jalankan satu perintah di chroot sebagai root, lalu keluar |
| `agentbox setup [komponen...]` | Setup modular dan idempoten (lihat di bawah) |
| `agentbox config` | Atur API key dan konfigurasi Hermes secara interaktif |
| `agentbox doctor [--fix]` | Diagnosis lingkungan; `--fix` hanya melakukan perbaikan yang aman |
| `agentbox repair` | `doctor --fix`, lalu ulangi langkah setup yang gagal/belum selesai |
| `agentbox install <pkg...>` | Shortcut `xbps-install -y` di dalam chroot |
| `agentbox update` | Update rootfs (`xbps-install -Syu`), Claude Code, dan Hermes |
| `agentbox service <start\|stop\|restart\|status\|log\|autostart on\|off>` | Delegasi langsung ke `lib/gateway.sh` |
| `agentbox status [--json [--versions]]` | Ringkasan: rootfs, mount, versi tool, status service; `--json` untuk WebUI |
| `agentbox mount` / `agentbox umount` | Kelola bind mount secara manual |
| `agentbox backup` | Arsipkan `/home/agent` ke `/data/adb/agentbox/backup/` |
| `agentbox reset` | Hapus dan bangun ulang rootfs (destruktif, lihat aturan keamanan) |

### `agentbox shell` — akses chroot saat terjadi masalah

- Default masuk sebagai `agent` via `su - agent` (login shell, `HOME=/home/agent`, cwd di home).
  `--root` masuk sebagai root dengan `HOME=/root`.
- Prompt membedakan user: `[agentbox] agent$` vs `[agentbox] root#`, supaya jelas sedang di mana.
- Bila user `agent` belum ada (komponen `user` belum selesai), tampilkan pesan
  "user agent belum dibuat, jalankan `agentbox setup user` atau masuk dengan `--root`" lalu keluar.
  Jangan diam-diam fallback ke root.
- Otomatis menjalankan mount bila belum ter-mount (idempoten).
- Pilih shell secara berurutan: `/bin/bash -l` → `/bin/sh`. Kalau keduanya tidak ada, tampilkan pesan jelas dan
  sarankan `agentbox reset`.
- Prompt diberi prefix `[agentbox]` (via `PS1`) agar user tahu sedang di dalam chroot.
- Env bersih: `env -i` dengan `HOME`, `TERM`, `LANG=C.UTF-8`, `PATH` yang benar.
- Saat keluar dari shell, **jangan** umount bila gateway masih berjalan (`gateway.sh status`), karena gateway memakai mount.
- `--safe` (rescue mode), dipakai saat rootfs/profile rusak:
  - hanya mount `/proc` dan `/dev` (tanpa `/sdcard`, supaya aman dari salah hapus),
  - shell `/bin/sh` tanpa membaca profile/rc (`sh -i` dengan `ENV` kosong),
  - tidak menyentuh service dan tidak menjalankan setup apa pun,
  - tampilkan banner berisi path rootfs dan pengingat perintah berguna (`xbps-install -f`, `xbps-pkgdb -a`).
- Bila chroot gagal total (mis. `/bin/sh` rusak), tampilkan pesan untuk inspeksi dari luar:
  `ls /data/adb/agentbox/rootfs` dan saran `agentbox reset`.

### `agentbox setup` — setup modular

Komponen, dijalankan berurutan sesuai dependensinya:

| Komponen | Isi |
|---|---|
| `rootfs` | Unduh dan ekstrak rootfs Void |
| `base` | `resolv.conf`, update xbps, paket dasar (`nodejs python3 git curl bash sudo`) + build deps untuk wheel Python yang harus dikompilasi di aarch64 (`base-devel python3-devel libffi-devel openssl-devel`) |
| `locale` | `glibc-locales`, aktifkan `en_US.UTF-8` |
| `user` | Buat user `agent` beserta home-nya |
| `claude` | Install Claude Code via installer resmi sebagai `agent` |
| `uv` | Install `uv` sebagai `agent` |
| `hermes` | **Interaktif, butuh TTY.** Install Hermes Agent sebagai `agent` lewat installer resmi. Installer membuat venv sendiri dan memasang extras `.[all]`, termasuk dependensi messaging gateway (Telegram, dsb.). Instalasi ada di `/home/agent/.hermes/` |
| `gateway` | **Interaktif, butuh TTY.** Jalankan `hermes gateway setup` sebagai `agent` untuk mengatur platform seperti Telegram |

- Tanpa argumen + ada TTY → tampilkan menu pilihan bernomor (default: semua yang belum selesai).
  Tanpa TTY (dipanggil WebUI/skrip) → jalankan semua yang belum selesai, tanpa prompt.
- Dengan argumen → hanya jalankan komponen itu (plus dependensi yang belum selesai), mis. `agentbox setup claude`.
- Komponen interaktif (`hermes`, `gateway`):
  - Tanpa TTY → **lewati** (jangan gagal), catat sebagai belum selesai, dan tampilkan
    "jalankan `agentbox setup hermes` dari terminal (Termux / `adb shell -t`)".
  - Unduh `install.sh` ke file dulu, lalu jalankan `bash install.sh` sebagai `agent` dengan TTY.
    **Jangan** `curl ... | bash`, karena stdin menjadi pipe sehingga prompt interaktif tidak bisa dijawab.
  - Jalankan lewat `chroot ... su - agent -c ...` dengan `TERM` diteruskan, sama seperti `agentbox shell`.
  - Sebelum menjalankan installer, tampilkan catatan: bila installer menawarkan memasang gateway sebagai
    service systemd, pilih **tidak**, karena gateway diawasi `lib/gateway.sh`.
  - Setelah komponen `gateway` sukses: `gateway.sh autostart on` lalu `gateway.sh start`.
- Tiap komponen menulis penanda `/data/adb/agentbox/state/<komponen>.done` setelah **sukses**.
  `--force` mengabaikan penanda dan menjalankan ulang.
- Tiap komponen menampilkan langkah yang sedang berjalan, dan saat gagal menunjukkan baris log yang relevan
  beserta perintah untuk mengulanginya.
- Di akhir setup, jalankan `agentbox doctor` otomatis lalu tampilkan langkah berikutnya
  (mis. "jalankan `agentbox config` untuk mengatur API key").

### `agentbox config`

- Input API key tanpa echo (`stty -echo`), simpan ke `config/env` dengan `chmod 600`.
- Tampilkan nilai yang tersimpan hanya dalam bentuk masked (mis. `sk-ant-…a1b2`).
- Bisa non-interaktif: `agentbox config set KEY VALUE`, `agentbox config unset KEY`.
- WebUI (tanpa TTY): `agentbox config set KEY --stdin` dan `agentbox config hermes-key KEY --stdin`. Nilai
  dibaca dari stdin (WebUI mengopernya sebagai base64 di perintah `ksu.exec`, proses root; `/proc` Android
  memakai hidepid), divalidasi ASCII tercetak tanpa spasi (1-4096), dan tidak pernah di-log.
- `hermes-key` menyimpan lewat `hermes config set` sebagai agent (Hermes sendiri yang menulis `.env`), hanya
  untuk kunci rahasia yang **sudah ada** di `.env` Hermes atau kunci utama provider aktif (peta di
  `hermes_provider_key`, dari `_REGISTRY_ROWS` di `hermes_cli/auth.py`). Gateway yang berjalan di-restart.
  Catatan: untuk provider anthropic, Hermes memakai `ANTHROPIC_API_KEY` lebih dulu daripada `ANTHROPIC_TOKEN`.
- `agentbox config hermes-api on|rotate|off|show|status [--json]`: Gateway API Server Hermes untuk aplikasi
  klien seperti [hermes-android](https://github.com/rusty4444/hermes-android). `on` membuat `API_SERVER_KEY` acak
  (32 byte `/dev/urandom`, base64url, 43 karakter) lewat `hermes config set`, `off` memakai `hermes config unset`,
  lalu gateway yang berjalan di-restart. `on` idempoten (kunci lama dipakai); `rotate` mengganti. `show` adalah
  satu-satunya jalan kunci keluar mentah (atas permintaan eksplisit, untuk diisi di aplikasi).
- **Kredensial Anthropic** (teruji 2026-10-12: token `sk-ant-oat01` 52 karakter ditolak 401, tersimpan di
  `ANTHROPIC_TOKEN` Hermes **dan** di `ANTHROPIC_API_KEY` agentbox):
  - Login langganan (Pro/Max/Team) yang disarankan: `claude auth login --claudeai` sebagai agent (profil Terminal
    `claude-login`) → `~/.claude/.credentials.json` (refresh token, diperbarui otomatis). Lalu
    `agentbox config hermes-link-claude [--model M]` mengosongkan `ANTHROPIC_API_KEY`/`ANTHROPIC_TOKEN`/`CLAUDE_CODE_OAUTH_TOKEN`
    di `.env` Hermes (`hermes config unset`), sehingga Hermes memakai login Claude Code (fallback resminya;
    sama dengan `use_anthropic_claude_code_credentials`). Fallback itu hanya aktif bila `model.provider` =
    `anthropic`, jadi provider lain dialihkan seperti `hermes model`: `model.provider anthropic`, `model.default`
    (default `HERMES_CLAUDE_MODEL` = `claude-sonnet-5`, model Claude yang sudah dipakai dipertahankan), dan
    `model.base_url`/`api_key`/`api_mode` dibuang (base_url lama tetap dipakai provider anthropic, teruji).
    `config.yaml` lama dicadangkan ke `config.yaml.before-claude`. Cadangan: profil `hermes-auth` (`hermes auth add anthropic`).
  - `anth_guard` menolak token di variabel yang salah: Claude Code `ANTHROPIC_API_KEY` hanya `sk-ant-api…`
    (token OAuth → `CLAUDE_CODE_OAUTH_TOKEN`); Hermes `ANTHROPIC_API_KEY` = API key, `ANTHROPIC_TOKEN` = OAuth.
    Nilai yang bukan `sk-ant-…` juga ditolak (teruji 2026-10-14: kunci provider lain di `ANTHROPIC_API_KEY`
    agentbox menimpa login Claude Code → TUI "invalid API key"), kecuali Claude Code `ANTHROPIC_API_KEY` bila
    `ANTHROPIC_BASE_URL` (proxy) ada di `config/env`. `doctor` menyarankan `config unset` bila variabel env
    menimpa login yang ada.
  - `agentbox config auth-check [--json]`: sumber yang benar-benar dipakai (Claude Code: `ANTHROPIC_API_KEY` →
    `CLAUDE_CODE_OAUTH_TOKEN` → login; Hermes: `ANTHROPIC_API_KEY` → `ANTHROPIC_TOKEN` → `CLAUDE_CODE_OAUTH_TOKEN`
    → login) lalu dicek ke `GET /v1/models` (gratis, tanpa percakapan; header lewat file 600, bukan argv).
    Status: `valid`, `invalid` (401), `wrong-var`, `refreshable` (access token login kedaluwarsa tapi ada refresh
    token: tidak dicek), `offline`, `unknown` (kode HTTP lain), `none`, `not-anthropic` (provider Hermes lain:
    tidak dicek). Teruji: access token login Claude Team yang valid mendapat 200 dari `/v1/models`.
    Dipakai `doctor` (FAIL/WARN) dan halaman Konfigurasi.
- `agentbox config gateway --finish`: hanya langkah setelah wizard (tanpa TTY), dipakai terminal WebUI.
- `agentbox config show --json` (WebUI): isi `config/env` + ringkasan konfigurasi Hermes (provider, model,
  variabel rahasia `.env` Hermes, Telegram). Nilai rahasia **hanya** keluar tersamar (`mask`), tidak pernah mentah.
- `agentbox config gateway` menjalankan `hermes gateway setup` sebagai `agent` di dalam chroot.
  Jangan menulis token Telegram sendiri ke `~/.hermes/.env` dengan nama variabel tebakan;
  serahkan ke wizard Hermes. Setelah selesai, pastikan `/home/agent/.hermes/.env` ber-permission `600`
  dan dimiliki `agent`, lalu restart service.

### `agentbox doctor`

Setiap cek mencetak `OK`, `WARN`, atau `FAIL` beserta perintah perbaikannya. Cek yang dilakukan:
arsitektur arm64, rootfs ada, ruang disk `/data`, status mount, DNS (`resolv.conf` + resolve domain),
koneksi HTTPS dan sertifikat, locale, user `agent`, `claude --version`, Hermes terpasang, API key terisi,
status `gateway.sh status`, gateway sudah dikonfigurasi (`~/.hermes/.env` ada),
serta hasil `hermes doctor` (dijalankan sebagai `agent`, output-nya diteruskan).

`--fix` hanya boleh melakukan perbaikan **non-destruktif**: tulis ulang `resolv.conf`, mount ulang,
restart service, perbaiki permission `config/env`. Tidak boleh menghapus data atau menjalankan `reset`.
`doctor` (tanpa `--fix`) dan `shell` harus tetap berfungsi tanpa koneksi internet.

## Mount

Bind mount yang dibutuhkan ke dalam rootfs: `/dev`, `/dev/pts`, `/proc`, `/sys`, dan `/data/media/0`
(muncul sebagai `/sdcard` di dalam chroot). Sumbernya sengaja **bukan** `/sdcard`: itu FUSE MediaProvider yang
menolak uid `agent` (teruji). Akses langsung lewat `/data/media/0` memakai grup `media_rw` (1023). Efek
sampingnya, file baru tidak langsung terlihat di galeri/aplikasi media sampai media di-scan ulang.
`/dev/shm` di-mount sebagai `tmpfs` (beberapa tool Node/Python membutuhkannya).

- Cek status mount dengan `grep " $target " /proc/mounts`. Jangan andalkan `mountpoint`
  (tidak selalu ada di toybox).
- Mount harus idempoten: jangan mount dua kali ke target yang sama.
- Umount dalam urutan terbalik, gunakan `umount -l` sebagai fallback.

## ⚠️ Aturan keamanan kritis

- **Sebelum `rm -rf` apa pun di bawah rootfs, WAJIB umount semua bind mount dan verifikasi lewat
  `/proc/mounts`.** Kalau `/sdcard` masih ter-bind, `rm -rf rootfs` akan menghapus isi penyimpanan internal
  user. Ini berlaku untuk `uninstall.sh`, `agentbox reset`, dan skrip lain. Kalau verifikasi gagal → abort.
- Jangan pernah menghapus berdasarkan variabel yang bisa kosong (`rm -rf "$ROOTFS/"*` dengan `$ROOTFS`
  kosong). Validasi variabel path tidak kosong dan diawali `/data/adb/agentbox` sebelum operasi destruktif.
- `agentbox reset` wajib: menghentikan service, umount + verifikasi, menawarkan `agentbox backup` lebih dulu,
  dan meminta user mengetik `RESET` sebagai konfirmasi. Tanpa TTY → tolak, kecuali diberi flag `--yes`.
- Agent selalu berjalan via `su agent` / `setpriv --reuid=agent` (dipakai `gateway.sh`). Jangan menambahkan opsi untuk menjalankan sebagai root.
- User `agent` **tidak** dimasukkan ke sudoers atau grup `wheel`. Instalasi paket dilakukan lewat
  `agentbox install` atau `agentbox shell --root`, supaya Claude Code dan Hermes tidak bisa naik ke root.
- File `config/env` tidak boleh di-log, di-echo, atau di-commit.

## Konvensi shell

- Skrip sisi Android (`*.sh` di root module, `system/bin/*`, `lib/common.sh`): shebang `#!/system/bin/sh`,
  **POSIX sh saja**, tanpa bashism (`[[ ]]`, array, `function`, `local -a`, `$'...'`).
- Skrip di dalam chroot (`rootfs-setup/*`): boleh `#!/bin/bash`.
- Untuk applet yang perilakunya beda di toybox (`tar`, `wget`, `xz`), panggil eksplisit via
  `"$BUSYBOX" <applet>`.
- Setiap skrip: `set -e` bila sesuai, logging lewat helper `ab_log()` di `lib/common.sh` ke `logs/`.
- Wrapper `claude`/`hermes` harus meneruskan argumen dengan aman (quoting benar), meneruskan `TERM`
  (default `xterm-256color`), set `LANG=C.UTF-8`, `HOME=/home/agent`, dan PATH yang menyertakan
  `/home/agent/.local/bin`.
- Lint: `shellcheck -s sh` untuk skrip Android, `shellcheck -s bash` untuk skrip chroot. Kode harus lolos tanpa warning.

## Gateway Hermes (tanpa runit)

`lib/gateway.sh`, `service.sh`, dan halaman Gateway WebUI **sudah dibuat** dan lolos `shellcheck` / `node --check`.
Jangan ditulis ulang tanpa alasan; perbaiki di tempat bila ada bug.

Cara kerja `lib/gateway.sh`:

- `start` memvalidasi (Hermes terpasang, `~/.hermes/.env` ada, mount sukses), lalu meluncurkan
  `gateway.sh supervise` terlepas dari parent (`busybox setsid`, stdio ke `/dev/null`).
- Supervisor (loop shell sisi Android) menunggu DNS `api.telegram.org` (maks ~60 detik), lalu menjalankan
  `busybox setsid chroot $ROOTFS setpriv --reuid=agent ... env -i ... hermes gateway` dengan output ke
  `logs/gateway.log`. Gateway jadi pemimpin process group sendiri, jadi `stop` mematikan seluruh group
  (termasuk subprocess yang dibuat Hermes).
- Crash → restart dengan backoff 10 s, digandakan sampai maks 5 menit. Backoff kembali ke 10 s bila gateway
  sempat hidup ≥ 2 menit.
- `stop` membuat file `run/gateway.stop`, mengirim TERM ke supervisor, lalu supervisor menghentikan gateway
  (TERM, KILL setelah 15 detik). Bila supervisor tidak merespons dalam 25 detik, `stop` mematikan langsung.
- Log dirotasi copy-truncate saat > 1 MB (`gateway.log.1`, `.2`).
- `status --json` → `{"state":"running|restarting|stopped","pid":…,"uptime":…,"autostart":…,"installed":…,"configured":…}`.
  Format ini dipakai WebUI (halaman Gateway dan Status di `webroot/index.html`); jangan diubah tanpa mengubah keduanya.
- "Configured" = `~/.hermes/.env` ada **dan** penanda `state/gateway.done` ada. `.env` saja tidak cukup karena
  installer Hermes selalu membuatnya dari template; penanda ditulis setelah `hermes gateway setup` sukses
  (lewat `agentbox setup gateway` atau `agentbox config gateway`).
- Autostart = keberadaan file `config/gateway.autostart`. `service.sh` hanya start gateway bila file ini ada.
- File PID: `run/gateway-supervisor.pid` dan `run/gateway.pid`. Kehidupan proses dicek lewat `/proc`
  (bukan zombie, dan cmdline supervisor berisi `gateway.sh supervise`), jadi PID basi setelah reboot aman.

Aturan:

- **Jangan** memakai `hermes gateway install/start/stop/status`: itu untuk systemd, yang tidak berjalan di chroot.
- Sebelum umount (reset/uninstall): `gateway.sh stop` dulu, lalu `ab_umount` (yang memverifikasi).
- Setelah `agentbox config gateway` selesai, jalankan `gateway.sh restart` bila gateway sedang berjalan.
- `setpriv` berasal dari `util-linux` di rootfs Void; `agentbox doctor` harus mengecek keberadaannya.

### WebUI: halaman Gateway (`#/gateway`)

- Memanggil `sh /data/adb/modules/agentbox/lib/gateway.sh …` lewat `ksu.exec(cmd, "{}", callbackName)`
  dengan callback `(errno, stdout, stderr)`. Cocokkan dengan dokumentasi WebUI KernelSU versi target.
- Fitur: status besar (Berjalan / Menunggu restart / Berhenti) dengan uptime dan PID, tombol
  Jalankan/Hentikan dan Mulai ulang, switch "Jalankan saat HP menyala" (autostart), dan tampilan 200 baris log.
- Status di-poll tiap 3 detik selama tab Gateway aktif dan layar menyala. Bila Hermes belum terpasang atau gateway belum
  dikonfigurasi, tombol Jalankan dinonaktifkan dan muncul tautan ke profil Terminal yang sesuai.
- Tanpa CDN atau dependensi eksternal (WebUI harus jalan offline). Mendukung tema terang/gelap.

### WebUI: struktur halaman

- **Satu dokumen (SPA)**: `index.html` (dibuka KernelSU) berisi keempat halaman sebagai komponen Preact, routing
  lewat hash `#/<page>?<params>` (`status`, `gateway`, `tty`, `config`; tak dikenal -> `status`). Pindah tab tidak
  memuat ulang dokumen; tombol back Android berpindah antar-tab. Daftar tab satu sumber di `AB.NAV` (`app.js`).
- **Keep-alive**: halaman yang pernah dibuka tetap ter-mount, hanya disembunyikan (`hidden`), jadi state-nya
  bertahan (data, draft form, sesi xterm). Tiap halaman menerima `active`; polling dan pembaruan saat layar
  menyala (`useWhileVisible`) **wajib** berhenti saat tidak aktif (tiap tick = `ksu.exec`). Saat tab dibuka lagi,
  data lama langsung tampil lalu disegarkan di latar. Posisi scroll disimpan per halaman.
- **CSS per halaman dibatasi** kelas akar (`.gw`, `.cfg`, `.tty`): semua halaman berbagi satu dokumen, jadi aturan
  global seperti `button {}` akan bocor ke halaman lain.
- **Jebakan Preact** (pernah terjadi): elemen bersyarat tanpa `key` di antara saudara bertipe sama bisa dicocokkan
  dengan elemen lain sehingga elemen itu dibuat ulang (switch kehilangan fokus) -> pakai slot tetap + `hidden`.
  Container `#app` dikosongkan sebelum `render` (placeholder lama tertinggal di bawah nav).
- **Status** (`#/status`, route default): `agentbox status --json` (cepat, ~0,4 dtk), lalu `--versions` menyusul
  (hermes `--version` ~5 dtk, sekali per sesi kecuali Muat ulang). Menampilkan langkah berikutnya + tautan ke Terminal.
- **Konfigurasi** (`#/config`): `agentbox config show --json`; perubahan dilakukan lewat wizard di Terminal
  (`#/tty?profile=<id>` memilih profil, tidak langsung memulai), plus form edit kunci sebaris: kunci Hermes
  (`config hermes-key`) dan `config/env` Claude Code (`config set/unset`, hapus dengan dua ketukan). Kartu
  "Aplikasi Hermes Android" (`config hermes-api`): aktifkan, tampilkan/salin kunci (diambil hanya saat diminta,
  disembunyikan lagi setelah 60 dtk atau saat tab ditinggalkan), ganti kunci/nonaktifkan dengan dua ketukan, unduh
  aplikasi (browser bawaan). Tidak dimuat ulang saat tab dibuka lagi bila form kunci sedang terbuka.
- Halaman lain menautkan ke Terminal dengan `#/tty?profile=<id>` (dipilih tiap kali tautan diketuk, kecuali profil
  diblokir atau sesi berjalan); tanpa profil, Terminal memilih langkah setup berikutnya hanya pada pembukaan pertama.
- **Library UI**: Preact + htm lewat bundel resmi `htm/preact/standalone.umd.js`
  (htm 3.1.1, ~13 KB, satu file di `vendor/htm-preact.umd.js`, global `window.htmPreact`). Dipilih karena tanpa
  build step, offline, dan Preact meng-escape teks otomatis (tidak ada `innerHTML` dengan data CLI). Dimuat lewat
  `<script>` UMD biasa, bukan ES module (MIME `type="module"` di WebView KernelSU belum diverifikasi). Teruji di HP
  (2026-10-13). Library tambahan wajib di-vendor beserta lisensinya; tetap **tanpa CDN** dan **tanpa build step**.

### PROTOTIPE: terminal WebUI (`#/tty` + `lib/tty.sh`)

Tujuan: menjalankan wizard interaktif Hermes (`hermes setup`, `hermes model`, `hermes gateway setup`) dari
WebUI tanpa Termux. Masih prototipe; menyimpang dari aturan "satu file" karena xterm.js 5.5.0 + addon-fit
(MIT) disimpan lokal di `webroot/vendor/` (tetap offline, tanpa CDN).

- Di SPA, xterm dan logikanya imperatif (`createTerminal`): Preact hanya merender `<div class="tty">` kosong.
  xterm.js dimuat saat tab Terminal pertama kali dibuka. Saat tab lain aktif, polling output berhenti (output
  menyusul lewat offset), ukuran tidak diukur, dan `kb-open`/fokus keyboard dilepas. Layout layar penuh (flex, tanpa
  scroll, nav inline) hanya saat `html.route-tty`.
- **Tanpa port jaringan** (loopback Android bisa diakses semua aplikasi). `script` (util-linux, di chroot)
  menyediakan pty; di dalamnya `su -l -P agent -c <perintah>`. Input lewat FIFO `run/tty/in`, output ke
  `run/tty/out`; WebUI polling `tty.sh read <offset>` (~120 ms saat aktif, ~700 ms saat diam).
- Keyboard Android: WebView KernelSU **tidak** melaporkan tinggi keyboard (visualViewport tetap). Saat input
  fokus, halaman dipendekkan ke 55% (`body.kb-open`) agar terminal + baris tombol tetap di atas keyboard.
  Tombol layar tidak mengambil fokus; tombol ⌨ mengatur `inputmode` textarea xterm (default mati).
- Hanya **profil tetap**, tidak ada shell bebas (WebUI berjalan sebagai root). Dua jenis:
  - *agent*: `demo`, `hermes-setup`, `hermes-model`, `gateway-setup`, `claude-login`
    (`claude auth login --claudeai`), `hermes-auth` (`hermes auth add anthropic`) -> perintah di chroot sebagai
    `agent`. Setelah kedua profil login, `tty.sh` menampilkan `config auth-check`. Tombol layar **Tempel** membaca
    clipboard (kode login OAuth; baris baru dibuang); bila WebView menolak, pakai ⌨ lalu tempel dari keyboard.
  - *cli*: `setup` = `agentbox setup` (menu komponen), `hermes-install` = `agentbox setup hermes`, `hermes-reinstall` = `agentbox setup --force hermes`
    (installer dijalankan ulang; `~/.hermes` tidak dihapus; gateway yang berjalan di-restart oleh CLI).
    Dijalankan sebagai root di pty `busybox script` sisi
    Android (logika setup tetap di CLI). busybox `script` tidak meneruskan exit code, jadi disimpan ke
    `run/tty/cli.rc`; `SHELL=/system/bin/sh` wajib karena Android tidak punya `/bin/sh`. Satu sesi sekaligus; halaman yang dibuka ulang menyambung ke sesi berjalan.
- Status profil (`tty.sh profiles`, JSON): `done`/`todo`/`blocked`/`none`. install Hermes = penanda
  `hermes.done` + binary ada; hermes setup/model = `model.provider` di `config.yaml` ada dan bukan `auto`
  (template installer berisi `auto`; dibaca dengan awk karena `hermes config get` butuh ~2-3 detik);
  gateway setup = penanda `gateway.done`. Profil yang butuh Hermes diblokir sampai Hermes terpasang.
  WebUI menandai opsi (✓ / belum / butuh …), menampilkan langkah berikutnya, dan menyegarkan status
  setiap sesi selesai.
- Data input/output dioper sebagai base64 (byte mentah, termasuk escape sequence). Resize lewat
  `stty -F /dev/pts/N` (pty luar); `su -P` meneruskan SIGWINCH ke pty dalam.
- Teruji dari shell: input baris, satu tombol mentah, menu `hermes model`, resize, stop. **Belum teruji**
  di WebView KernelSU: latensi `ksu.exec` dan keyboard virtual Android.
- Setelah profil `gateway-setup` keluar dengan kode 0, `tty.sh` menjalankan `agentbox config gateway --finish`
  (logika sama dengan CLI) dan menampilkan hasilnya di terminal: `.env` 600 milik agent, penanda
  `gateway.done`, lalu konfigurasi pertama -> autostart on + start; konfigurasi ulang -> restart bila berjalan.
  Kode keluar wizard selain 0 -> pasca-proses dilewati.

## Hasil verifikasi (2026-10-11)

- **Installer Hermes** (`scripts/install.sh`, NousResearch/hermes-agent) memakai protokol *stage*:
  `prerequisites repository venv python-deps config products setup gateway complete`, bisa dijalankan
  satu per satu dengan `--stage NAME`. Stage `gateway` menjalankan `hermes gateway install` (systemd),
  jadi komponen `hermes` menjalankan semua stage **kecuali** `gateway`; platform diatur lewat komponen
  `gateway` (`hermes gateway setup`). Stage `setup` = `hermes setup` (interaktif, baca `/dev/tty`).
- Installer tidak lagi memakai venv `.[all]`: uv, Python, Node, ripgrep, dan **FFmpeg** diunduh sendiri
  oleh package manager Hermes (pm). Tidak perlu `ffmpeg` dari xbps. Node glibc butuh `libatomic`
  (dipasang di komponen `base`).
- Installer menolak berjalan bila mendeteksi Termux (`TERMUX_VERSION` / `PREFIX`), jadi env harus bersih
  (`env -i` / `su -`), yang memang sudah dilakukan.
- Mirror Void: `https://repo-default.voidlinux.org/live/current/void-aarch64-ROOTFS-YYYYMMDD.tar.xz`
  (terakhir `20250202`), checksum di `sha256sum.txt` format BSD (`SHA256 (file) = hash`).
  Rootfs sudah berisi `bash`, `setpriv`, `su`, `useradd`, tapi belum `curl`.
- Device target memakai metamodule (mountify), jadi overlay `system/bin` aktif. Fallback bila tidak aktif:
  `service.sh` menulis stub `agentbox`/`claude`/`hermes` ke `$PREFIX/bin` Termux (bukan symlink: Termux
  tidak bisa menembus `/data/adb`). Stub dan wrapper naik ke root lewat `su -c` bila dipanggil non-root.
- **hermes-android** (Flutter, MIT) adalah klien chat, bukan pengganti agentbox. Chat cukup lewat Gateway API
  Server: platform di dalam `hermes gateway` (`gateway/platforms/api_server.py`), aktif bila `API_SERVER_KEY` >= 16
  karakter, default bind `127.0.0.1:8642`, setiap request wajib `Bearer` (teruji di chroot: 401 tanpa/kunci salah,
  200 dengan kunci). Aplikasi mengizinkan HTTP cleartext dan punya mode API-only (tanpa dashboard).
- **Jangan aktifkan dashboard Hermes (9119) di HP**: pada bind loopback tanpa `public_url` ia tanpa login dan token
  sesinya disisipkan ke HTML, jadi aplikasi lain di HP bisa mengambil alih Hermes (`--insecure` pun diabaikan).
- **Uji dari sesi Claude Code**: tiap perintah berjalan di PID namespace sandbox sendiri, jadi proses latar dari
  uji sebelumnya tidak terlihat/terjangkau lewat PID. Hentikan gateway uji lewat socket kontrolnya:
  `{"verb":"pause-for-update","id":1,"protocol":1}` ke `$HERMES_HOME/gateway.sock` (gateway keluar dengan rapi).

## Keputusan implementasi tambahan

- User `agent` memakai **UID/GID tetap 8061** (rentang 8000-8999 tidak dipakai AID Android). Default
  `useradd` (1000) bentrok dengan `AID_SYSTEM` di kernel host, padahal `/dev/binder` ikut ter-bind ke chroot.
  UID >= 10000 yang bukan aplikasi **diblokir netd** (teruji: koneksi timeout), jadi harus < 10000.
- `agent` dimasukkan ke grup Android `aid_inet` (3003) dan `aid_net_raw` (3004), karena kernel Android
  (paranoid network) menolak socket jaringan tanpa grup ini, serta `media_rw` (1023) agar bisa menulis ke
  `/sdcard`. Ini bukan grup privilese root; aturan "tanpa sudo/wheel" tetap berlaku.
- Login interaktif sebagai agent memakai `su -l -P` (pty baru). Teruji: `su -c` tanpa `-P` membuat session
  baru tanpa terminal pengendali, sehingga installer Hermes menganggap "no terminal" dan melewati `hermes setup`.
  Jangan pakai `--session-command`: proses agent bisa menyuntik keystroke (TIOCSTI) ke terminal root
  (kernel 5.4 belum punya `dev.tty.legacy_tiocsti`).
- Mount bersifat **per mount namespace** KernelSU: sesi `su` yang berbeda bisa tidak saling melihat mount.
  `ab_mount` idempoten per namespace, dan `rm` hanya menelusuri mount di namespace-nya sendiri.
- `config/env` diteruskan ke `claude`/`hermes` lewat environment (bukan argv, karena `/proc/*/cmdline`
  terbaca semua user). `agentbox shell` meneruskannya lewat `su -w`.

## Log

| File (`/data/adb/agentbox/logs/`) | Isi | Aktif |
|---|---|---|
| `agentbox.log` | ringkasan aksi (`ab_log`) | selalu |
| `setup.log` | output lengkap tiap komponen setup (dipakai untuk menampilkan baris error saat gagal) | selalu |
| `gateway.log` | output gateway + supervisor | selalu |
| `debug.log` | `ab_debug`: rencana setup, perintah + exit code, durasi komponen, trace `set -x` dari `setup.sh`; installer Hermes dijalankan dengan `--verbose` | hanya build **debug** |

- Mode ditentukan `lib/build.conf` yang ditulis `tools/build.sh` (`AB_BUILD=release|debug`, `AB_DEBUG=0|1`).
  Tanpa file itu (menjalankan dari repo) mode `dev`, debug mati. `agentbox status` menampilkan mode build.
- Override saat runtime tanpa build ulang: `su -c 'AGENTBOX_DEBUG=1 agentbox setup ...'` (atau `=0`).
- `debug.log` ber-permission `600`, dirotasi ke `debug.log.1` saat > 5 MB.
- Jangan pernah mengoper nilai dari `config/env` ke `ab_debug` (hanya nama variabel).

## Versi dan rilis

- **Semver**, sumber tunggal `module.prop`: `version=vMAJOR.MINOR.PATCH[-PRE]`,
  `versionCode=MAJOR*10000+MINOR*100+PATCH` (MINOR/PATCH < 100; pre-release memakai versionCode versi dasarnya).
  Jangan edit manual: `sh tools/bump-version.sh patch|minor|major|X.Y.Z[-pre]`.
- `.github/workflows/release.yml`: push ke `main` yang mengubah `module.prop` (atau dijalankan manual) →
  `bump-version.sh --check` → lewati bila tag sudah ada → shellcheck 0.10.0 (dipatok, sama dengan pengembangan)
  → `build.sh release` + `debug` + `SHA256SUMS` → `gh release create vX.Y.Z --generate-notes` (pre-release
  ditandai). Nilai dari `module.prop` dioper lewat `env:`, bukan `${{ }}` di skrip. Divalidasi dengan actionlint.
- **Update dari KernelSU Manager**: `module.prop` punya
  `updateJson=https://github.com/rjial/agentbox/releases/latest/download/update.json` (`latest` = rilis stabil
  terbaru, bukan pre-release). Workflow membuat `update.json` (`version`, `versionCode`, `zipUrl` ke
  `agentbox-vX.Y.Z-release.zip`, `changelog`) dengan `jq` dan `changelog.md` (commit sejak tag sebelumnya),
  hanya untuk rilis stabil. Nama zip di `zipUrl` harus sama dengan keluaran `tools/build.sh release`.
  Zip debug juga membawa `updateJson`, jadi update dari Manager mengganti build debug dengan build release.

## Testing

```sh
# build zip (hasil: dist/agentbox-<versi>-<tipe>.zip)
sh tools/build.sh release      # log debug mati
sh tools/build.sh debug        # log debug aktif, versi module diberi akhiran -debug

# install ke device
adb push dist/agentbox-v0.1.0-debug.zip /data/local/tmp/agentbox.zip
adb shell su -c '/data/adb/ksud module install /data/local/tmp/agentbox.zip'   # ksud tidak ada di PATH
adb reboot

# setup & cek
adb shell su -c 'agentbox setup'
adb shell su -c 'agentbox doctor'
adb shell -t su -c 'agentbox shell'          # -t agar dapat TTY; masuk sebagai agent
adb shell -t su -c 'agentbox shell --root'
adb shell -t su -c 'agentbox shell --safe'
adb shell su -c 'agentbox status'
adb shell su -c 'cat /data/adb/agentbox/logs/*.log'
```

Setiap perubahan pada `uninstall.sh`, `agentbox reset`, atau helper umount wajib dites di device dengan file
dummy di `/sdcard` untuk memastikan tidak ikut terhapus.
