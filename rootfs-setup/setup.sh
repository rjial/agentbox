#!/bin/bash
# Dijalankan DI DALAM chroot sebagai root oleh `agentbox setup`:
#   setup.sh <base|locale|user|claude|uv|hermes-fetch>
# Tiap langkah idempoten. Konstanta dioper lewat env oleh agentbox:
#   AGENT, AGENT_UID, AGENT_HOME, AB_ANDROID_GROUPS
set -euo pipefail

AGENT="${AGENT:-agent}"
AGENT_UID="${AGENT_UID:-8061}"
AGENT_HOME="${AGENT_HOME:-/home/agent}"
AB_ANDROID_GROUPS="${AB_ANDROID_GROUPS:-aid_inet:3003 aid_net_raw:3004 media_rw:1023}"
AGENT_PATH="$AGENT_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
DL_DIR="$AGENT_HOME/.cache/agentbox"

# Mode debug (build debug / AGENTBOX_DEBUG=1): trace `set -x` ke file terpisah agar output terminal
# tetap bersih; agentbox memindahkannya ke logs/debug.log setelah langkah ini selesai.
if [ "${AB_DEBUG:-0}" = 1 ] && [ -n "${AB_TRACE:-}" ]; then
	mkdir -p "$(dirname "$AB_TRACE")"
	exec 9>>"$AB_TRACE"
	BASH_XTRACEFD=9
	PS4='+ setup.sh:${LINENO}: '
	set -x
fi

BASE_PKGS=(nodejs python3 git curl bash sudo ca-certificates util-linux shadow pam
	tar xz gzip unzip which procps-ng libatomic libstdc++
	base-devel python3-devel libffi-devel openssl-devel)

step() { printf '==> %s\n' "$*"; }

die() {
	printf 'GAGAL: %s\n' "$*" >&2
	exit 1
}

# Jalankan perintah sebagai agent dengan env bersih (tanpa PAM, sama seperti gateway.sh).
as_agent() {
	setpriv --reuid="$AGENT" --regid="$AGENT" --init-groups \
		env -i HOME="$AGENT_HOME" USER="$AGENT" LOGNAME="$AGENT" SHELL=/bin/bash \
		LANG=C.UTF-8 TERM="${TERM:-xterm-256color}" PATH="$AGENT_PATH" \
		bash -c "cd \"\$HOME\" && $1"
}

do_base() {
	step "menulis /etc/resolv.conf"
	if [ ! -s /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
		rm -f /etc/resolv.conf
		printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf
	fi

	step "update xbps"
	xbps-install -Syu xbps
	step "update seluruh paket"
	xbps-install -yu
	step "install paket dasar: ${BASE_PKGS[*]}"
	xbps-install -Sy "${BASE_PKGS[@]}"

	step "prompt [agentbox]"
	mkdir -p /etc/bash/bashrc.d
	cat >/etc/bash/bashrc.d/agentbox.sh <<'EOF'
# Ditulis oleh agentbox: tandai bahwa shell ini ada di dalam chroot.
PS1='[agentbox] \u\$ '
EOF
	if [ -f /etc/bash/bashrc ] && ! grep -q 'bashrc.d/agentbox.sh' /etc/bash/bashrc; then
		printf '\n[ -r /etc/bash/bashrc.d/agentbox.sh ] && . /etc/bash/bashrc.d/agentbox.sh\n' >>/etc/bash/bashrc
	fi
	cat >/etc/profile.d/agentbox.sh <<'EOF'
# Ditulis oleh agentbox.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH
if [ -n "${BASH_VERSION:-}" ]; then
	PS1='[agentbox] \u\$ '
elif [ "$(id -u)" = 0 ]; then
	PS1="[agentbox] $(id -un)# "
else
	PS1="[agentbox] $(id -un)\$ "
fi
EOF
	command -v setpriv >/dev/null || die "setpriv (util-linux) tidak ditemukan setelah install"
}

do_locale() {
	step "install glibc-locales"
	xbps-install -Sy glibc-locales
	step "aktifkan en_US.UTF-8"
	if grep -q '^#\s*en_US.UTF-8 UTF-8' /etc/default/libc-locales; then
		sed -i 's/^#\s*\(en_US.UTF-8 UTF-8\)/\1/' /etc/default/libc-locales
	elif ! grep -q '^en_US.UTF-8 UTF-8' /etc/default/libc-locales; then
		echo 'en_US.UTF-8 UTF-8' >>/etc/default/libc-locales
	fi
	xbps-reconfigure -f glibc-locales
	locale -a | grep -qi '^en_US.utf8$' || die "locale en_US.UTF-8 tidak terbentuk"
	printf 'LANG=en_US.UTF-8\n' >/etc/locale.conf
}

do_user() {
	for g in $AB_ANDROID_GROUPS; do
		name=${g%%:*}
		gid=${g##*:}
		if getent group "$gid" >/dev/null; then
			name=$(getent group "$gid" | cut -d: -f1)
		else
			step "buat grup $name ($gid)"
			groupadd -g "$gid" "$name"
		fi
		groups_csv="${groups_csv:+$groups_csv,}$name"
	done

	if id "$AGENT" >/dev/null 2>&1; then
		step "user $AGENT sudah ada"
		old_uid=$(id -u "$AGENT")
		if [ "$old_uid" != "$AGENT_UID" ]; then
			step "migrasi uid/gid $AGENT: $old_uid -> $AGENT_UID"
			getent group "$AGENT_UID" >/dev/null && die "gid $AGENT_UID sudah dipakai grup lain"
			getent passwd "$AGENT_UID" >/dev/null && die "uid $AGENT_UID sudah dipakai user lain"
			old_gid=$(id -g "$AGENT")
			groupmod -g "$AGENT_UID" "$AGENT"
			usermod -u "$AGENT_UID" -g "$AGENT_UID" "$AGENT"
			find / -xdev \( -uid "$old_uid" -o -gid "$old_gid" \) -not -path '/sdcard/*' \
				-exec chown -h "$AGENT:$AGENT" {} + 2>/dev/null || true
		fi
	else
		step "buat user $AGENT (uid $AGENT_UID)"
		getent group "$AGENT_UID" >/dev/null || groupadd -g "$AGENT_UID" "$AGENT"
		useradd -m -d "$AGENT_HOME" -s /bin/bash -u "$AGENT_UID" -g "$AGENT_UID" "$AGENT"
	fi
	step "grup tambahan: $groups_csv"
	usermod -a -G "$groups_csv" "$AGENT"

	# Agent sengaja TIDAK masuk wheel/sudoers: Claude Code dan Hermes tidak boleh naik ke root.
	if id -nG "$AGENT" | tr ' ' '\n' | grep -qx wheel; then
		gpasswd -d "$AGENT" wheel
	fi
	passwd -l "$AGENT" >/dev/null 2>&1 || true

	mkdir -p "$AGENT_HOME/.local/bin" "$DL_DIR"
	chown -R "$AGENT:$AGENT" "$AGENT_HOME"
	chmod 700 "$AGENT_HOME"
}

do_claude() {
	step "unduh installer resmi Claude Code"
	as_agent "mkdir -p '$DL_DIR' && curl -fsSL https://claude.ai/install.sh -o '$DL_DIR/claude-install.sh'"
	step "jalankan installer sebagai $AGENT"
	as_agent "bash '$DL_DIR/claude-install.sh'"
	step "verifikasi"
	as_agent "claude --version"
}

do_uv() {
	step "unduh installer resmi uv"
	as_agent "mkdir -p '$DL_DIR' && curl -fsSL https://astral.sh/uv/install.sh -o '$DL_DIR/uv-install.sh'"
	step "jalankan installer sebagai $AGENT"
	as_agent "UV_NO_MODIFY_PATH=1 sh '$DL_DIR/uv-install.sh'"
	as_agent "uv --version"
}

# Hermes sendiri dijalankan oleh agentbox (sisi Android) dengan TTY; di sini hanya unduh.
do_hermes_fetch() {
	step "unduh installer resmi Hermes Agent"
	as_agent "mkdir -p '$DL_DIR' && curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh -o '$DL_DIR/hermes-install.sh'"
	as_agent "bash -n '$DL_DIR/hermes-install.sh'"
}

case "${1:-}" in
base) do_base ;;
locale) do_locale ;;
user) do_user ;;
claude) do_claude ;;
uv) do_uv ;;
hermes-fetch) do_hermes_fetch ;;
*)
	echo "Pemakaian: setup.sh base|locale|user|claude|uv|hermes-fetch" >&2
	exit 2
	;;
esac
