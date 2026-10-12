#!/bin/sh
# Versi agentbox mengikuti semver; module.prop adalah satu-satunya sumber versi.
#
#   sh tools/bump-version.sh patch|minor|major   naikkan versi (pre-release dibuang)
#   sh tools/bump-version.sh 1.2.0[-rc.1]         setel versi tertentu
#   sh tools/bump-version.sh --check              validasi module.prop; cetak version=, tag=, prerelease=
#                                                 (dipakai GitHub Actions untuk rilis)
#
# Aturan:
#   version=vMAJOR.MINOR.PATCH[-PRERELEASE]
#   versionCode=MAJOR*10000 + MINOR*100 + PATCH   (MINOR dan PATCH < 100)
# KernelSU membandingkan versionCode (angka) untuk mendeteksi update, jadi rumus ini menjaga urutannya.
# Pre-release memakai versionCode yang sama dengan versi dasarnya.
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
prop="$root/module.prop"

die() {
	echo "bump-version: $*" >&2
	exit 1
}

prop_get() {
	sed -n "s/^$1=//p" "$prop" | head -n 1
}

# Pecah "MAJOR.MINOR.PATCH[-PRE]" ke variabel v_major, v_minor, v_patch, v_pre.
parse() {
	case "$1" in
	*[!0-9A-Za-z.-]* | "") die "versi tidak valid: '$1'" ;;
	esac
	v_pre=""
	case "$1" in *-*) v_pre=${1#*-} ;; esac
	v_base=${1%%-*}
	old_ifs=$IFS
	IFS=.
	# shellcheck disable=SC2086  # sengaja dipecah per titik
	set -- $v_base
	IFS=$old_ifs
	[ $# -eq 3 ] || die "versi harus MAJOR.MINOR.PATCH: '$v_base'"
	for n in "$1" "$2" "$3"; do
		case "$n" in "" | *[!0-9]*) die "bagian versi bukan angka: '$n'" ;; esac
		case "$n" in 0?*) die "bagian versi tidak boleh diawali 0: '$n'" ;; esac
	done
	v_major=$1 v_minor=$2 v_patch=$3
	if [ "$v_minor" -ge 100 ] || [ "$v_patch" -ge 100 ]; then
		die "MINOR dan PATCH harus < 100 (rumus versionCode)"
	fi
	case "$v_pre" in
	*..* | .* | *. ) die "pre-release tidak valid: '$v_pre'" ;;
	esac
}

code_of() {
	echo $((v_major * 10000 + v_minor * 100 + v_patch))
}

[ -f "$prop" ] || die "module.prop tidak ditemukan di $root"
cur=$(prop_get version)
cur_code=$(prop_get versionCode)
case "$cur" in v*) ;; *) die "version di module.prop harus diawali 'v': '$cur'" ;; esac
parse "${cur#v}"

case "${1:-}" in
--check)
	want=$(code_of)
	[ "$cur_code" = "$want" ] ||
		die "versionCode=$cur_code tidak cocok dengan $cur (seharusnya $want). Perbaiki: sh tools/bump-version.sh ${cur#v}"
	echo "version=${cur#v}"
	echo "tag=$cur"
	if [ -n "$v_pre" ]; then echo "prerelease=true"; else echo "prerelease=false"; fi
	echo "versionCode=$cur_code"
	exit 0
	;;
major) new="$((v_major + 1)).0.0" ;;
minor) new="$v_major.$((v_minor + 1)).0" ;;
patch) new="$v_major.$v_minor.$((v_patch + 1))" ;;
"" | -h | --help)
	sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
*) new=${1#v} ;;
esac

parse "$new"
new_code=$(code_of)
[ "$new_code" -ge "$cur_code" ] || die "versi baru v$new (versionCode $new_code) lebih kecil dari $cur ($cur_code)"
[ "v$new" != "$cur" ] || die "versi sudah $cur"

sed -i "s/^version=.*/version=v$new/; s/^versionCode=.*/versionCode=$new_code/" "$prop"
echo "module.prop: $cur ($cur_code) -> v$new ($new_code)"
echo "Langkah berikutnya:"
echo "  git commit -am \"Rilis v$new\" && git push"
echo "  GitHub Actions membuat release v$new beserta zip-nya."
