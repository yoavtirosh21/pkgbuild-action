#!/bin/bash
set -euo pipefail

FILE="$(basename "$0")"

pacman -Syu --noconfirm base-devel

# Makepkg does not allow running as root
# Create a new user `builder`
# `builder` needs to have a home directory because some PKGBUILDs will try to
# write to it (e.g. for cache)
useradd builder -m
# When installing dependencies, makepkg will use sudo
# Give user `builder` passwordless sudo access
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Give all users (particularly builder) full access to these files
chmod -R a+rw .

# Assume that if .SRCINFO is missing then it is generated elsewhere.
# AUR checks that .SRCINFO exists so a missing file can't go unnoticed.
if [ -f .SRCINFO ] && ! sudo -u builder makepkg --printsrcinfo | diff - .SRCINFO; then
	echo "::error file=$FILE,line=$LINENO::Mismatched .SRCINFO. Update with: makepkg --printsrcinfo > .SRCINFO"
	exit 1
fi

# Get array of packages to be built
mapfile -t PKGFILES < <( sudo -u builder makepkg --packagelist )
echo "Package(s): ${PKGFILES[*]}"

# Optionally install dependencies from AUR
if [ -n "${INPUT_AURDEPS:-}" ]; then
	# First install yay
	pacman -S --noconfirm git
	git clone https://aur.archlinux.org/yay.git /tmp/yay
	pushd /tmp/yay
	chmod -R a+rw .
	sudo -H -u builder makepkg --syncdeps --install --noconfirm
	popd

	# Extract dependencies from .SRCINFO (depends or depends_x86_64) and install
	mapfile -t PKGDEPS < \
		<(sed -n -e 's/^[[:space:]]*depends\(_x86_64\)\? = \([[:alnum:][:punct:]]*\)[[:space:]]*$/\2/p' .SRCINFO)
	yay --sync --noconfirm "${PKGDEPS[@]}"
fi

# Build packages
# INPUT_MAKEPKGARGS is intentionally unquoted to allow arg splitting
# shellcheck disable=SC2086
sudo -H -u builder makepkg --syncdeps --noconfirm ${INPUT_MAKEPKGARGS:-}

# Report built package archives
i=0
for PKGFILE in "${PKGFILES[@]}"; do
	# makepkg reports absolute paths, must be relative for use by other actions
	RELPKGFILE="$(realpath --relative-base="$PWD" "$PKGFILE")"
	# Caller arguments to makepkg may mean the pacakge is not built
	if [ -f "$PKGFILE" ]; then
		echo "::set-output name=pkgfile$i::$RELPKGFILE"
	else
		echo "Archive $RELPKGFILE not built"
	fi
	(( ++i ))
done

function prepend () {
	# Prepend the argument to each input line
	while read -r line; do
		echo "$1$line"
	done
}

function namcap_check() {
	# Run namcap checks
	# Installing namcap after building so that makepkg happens on a minimal
	# install where any missing dependencies can be caught.
	pacman -S --noconfirm namcap

	NAMCAP_ARGS=()
	if [ -n "${INPUT_NAMCAPRULES:-}" ]; then
		NAMCAP_ARGS+=( "-r" "${INPUT_NAMCAPRULES}" )
	fi
	if [ -n "${INPUT_NAMCAPEXCLUDERULES:-}" ]; then
		NAMCAP_ARGS+=( "-e" "${INPUT_NAMCAPEXCLUDERULES}" )
	fi

	namcap "${NAMCAP_ARGS[@]}" PKGBUILD \
		| prepend "::warning file=$FILE,line=$LINENO::"
	for PKGFILE in "${PKGFILES[@]}"; do
		if [ -f "$PKGFILE" ]; then
			RELPKGFILE="$(realpath --relative-base="$PWD" "$PKGFILE")"
			namcap "${NAMCAP_ARGS[@]}" "$PKGFILE" \
				| prepend "::warning file=$FILE,line=$LINENO::$RELPKGFILE:"
		fi
	done
}

if [ -z "${INPUT_NAMCAPDISABLE:-}" ]; then
	namcap_check
fi