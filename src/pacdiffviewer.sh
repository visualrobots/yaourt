#!/bin/bash
#set -x
#   pacdiffviewer : manage/backup/clean/merge pac* files
#
#   Copyright (c) 2010 tuxce <tuxce.net@gmail.com>
#   Copyright (c) 2008-2010 Julien MISCHKOWITZ <wain@archlinux.fr>
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
export TEXTDOMAINDIR=/usr/share/locale
export TEXTDOMAIN=yaourt
type gettext.sh > /dev/null 2>&1 && { . gettext.sh; } || {
	eval_gettext () { echo "$1"; }
	gettext () { echo "$1"; }
}

myname=pacdiffviewer
myversion=0.4

ROOTDIR=
SAVEDIR=$ROOTDIR/var/lib/yaourt/backupfiles
LOCATE=0
SEARCH_REP=(/etc/ /boot/)
DIFFEDITCMD="vimdiff"
QUIET=0
[[ -d "$SAVEDIR" ]] && MERGE=1 || MERGE=0
tmp_file=$(mktemp)
trap 'rm "$tmp_file"' 0

usage()
{
	echo "$myname $myversion"
	[[ "$1" = "-v" ]] && exit 0
	echo -e "\t-c $(gettext 'Delete all *.pac* found')"
	echo -e "\t-b $(gettext 'Save all packages backup files for a later merge')"
	echo -e "\t-q $(gettext 'Use with backup to not output messages')"
	echo -e "\t-s $(gettext 'Select files instead of listing them sequentially')"
	echo -e "\t-h $(gettext 'This help')"
	echo -e "\t-v $(gettext 'Show version')"
	exit 0
}

# Save files marked as backup in packages for a possible later merge
backup_files()
{
	package-query -Qf "%n - %v"$'\n'"%b" --csep $'\n' | while read _file _md5sum _version
	do
		# no backups
		[[ "$_file" = "-" ]] && pkgname="" && continue
		# _md5sum = "-" -> on name/version line
		[[ "$_md5sum" = "-" ]] && pkgname="$_file" && pkgver="$_version" && continue
		[[ ! -f "$ROOTDIR/$_file" ]] && continue
		backupdir="$SAVEDIR/$pkgname/$pkgname-$pkgver"
		[[ -f "$backupdir/$_file" ]] && continue
		currentfile="$_file.pacnew"
		[[ -f "$ROOTDIR/$currentfile" ]] || currentfile="$_file"
		if echo "$_md5sum  $ROOTDIR/$currentfile" | md5sum --status -c - &>/dev/null; then
			(( ! QUIET )) && echo "  -> $(gettext 'saving') $ROOTDIR/$currentfile"
			mkdir -p "$(dirname "$backupdir/$_file")" || return 1
			cp -a "$ROOTDIR/$currentfile" "$backupdir/$_file" || return 1
		fi
	done
}

# Create pacnew/pacsave/pacorig db
# PACOLD=()	-> all pacnew/pacsave files which package is not installed
# PACNEW=()	-> rest of pacnew files
# PACSAVE=() -> rest of pacsave files
# PACORIG=() -> pacorig files
create_db()
{
	unset PACOLD PACNEW PACSAVE
	local pacfiles
	IFS=$'\n'
	if (( LOCATE )); then
		pacfiles=($(locate -eb "*.pacorig" "*.pacsave" "*.pacnew"))
	else
		pacfiles=($(find "${SEARCH_REP[@]}" \( -name "*.pacorig" -o -name "*.pacsave" -o -name "*.pacnew" \)))
	fi
	unset IFS
	for _file in "${pacfiles[@]}"; do
		for ext in .pacnew .pacsave .pacorig; do
			[[ ${_file%$ext} != $_file ]] && break
		done
		[[ ! -f "${_file%$ext}" ]] && PACOLD+=("${_file}") &&	continue
		[[ "$ext" = ".pacnew" ]] && PACNEW+=("${_file}")
		[[ "$ext" = ".pacsave" ]] && PACSAVE+=("${_file}")
		[[ "$ext" = ".pacorig" ]] && PACORIG+=("${_file}")
	done
	echo "${#PACORIG[@]} .pacorig $(gettext 'found')"
	echo "${#PACNEW[@]} .pacnew $(gettext 'found')"
	echo "${#PACSAVE[@]} .pacsave $(gettext 'found')"
	echo "${#PACOLD[@]} $(gettext 'files are orphans')"
	echo
}

# Return previous version file if we had backup it
# usage: previous_version ($file)
# return previous file or ""
previous_version ()
{
	[[ $1 ]] || return 
	local file=$1
	read pkgname pkgver < <(LC_ALL=C pacman -Qo "$file" | awk '{print $(NF-1)" "$NF}' 2>/dev/null)
	[[ $pkgname ]] || return 
	[[ -d "$SAVEDIR/$pkgname/" ]] || return 
	pushd "$SAVEDIR/$pkgname/" &> /dev/null
	local pkgver_prev=""
	for _rep in $(ls -Ad *-*); do
		[[ "$_rep" = "$pkgname-$pkgver" || ! -f "${_rep}${file}" ||
			$(vercmp $pkgver ${_rep#*-}) -lt 0 ]] && continue
		if [[ -z "$pkgver_prev" || $(vercmp $pkgver_prev ${_rep#*-}) -lt 0 ]]; then
			pkgver_prev="${_rep#*-}"
		fi
	done
	popd &> /dev/null
	[[ ! "$pkgver_prev" ]] && return 
	echo "$SAVEDIR/$pkgname/$pkgname-$pkgver_prev/$file"
}

# Search if we can merge a .pac{save,new} with a current file
# usage: is_mergeable ($file)
# return: 0 on success
is_mergeable()
{
	(( ! MERGE )) && return 1
	[[ $1 ]] || return 1
	local file=$1
	local ext=${2:-.pacnew}
	local file_prev=$(previous_version "$file")
	[[ $file_prev ]] || return 1
	diff -aBbu "$file_prev" "${file}${ext}" > $tmp_file
	(( $? != 1 )) && return 1
	patch --dry-run -sp0 "$file" -i "$tmp_file" &> /dev/null || return 1
	return 0
}


# Remove .pac* files
supress()
{
	local pacfiles=(${PACOLD[@]})
	[[ "$1" = "all" ]] && pacfiles+=("${PACNEW[@]}" "${PACSAVE[@]}" "${PACORIG[@]}")
	(( ! ${#pacfiles[@]} )) && return
	echo "${pacfiles[@]}" | fold -s -w $(tput cols)
	echo
	prompt "$(gettext 'Do you want to delete these files ?')" $(yes_no 2) "$(gettext '(A for All)')"
	local answer=$(userinput "YNA" "N")
	[[ "$answer" = "N" ]] && return
	local _opt=""
	[[ "$answer" = "Y" ]] && _opt="-i"
	rm $_opt "${pacfiles[@]}"
}

# Manage .pac* file
# Called by manage()
manage_file ()
{
	local ext=$1; shift
	local _time=${1%%  *}
	local _file="${1#*  }"
	while true; do
		local _msg="$ext: ${_file%$ext}"
		local _prompt="Action: [E]dit, [R]eplace, [S]uppress,"
		local _prompt_action="ERSCA"
		diff -abBu "${_file%$ext}" "$_file" &> /dev/null && _msg+=" **same file**"
		if is_mergeable "${_file%$ext}" "$ext"; then
			_prompt+=" [M]erge,"
			_prompt_action+="M"
			_msg+=" **automerge**"
		fi
		msg $_msg
		# gettext "Action: [E]dit, [R]eplace, [S]uppress, [C]ontinue (default), [A]bort ?"
		# gettext "Action: [E]dit, [R]eplace, [S]uppress, [M]erge, [C]ontinue (default), [A]bort ?"
		# gettext "ERSCA"
		# gettext "ERSMCA"
		prompt "$(gettext "$_prompt [C]ontinue (default), [A]bort ?")"
		local answer=$(userinput "$_prompt_action" "C")
		case "$answer" in
			A) break 2;;	# break manage() loop
			C) break;;
			E) $DIFFEDITCMD "${_file%$ext}" "$_file" ;;
			R) mv "$_file" "${_file%$ext}"; break;;
			S) rm "$_file"; break ;;
			M)	patch -sp0 "${_file%$ext}" -i "$tmp_file"
				(( $? )) && error "$(gettext 'patch returned an error!')"
				break;;
		esac
	done
}	

# Manage list of .pac* files
manage()
{
	echo
	local ext=$1; shift
	[[ $@ ]] || return
	readarray -t pacfiles < <(stat -c "%Y %n" "$@" |
		sort |
		awk '{printf ("%s %s\n", strftime("%x %X",$1), substr ($0, length($1)+1))}')
	if (( SELECT )); then
		select _line in "${pacfiles[@]}"; do
			[[ $_line ]] || break
			manage_file "$ext" "$_line"
		done
	else
		local i=0
		for _line in "${pacfiles[@]}"; do
			(( i++ ))
			msg "$i/${#pacfiles[@]}:"
			manage_file "$ext" "$_line"
		done
	fi
}

. /usr/lib/yaourt/basicfunctions.sh
initcolor
action=""
while [[ $1 ]]; do
	case "$1" in 
		-q) QUIET=1;;
		-s) SELECT=1;;
		--backup|-b) action=backup;;
		-c)	action=clean;; 
		-*) usage $1;;
	esac
	shift
done

case "$action" in
	backup)	backup_files;;
	clean)	create_db; supress all;;
	*)	create_db
		manage .pacsave "${PACSAVE[@]}"
		manage .pacnew "${PACNEW[@]}"
		manage .pacorig "${PACORIG[@]}"
		msg "$(gettext 'The following files have no original version.')"
		supress
		;;
esac
