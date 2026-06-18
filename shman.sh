#!/bin/sh
# shman - minimal POSIX dotfile manager
#
# Layout:        ~/.shman/store/     canonical files (git-friendly: only these)
#                ~/.shman/backups/   prior versions, saved before any overwrite
#                ~/.shman/db.txt     the index
# DB format:     field_type:track_type:mode:path
#   field_type   f = file, d = directory
#   track_type   l = symlink, c = copy
#   mode         octal permission bits to enforce (e.g. 600); may be empty
#   path         path relative to both the store and ~/
#   example:     f:l:600:.ssh/config   f:c:755:bin/deploy.sh   d:c:700:.gnupg
#
# mode comes before path so a path containing ':' still parses correctly.
#
# Nothing is ever quietly destroyed: before a tracked file is overwritten
# (the store copy on re-add, or the home copy on sync/repair) its current
# content is saved into backups/<path>.<store|home>.<timestamp>.
#
# Many filesystem states are recoverable. Subcommands that walk the DB
# (sync, repair) treat per-entry problems as non-fatal: they fix what they
# can, count the rest, and only report failure once at the end.

SHMAN_DIR="$HOME/.shman"
STORE="$SHMAN_DIR/store"
BACKUPS="$SHMAN_DIR/backups"
DB="$SHMAN_DIR/db.txt"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

err() { printf 'Error: %s\n' "$1" >&2; }
warn() { printf 'Warning: %s\n' "$1" >&2; }

# Resolve a symlink's target. readlink is not in POSIX but is present on every
# Linux/BusyBox system and is robust against odd filenames, unlike parsing ls.
link_target() {
	readlink -- "$1" 2>/dev/null
}

# Print a file's octal permission bits (e.g. 644, 600, 4755), empty on failure.
# GNU/BusyBox use -c, BSD uses -f; both are tried so the mode survives anywhere.
file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# Enforce recorded octal mode $1 on path $2.
#   return 0  nothing to do (no mode recorded, path absent, or already correct)
#   return 1  mode changed successfully
#   return 2  chmod failed
sync_mode() {
	[ -n "$1" ] && [ -e "$2" ] || return 0
	[ "$(file_mode "$2")" = "$1" ] && return 0
	chmod "$1" "$2" 2>/dev/null && return 1
	return 2
}

# Save the content currently at $1 into backups/<relpath>.<kind>.<timestamp>
# before the caller overwrites it. No-op if nothing is there. Returns nonzero
# only if a backup was attempted but failed, so callers can refuse to proceed.
#   $1 path to save   $2 relpath (db path)   $3 kind tag (store|home)
backup_path() {
	[ -e "$1" ] || [ -L "$1" ] || return 0
	_bdst="$BACKUPS/$2.$3.$(date +%Y%m%d%H%M%S)"
	mkdir -p "$(dirname "$_bdst")" || return 1
	cp -Rp -- "$1" "$_bdst" 2>/dev/null || return 1
	return 0
}

# Strip trailing slashes (keeping "/" itself) so basename/cp behave the same
# across coreutils and busybox regardless of how the user typed the path.
strip_slash() {
	case "$1" in
	/) printf '/' ;;
	*)
		_s=$1
		while [ "${_s%/}" != "$_s" ]; do _s=${_s%/}; done
		printf '%s' "$_s"
		;;
	esac
}

# Reject paths that are absolute or escape the store/home via "..".
valid_target() {
	case "$1" in
	'' | /* | ../* | */../* | */.. | ..)
		return 1
		;;
	esac
	return 0
}

# Split a DB line into the globals f_type, t_type, t_mode, t_path.
# Path is everything after the third colon, so colons in paths survive.
parse_line() {
	f_type=${1%%:*}
	_rest=${1#*:}
	t_type=${_rest%%:*}
	_rest=${_rest#*:}
	t_mode=${_rest%%:*}
	t_path=${_rest#*:}
}

# Remove every DB entry whose path equals $1. Written atomically via temp file.
db_remove() {
	[ -f "$DB" ] || return 0
	_tmp="$DB.tmp.$$"
	: >"$_tmp" || {
		err "cannot write to $_tmp"
		return 1
	}
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		parse_line "$line"
		[ "$t_path" = "$1" ] && continue
		printf '%s\n' "$line" >>"$_tmp"
	done <"$DB"
	mv "$_tmp" "$DB"
}

# Append field_type:track_type:mode:path, replacing any prior entry for the path.
db_set() {
	db_remove "$4" || return 1
	printf '%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >>"$DB"
}

# Refuse to clobber data we cannot recover. Safe when the home target is a
# symlink (removing it loses no data), is the source itself (its content is
# preserved into the store first), or is the unmodified copy we already deploy
# for this path. A real file that merely shares a tracked path name but has
# diverged from the store is NOT safe -- the user may have put real data there.
#   $1 home target   $2 source   $3 db path
safe_to_place() {
	[ -L "$1" ] && return 0
	[ -e "$1" ] || return 0
	[ "$1" -ef "$2" ] && return 0
	content_matches "$STORE/$3" "$1" && return 0
	return 1
}

# Confirm the store exists; create the parent dir for a store path.
ensure_store() {
	[ -d "$STORE" ] || {
		err "store $STORE missing; run 'shman init' first"
		return 1
	}
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------

cmd_init() {
	if ! mkdir -p "$STORE" "$BACKUPS"; then
		err "could not create $SHMAN_DIR"
		return 1
	fi
	if [ ! -f "$DB" ] && ! touch "$DB"; then
		err "could not create $DB"
		return 1
	fi
	rc=0
	[ -r "$STORE" ] && [ -w "$STORE" ] || {
		err "$STORE is not readable/writable"
		rc=1
	}
	[ -r "$DB" ] && [ -w "$DB" ] || {
		err "$DB is not readable/writable"
		rc=1
	}
	[ "$rc" -eq 0 ] && printf 'Initialized %s\n' "$SHMAN_DIR"
	return "$rc"
}

# ---------------------------------------------------------------------------
# link / copy share most of their argument handling
# ---------------------------------------------------------------------------

# Sets globals: source, target, recursive. Returns nonzero on bad args.
parse_add_args() {
	source=''
	target=''
	recursive=0
	for arg in "$@"; do
		case "$arg" in
		-r)
			recursive=1
			;;
		-*)
			err "unknown flag: $arg"
			return 1
			;;
		*)
			if [ -z "$source" ]; then
				source=$arg
			elif [ -z "$target" ]; then
				target=$arg
			else
				err "too many arguments"
				return 1
			fi
			;;
		esac
	done
	[ -n "$source" ] || {
		err "missing <source>"
		return 1
	}
	source=$(strip_slash "$source")
	[ -n "$target" ] || target=${source##*/}
	target=$(strip_slash "$target")
	if ! valid_target "$target"; then
		err "unsafe target path: $target"
		return 1
	fi
	return 0
}

cmd_link() {
	ensure_store || return 1
	parse_add_args "$@" || return 1

	if [ -L "$source" ]; then
		err "source is a symlink: $source. Point shman at the file or directory it references."
		return 1
	fi
	if [ ! -e "$source" ]; then
		err "source does not exist: $source"
		return 1
	fi

	dst="$STORE/$target"
	home_tgt="$HOME/$target"

	if [ -d "$source" ]; then
		f_type=d
		cp_cmd="cp -Rp"
	else
		f_type=f
		cp_cmd="cp -p"
	fi
	mode=$(file_mode "$source")

	if ! safe_to_place "$home_tgt" "$source" "$target"; then
		err "$home_tgt already exists and is not managed by shman; refusing to overwrite"
		return 1
	fi

	# Canonical copy must land in the store before we touch the original.
	if ! mkdir -p "$(dirname "$dst")"; then
		err "could not create store path for $target"
		return 1
	fi
	if [ ! "$source" -ef "$dst" ]; then
		if ! backup_path "$dst" "$target" store; then
			err "could not back up the existing store copy of $target"
			return 1
		fi
		rm -rf -- "$dst"
		if ! $cp_cmd -- "$source" "$dst"; then
			err "failed to copy $source into store"
			return 1
		fi
	fi

	# Replace whatever is at the home target with a fresh symlink.
	if [ -e "$home_tgt" ] || [ -L "$home_tgt" ]; then
		if ! rm -rf -- "$home_tgt"; then
			err "could not remove existing $home_tgt"
			return 1
		fi
	fi
	if ! ln -s "$dst" "$home_tgt"; then
		err "could not create symlink $home_tgt"
		return 1
	fi

	if ! db_set "$f_type" l "$mode" "$target"; then
		err "linked files but failed to update database"
		return 1
	fi
	printf 'Linked: %s -> %s\n' "$target" "$dst"
}

cmd_copy() {
	ensure_store || return 1
	parse_add_args "$@" || return 1

	if [ -L "$source" ]; then
		err "source is a symlink: $source. Point shman at the file or directory it references."
		return 1
	fi
	if [ ! -e "$source" ]; then
		err "source does not exist: $source"
		return 1
	fi

	dst="$STORE/$target"
	home_tgt="$HOME/$target"

	if [ -d "$source" ]; then
		if [ "$recursive" -ne 1 ]; then
			err "source is a directory. Use -r for recursive copy."
			return 1
		fi
		if [ -z "$(ls -A -- "$source" 2>/dev/null)" ]; then
			err "refusing to track empty directory: $source"
			return 1
		fi
		f_type=d
		cp_cmd="cp -Rp"
	else
		f_type=f
		cp_cmd="cp -p"
	fi
	mode=$(file_mode "$source")

	if ! safe_to_place "$home_tgt" "$source" "$target"; then
		err "$home_tgt already exists and is not managed by shman; refusing to overwrite"
		return 1
	fi

	if ! mkdir -p "$(dirname "$dst")"; then
		err "could not create store path for $target"
		return 1
	fi
	if [ ! "$source" -ef "$dst" ]; then
		if ! backup_path "$dst" "$target" store; then
			err "could not back up the existing store copy of $target"
			return 1
		fi
		rm -rf -- "$dst"
		if ! $cp_cmd -- "$source" "$dst"; then
			err "failed to copy $source into store"
			return 1
		fi
	fi

	# Deploy the store copy to the home target so a plain copy lives there now,
	# matching link's immediacy rather than waiting for the next sync.
	if [ ! "$source" -ef "$home_tgt" ] && ! deploy_copy "$dst" "$home_tgt" "$target"; then
		err "copied to store but failed to place copy at $home_tgt"
		return 1
	fi

	if ! db_set "$f_type" c "$mode" "$target"; then
		err "copied files but failed to update database"
		return 1
	fi
	printf 'Copied: %s -> %s\n' "$target" "$dst"
}

# ---------------------------------------------------------------------------
# Content comparison for copy-tracked entries
# ---------------------------------------------------------------------------

# Returns 0 when target content matches the store source.
content_matches() {
	_src=$1
	_tgt=$2
	[ -e "$_tgt" ] || return 1
	if [ -d "$_src" ]; then
		diff -r -- "$_src" "$_tgt" >/dev/null 2>&1
	else
		cmp -s -- "$_src" "$_tgt"
	fi
}

# Copy store source onto target, replacing whatever is there. The target's
# current content is backed up first (kind "home") so a local edit that is
# about to be overwritten can always be recovered.
#   $1 store source   $2 home target   $3 db path (for backup naming)
deploy_copy() {
	_src=$1
	_tgt=$2
	backup_path "$_tgt" "$3" home || return 1
	mkdir -p "$(dirname "$_tgt")" || return 1
	rm -rf -- "$_tgt" || return 1
	if [ -d "$_src" ]; then
		cp -Rp -- "$_src" "$_tgt"
	else
		cp -p -- "$_src" "$_tgt"
	fi
}

# ---------------------------------------------------------------------------
# sync
# ---------------------------------------------------------------------------

cmd_sync() {
	ensure_store || return 1
	[ -f "$DB" ] || {
		err "no database at $DB"
		return 1
	}

	updated=0
	errors=0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		parse_line "$line"
		if ! valid_target "$t_path"; then
			err "skipping unsafe path in db: $t_path"
			errors=$((errors + 1))
			continue
		fi
		src="$STORE/$t_path"
		tgt="$HOME/$t_path"

		if [ ! -e "$src" ]; then
			err "corruption: source missing at $src. Cannot repair."
			errors=$((errors + 1))
			continue
		fi

		# Enforce the recorded mode on the store file first, so a source whose
		# own permissions were stripped (e.g. 000) becomes readable before we
		# compare or copy it.
		sync_mode "$t_mode" "$src"
		case $? in
		1) updated=$((updated + 1)) ;;
		2)
			err "could not set mode $t_mode on $src"
			errors=$((errors + 1))
			;;
		esac

		case "$t_type" in
		l)
			if [ -L "$tgt" ]; then
				if [ "$(link_target "$tgt")" != "$src" ]; then
					# Wrong symlink: removing a symlink never touches its target.
					rm -f -- "$tgt"
					if ln -s "$src" "$tgt"; then
						updated=$((updated + 1))
					else
						err "could not link $tgt"
						errors=$((errors + 1))
						continue
					fi
				fi
			elif [ -e "$tgt" ]; then
				# A real file/dir lives here; never delete unmanaged data in sync.
				err "$tgt is not a symlink; run 'shman repair' to resolve"
				errors=$((errors + 1))
				continue
			elif ln -s "$src" "$tgt"; then
				updated=$((updated + 1))
			else
				err "could not link $tgt"
				errors=$((errors + 1))
				continue
			fi
			;;
		c)
			if ! content_matches "$src" "$tgt"; then
				if deploy_copy "$src" "$tgt" "$t_path"; then
					updated=$((updated + 1))
				else
					err "could not copy to $tgt"
					errors=$((errors + 1))
					continue
				fi
			fi
			;;
		*)
			err "unknown track type '$t_type' for $t_path"
			errors=$((errors + 1))
			continue
			;;
		esac

		# A copy's deployed home file must match too (the store file was already
		# brought to the recorded mode above).
		if [ "$t_type" = c ]; then
			sync_mode "$t_mode" "$tgt"
			case $? in
			1) updated=$((updated + 1)) ;;
			2)
				err "could not set mode $t_mode on $tgt"
				errors=$((errors + 1))
				;;
			esac
		fi
	done <"$DB"

	printf 'Sync complete. %s files updated.\n' "$updated"
	[ "$errors" -gt 0 ] && {
		printf '%s entries could not be synced.\n' "$errors" >&2
		return 1
	}
	return 0
}

# ---------------------------------------------------------------------------
# repair
# ---------------------------------------------------------------------------

cmd_repair() {
	ensure_store || return 1
	[ -f "$DB" ] || {
		err "no database at $DB"
		return 1
	}

	restored=0
	errors=0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -z "$line" ] && continue
		parse_line "$line"
		if ! valid_target "$t_path"; then
			err "skipping unsafe path in db: $t_path"
			errors=$((errors + 1))
			continue
		fi
		src="$STORE/$t_path"
		tgt="$HOME/$t_path"

		if [ ! -e "$src" ]; then
			err "corruption: source missing at $src. Manual intervention required."
			errors=$((errors + 1))
			continue
		fi

		# Enforce the recorded mode on the store file first, so a source whose
		# own permissions were stripped (e.g. 000) becomes readable before we
		# compare or copy it.
		sync_mode "$t_mode" "$src"
		case $? in
		1) restored=$((restored + 1)) ;;
		2)
			err "could not set mode $t_mode on $src"
			errors=$((errors + 1))
			;;
		esac

		case "$t_type" in
		l)
			if [ -L "$tgt" ]; then
				if [ "$(link_target "$tgt")" != "$src" ] || [ ! -e "$tgt" ]; then
					rm -f -- "$tgt"
					if ln -s "$src" "$tgt"; then
						restored=$((restored + 1))
					else
						err "could not relink $tgt"
						errors=$((errors + 1))
						continue
					fi
				fi
			elif [ ! -e "$tgt" ]; then
				if ln -s "$src" "$tgt"; then
					restored=$((restored + 1))
				else
					err "could not link $tgt"
					errors=$((errors + 1))
					continue
				fi
			else
				# stdin is the DB file (the while loop reads it), so the prompt
				# must read from the terminal directly. If there is no terminal,
				# the read fails and we default to leaving the file untouched.
				printf 'File %s exists but is not a managed link. Overwrite? [y/N] ' "$t_path"
				read -r ans 2>/dev/null </dev/tty || ans=n
				case "$ans" in
				y | Y | yes | YES)
					rm -rf -- "$tgt"
					if ln -s "$src" "$tgt"; then
						restored=$((restored + 1))
					else
						err "could not link $tgt"
						errors=$((errors + 1))
						continue
					fi
					;;
				*)
					warn "left $t_path untouched"
					continue
					;;
				esac
			fi
			;;
		c)
			if ! content_matches "$src" "$tgt"; then
				if deploy_copy "$src" "$tgt" "$t_path"; then
					restored=$((restored + 1))
				else
					err "could not restore copy at $tgt"
					errors=$((errors + 1))
					continue
				fi
			fi
			;;
		*)
			err "unknown track type '$t_type' for $t_path"
			errors=$((errors + 1))
			continue
			;;
		esac

		# A copy's deployed home file must match too (the store file was already
		# brought to the recorded mode above).
		if [ "$t_type" = c ]; then
			sync_mode "$t_mode" "$tgt"
			case $? in
			1) restored=$((restored + 1)) ;;
			2)
				err "could not set mode $t_mode on $tgt"
				errors=$((errors + 1))
				;;
			esac
		fi
	done <"$DB"

	printf 'Repair complete. %s links restored. %s errors found.\n' "$restored" "$errors"
	[ "$errors" -gt 0 ] && return 1
	return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

usage() {
	cat <<EOF
Usage: shman <command> [args]

  init                       create ~/.shman and db.txt
  link <source> [target]     move into store, replace original with symlink
  copy <source> [target] [-r]  copy into store, keep a plain copy at home
  sync                       make ~/ match db.txt (relink / recopy)
  repair                     verify store vs db.txt and restore links
EOF
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift

case "$cmd" in
init) cmd_init "$@" ;;
link) cmd_link "$@" ;;
copy) cmd_copy "$@" ;;
sync) cmd_sync "$@" ;;
repair) cmd_repair "$@" ;;
help)
	usage
	;;
'')
	usage >&2
	exit 1
	;;
*)
	err "unknown command: $cmd"
	usage >&2
	exit 1
	;;
esac
