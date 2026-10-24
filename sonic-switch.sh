#!/bin/sh

# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 SonicDE Community

# shellcheck disable=SC2009,SC2016,SC2059,SC2086

set -eu


# Constants

VER='0.9.0'
HOMEPAGE='https://sonicde.org'
REPO_HOMEPAGE='https://sonicde-arch.github.io'

PGP_KEY_ID=3B87898C73F11DF5
PGP_KEY_FILE=sonicde-archlinux.asc
PGP_KEY_URL="$REPO_HOMEPAGE/$PGP_KEY_FILE"

BINPKG_REPOS="\
stable
stable-testing
beta"
REPO_NAME_TPL='sonicde-%s'
REPO_URL_TPL='https://github.com/sonicde-arch/%s/releases/download/$arch'

KNOWN_LMS='emptty gdm greetd lemurs lightdm lxdm ly plasmalogin sddm slim soniclogin xdm'
LOG=$HOME/sonic-switch.log
NUL=/dev/null

DISTRO_TYPE='Arch Linux based'
OS_RELEASE_RE='^(ID=arch|ID_LIKE=.*arch)'


# Messages

CHOOSE_BINPKG_REPO_MSG='Please select the SonicDE repository you want to use:'
FPRINT_MSG='Please compare the key fingerprint to the one at %s. Does it look right?'
INTRO_MSG='SonicDE.org sonic-switch.sh, version: %s.

This script will install SonicDE on your system. It will restart your graphical session so please save all your work. It will also replace any conflicting KDE components with the SonicDE equivalents.
'
INSTALL_MSG='The installation of the SonicDE packages will start in %d seconds. It''s running in the background to continue in case your GUI session is getting terminated. You can find an installation log at %s.'
LM_SWITCH_MSG='SonicDE comes with the Sonic Login Manager which is highly recommended when migrating from Wayland-based setups. Do you want to switch to the Sonic Login Manager?'
THANKS_MSG='Thank you for choosing SonicDE! Please see %s for any further information.
'


# Errors

NO_CURL_WGET_ERR='No ''curl'' or ''wget'' command found. Please install one of them.'
NO_DOAS_SUDO_ERR='No ''doas'' or ''sudo'' command found. Please install one of them.'
DISTRO_ERR='This script only works on %s systems. Please see https://sonicde.org for SonicDE packages suitable for other distributions and operating systems. Aborting.'
WRONG_FPRINT_ERR='Wrong fingerprint. Aborting.'


# Functions

chooserepo() {
	printf '%s\n' "$1"
	printf '%s\n' "$2" | cut -d '|' -f 1 | grep -n '.*' | sed 's/:/) /g'
	_max=$(printf '%s\n' "$2" | wc -l)
	printf '0:exit script\n'
	while :; do
		IFS= read -r _choice || die 1 'Input closed.'
		test "$_choice" = 0 && die 1 'Exiting.'
		case $_choice in
			''|*[!0-9]*) continue ;;
			*) : ;;
		esac
		test $_choice -gt 0 -a $_choice -le $_max && break
	done
	printf '%s\n' "$2" | cut -d '|' -f 1 | sed -n "$_choice"p > repo
}

findloginman() {
	_regex=$(printf '%s' "$KNOWN_LMS" | tr ' ' '|')
	ps -A -o comm= | grep -E "^(${_regex})$" || :
}

msg() {
	fstring=$1; shift
	printf "\n$fstring\n" "$@"
}

yesno() {
	fstring=$1; shift
	printf "$fstring (y/n): " "$@"
	read -r _answer
	test "$_answer" = 'y' -o "$_answer" = 'Y' && return 0
}

die() {
	rc=$1; fstring=$2; shift 2
	printf "\n$fstring\n" "$@"
	exit "$rc"
}

thank_you() {
	printf "$THANKS_MSG\n" "$ORIG_URL"
	exit 0
}


# Intro and Prechecks

msg "$INTRO_MSG" "$VER"

command -v curl >$NUL && fetch='curl --fail --location --remote-name'
command -v wget >$NUL && fetch='wget --no-clobber'
test -n "${fetch:-}" || die 1 "$NO_CURL_WGET_ERR"

sudo=$(command -v sudo || command -v doas) || die 1 "$NO_DOAS_SUDO_ERR"
grep -Eq "$OS_RELEASE_RE" /etc/os-release || die 1 "$DISTRO_ERR" "$DISTRO_TYPE"

packey="$sudo pacman-key"
pacinst="$sudo pacman --sync --needed"
pkgs='sonicde-meta'
slminst=

if pacman -Qi $pkgs >$NUL 2>&1 ; then
	msg 'Found an installation of SonicDE. Goood!'
	die 0 "$THANKS_MSG" "$HOMEPAGE"
fi


# Main

cd "$(mktemp -d)"

if ! $packey -l "$PGP_KEY_ID" >$NUL 2>&1 ; then
	msg 'Importing the package signing key:'
	$fetch "$PGP_KEY_URL"
	$packey --add "$PGP_KEY_FILE"
	$packey --finger "$PGP_KEY_ID"
	yesno "$FPRINT_MSG" "$REPO_HOMEPAGE" || die 1 "$WRONG_FPRINT_ERR"
	$packey --lsign-key "$PGP_KEY_ID"
fi

dbname=$(sed -En 's/^\[(sonicde.*)\]/\1/p' /etc/pacman.conf)
if [ -z "$dbname" ] ; then
	chooserepo "$CHOOSE_BINPKG_REPO_MSG" "$BINPKG_REPOS"
	dbname=$(printf "$REPO_NAME_TPL" "$(cat repo)")
	repourl=$(printf "$REPO_URL_TPL" "$(cat repo)")
	msg 'Adding the SonicDE repository to your ''/etc/pacman.conf'':'
	$sudo tee -a /etc/pacman.conf <<-EO_REPO

		[$dbname]
		Server = $repourl
	EO_REPO
fi

msg 'Analyzing your login manager setup'
lmname=$(findloginman)
if [ "$lmname" != soniclogin ] && yesno "$LM_SWITCH_MSG" ; then
	slminst=1
fi

yesno 'Are you ready to switch to SonicDE?' || exit 0


msg 'Refreshing package databases:'
$pacinst --refresh

msg 'Installing the dependencies of SonicDE:'
$pacinst --print --print-format '%r %n' $pkgs > deps
while read -r repo pkg; do
	test "$repo" = "$dbname" && continue
	extdeps="${extdeps:-} ${pkg}"
done < deps
test -n "${extdeps:-}" && $pacinst --asdeps --noconfirm $extdeps

msg 'Downloading the SonicDE packages:'
yes | $pacinst --downloadonly $pkgs

msg 'Assembling the installation script'
printf 'set -eu; yes | pacman --sync --needed %s\n' "$pkgs" > install.sh
svname=$lmname
pacman -Q xdm-archlinux >$NUL 2>&1 && svname=xdm-archlinux
if [ "$slminst" = 1 ] ; then
	cat >> install.sh <<-SLMINS
		test -n "$svname" && systemctl stop $svname
		yes | pacman --sync --needed sonic-login-manager 2>/dev/null
		systemctl enable --force soniclogin
		systemctl start soniclogin
	SLMINS
elif [ -n "$svname" ] ; then
	printf 'systemctl restart %s\n' "$svname" >> install.sh
fi
chmod a+x install.sh

msg "$INSTALL_MSG" 3 "$LOG"
msg "$THANKS_MSG" "$HOMEPAGE"

: > "$LOG"
$sudo systemd-run --on-active=3s --unit=sonic-switch-$$ \
	/bin/sh -c "'$(pwd)'/install.sh >> '$LOG' 2>&1"
tail -f "$LOG"
