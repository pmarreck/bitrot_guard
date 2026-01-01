#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET_BIN=${1:-"$PROJECT_ROOT/bitrot_guard"}
TARGET_BIN="$(cd "$(dirname "$TARGET_BIN")" && pwd)/$(basename "$TARGET_BIN")"

TESTS=()
TEMP_DIRS=()
EXPECTED_ABOUT="Bitrot Guard creates and uses par2 redundancy to detect and repair bitrot in your files and directories."
QUIET_MODE=0
unset BRG_PAR2_STORE BRG_PAR2_DB_PATH

falsey() {
	local arg="${1:-}"
	case "$arg" in
		--help)
			cat <<EOF
Usage: truthy VARIABLE|value
Returns 0 (true) if the input is truthy, 1 otherwise.

Usage: falsey VARIABLE|value
Returns 0 if the input is falsey (unset, empty, or one of 0/false/off/n/no/disable/disabled).
EOF
			return 0
			;;
		--test)
			return 0
			;;
		"" )
			return 0
			;;
	esac

	local value=""
	if [[ "$arg" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		if [[ ${!arg+x} ]]; then
			value="${!arg}"
		else
			return 0
		fi
	else
		value="$arg"
	fi

	local lower
	lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
	case "$lower" in
		""|0|f|false|off|n|no|disable|disabled)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

truthy() {
	local arg="${1:-}"
	case "$arg" in
		--help|--test)
			falsey "$arg"
			return 0
			;;
	esac
	falsey "$arg"
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		return 1
	elif [[ $rc -eq 1 ]]; then
		return 0
	else
		return $rc
	fi
}

if truthy QUIET; then
	QUIET_MODE=1
fi

cleanup() {
	for dir in "${TEMP_DIRS[@]}"; do
		[[ -d "$dir" ]] && rm -rf "$dir"
	done
}
trap cleanup EXIT

log() {
	if truthy DEBUG; then
		echo "TEST DEBUG: $*" >&2
	fi
}

fail() {
	echo "TEST ERROR: $*" >&2
	return 1
}

run_quiet() {
	"$TARGET_BIN" "$@" >/dev/null 2>&1
}

register_test() {
	TESTS+=("$1")
}

make_temp_dir() {
	local dir
	dir=$(mktemp -d)
	TEMP_DIRS+=("$dir")
	printf '%s\n' "$dir"
}

abs_path() {
	local target="$1" dir base
	dir=$(cd "$(dirname "$target")" >/dev/null 2>&1 && pwd -P)
	base=$(basename "$target")
	printf '%s/%s\n' "$dir" "$base"
}

sanitize_filename() {
	local name="$1"
	printf '%s' "$name" | sed 's/[^A-Za-z0-9._-]/_/g'
}

get_par2_path() {
	local orig_path="$1"
	local base_dir=$(dirname "$orig_path")
	local base_name=$(basename "$orig_path")
	local sanitized_name=$(sanitize_filename "$base_name")
	printf '%s/.%s.par2\n' "$base_dir" "$sanitized_name"
}

expect_par2_absent() {
	local dir="$1"
	if find "$dir" -name ".*.par2" -print -quit | grep -q .; then
		fail "Unexpected par2 files in $dir"
		return 1
	fi
}

test_directory_lifecycle() {
	log "test_directory_lifecycle"
	local dir file1 file2 stats
	dir=$(make_temp_dir)
	file1="$dir/file1.txt"
	file2="$dir/file2.txt"
	echo "alpha" > "$file1"
	echo "beta" > "$file2"

	run_quiet create "$dir"
	run_quiet verify "$dir"
	echo "gamma" >> "$file1"
	run_quiet update "$dir"
	run_quiet repair "$dir"
	stats=$("$TARGET_BIN" stats "$dir")
	if [[ "$stats" != *"Coverage:"* ]]; then
		fail "Stats missing coverage line"
		return 1
	fi
	run_quiet clear "$dir"
	expect_par2_absent "$dir"
}
register_test test_directory_lifecycle

test_single_file_repair() {
	log "test_single_file_repair"
	local dir file
	dir=$(make_temp_dir)
	file="$dir/single.txt"
	echo "This is a test file for single file operations" > "$file"
	run_quiet create "$file"
	printf 'X' | dd of="$file" bs=1 seek=5 conv=notrunc 2>/dev/null
	run_quiet repair "$file"
	run_quiet verify "$file"
	if ! grep -q "This is a test file for single file operations" "$file"; then
		fail "Repair did not restore file content"
		return 1
	fi
}
register_test test_single_file_repair

test_cli_aliases() {
	log "test_cli_aliases"
	local dir file
	dir=$(make_temp_dir)
	file="$dir/sample.txt"
	echo "sample" > "$file"
	"$TARGET_BIN" --create "$file" >/dev/null 2>&1
	if [[ ! -f "$dir/.sample.txt.par2" ]]; then
		fail "Alias --create did not create par2"
		return 1
	fi
	"$TARGET_BIN" --verify "$file" >/dev/null 2>&1
	"$TARGET_BIN" --clear "$file" >/dev/null 2>&1
	expect_par2_absent "$dir"
}
register_test test_cli_aliases

test_protect_dotfiles() {
	log "test_protect_dotfiles"
	local dir hidden
	dir=$(make_temp_dir)
	hidden="$dir/.hidden.txt"
	echo "secret" > "$hidden"
	PROTECT_DOTFILES=0 run_quiet create "$dir"
	if find "$dir" -name ".hidden.txt*.par2" -print -quit | grep -q .; then
		fail "Dotfile was protected despite PROTECT_DOTFILES=0"
		return 1
	fi
	PROTECT_DOTFILES=1 run_quiet update "$dir"
	if ! find "$dir" -name "*.par2" -print -quit | grep -q .; then
		fail "Dotfile not protected when PROTECT_DOTFILES=1"
		return 1
	fi
}
register_test test_protect_dotfiles

test_sqlite_store_create_does_not_write_par2_files() {
	log "test_sqlite_store_create_does_not_write_par2_files"
	local dir file db stored_count
	dir=$(make_temp_dir)
	file="$dir/sqlite_store.txt"
	db="$dir/brg_par2.sqlite3"

	echo "hello sqlite store" > "$file"

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file"

	expect_par2_absent "$dir"
	if [[ ! -f "$db" ]]; then
		fail "Expected sqlite db to exist at $db"
		return 1
	fi

	if ! command -v sqlite3 >/dev/null 2>&1; then
		fail "sqlite3 is required for sqlite store tests"
		return 1
	fi

	stored_count=$(sqlite3 "$db" "select count(*) from brg_par2_files;")
	if [[ "$stored_count" -lt 1 ]]; then
		fail "Expected at least one stored par2 row, got $stored_count"
		return 1
	fi
}
register_test test_sqlite_store_create_does_not_write_par2_files

test_sqlite_store_excludes_db_file_from_protection() {
	log "test_sqlite_store_excludes_db_file_from_protection"
	local dir file db db_abs db_sql protected_count
	dir=$(make_temp_dir)
	file="$dir/keep.txt"
	db="$dir/brg_par2.sqlite3"
	db_abs=$(abs_path "$db")
	db_sql=$(printf '%s' "$db_abs" | sed "s/'/''/g")

	echo "protect me" > "$file"
	: > "$db"

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$dir"

	protected_count=$(sqlite3 "$db" "select count(*) from brg_par2_files where source_path = '$db_sql';")
	if [[ "$protected_count" -ne 0 ]]; then
		fail "Expected db file to be excluded from protection, but found $protected_count rows"
		return 1
	fi
}
register_test test_sqlite_store_excludes_db_file_from_protection

test_sqlite_store_excludes_db_file_when_db_path_is_relative() {
	log "test_sqlite_store_excludes_db_file_when_db_path_is_relative"
	local dir file db db_abs db_sql protected_count db_marker
	dir=$(make_temp_dir)
	file="$dir/keep.txt"
	db="$dir/brg_par2.sqlite3"
	db_abs=$(abs_path "$db")
	db_sql=$(printf '%s' "$db_abs" | sed "s/'/''/g")
	db_marker="$dir/.brg_par2.sqlite3.brg_empty"

	echo "protect me" > "$file"
	: > "$db"

	(
		cd "$dir"
		BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="brg_par2.sqlite3" "$TARGET_BIN" create "$dir" >/dev/null 2>&1
	)

	protected_count=$(sqlite3 "$db" "select count(*) from brg_par2_files where source_path = '$db_sql';")
	if [[ "$protected_count" -ne 0 ]]; then
		fail "Expected relative-path db file to be excluded from protection, but found $protected_count rows"
		return 1
	fi
	if [[ -f "$db_marker" ]]; then
		fail "Expected db file not to get a .brg_empty marker at $db_marker"
		return 1
	fi
}
register_test test_sqlite_store_excludes_db_file_when_db_path_is_relative

test_sqlite_store_repair_restores_file() {
	log "test_sqlite_store_repair_restores_file"
	local dir file db original
	dir=$(make_temp_dir)
	file="$dir/sqlite_repair.txt"
	db="$dir/brg_par2.sqlite3"
	original="This is a sqlite-store repair test"

	echo "$original" > "$file"

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file"
	printf 'X' | dd of="$file" bs=1 seek=5 conv=notrunc 2>/dev/null
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet repair "$file"
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet verify "$file"

	if ! grep -q "$original" "$file"; then
		fail "sqlite-store repair did not restore file content"
		return 1
	fi
}
register_test test_sqlite_store_repair_restores_file

test_cli_par2_store_sqlite_flags() {
	log "test_cli_par2_store_sqlite_flags"
	local dir file db stored_count
	dir=$(make_temp_dir)
	file="$dir/cli_sqlite_flags.txt"
	db="$dir/brg_par2.sqlite3"

	echo "cli flags sqlite store" > "$file"

	"$TARGET_BIN" --par2-store sqlite --par2-db "$db" create "$file" >/dev/null 2>&1

	expect_par2_absent "$dir"
	if [[ ! -f "$db" ]]; then
		fail "Expected sqlite db to exist at $db"
		return 1
	fi

	stored_count=$(sqlite3 "$db" "select count(*) from brg_par2_files;")
	if [[ "$stored_count" -lt 1 ]]; then
		fail "Expected at least one stored par2 row, got $stored_count"
		return 1
	fi
}
register_test test_cli_par2_store_sqlite_flags

test_cli_par2_bin_option_uses_custom_binary() {
	log "test_cli_par2_bin_option_uses_custom_binary"
	local real_par2
	real_par2=$(command -v par2 || true)
	[[ -n "${real_par2:-}" ]] || { log "Skipping par2 bin option test (par2 missing)"; return 0; }

	local dir file marker shim out
	dir=$(make_temp_dir)
	file="$dir/custom_par2.txt"
	echo "par2z test" > "$file"
	marker="$dir/par2_called"
	shim="$dir/par2_shim"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'set -euo pipefail'
		printf '%s\n' ": >\"$marker\""
		printf '%s\n' "exec \"$real_par2\" \"\$@\""
	} >"$shim"
	chmod +x "$shim"

	out=$("$TARGET_BIN" --par2-bin "$shim" create "$file" 2>&1)
	if [[ ! -f "$marker" ]]; then
		fail "Expected --par2-bin to invoke custom par2 binary. Output: $out"
		return 1
	fi
}
register_test test_cli_par2_bin_option_uses_custom_binary

test_create_stops_on_disk_full() {
	log "test_create_stops_on_disk_full"
	local dir file1 file2 shim marker out rc calls
	dir=$(make_temp_dir)
	file1="$dir/one.txt"
	file2="$dir/two.txt"
	echo "one" > "$file1"
	echo "two" > "$file2"
	marker="$dir/par2_calls"
	shim="$dir/par2_shim"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'set -euo pipefail'
		printf '%s\n' "echo called >>\"$marker\""
		printf '%s\n' 'echo "No space left on device" >&2'
		printf '%s\n' 'exit 1'
	} >"$shim"
	chmod +x "$shim"

	set +e
	out=$(BRG_PAR2_BIN="$shim" "$TARGET_BIN" create "$dir" 2>&1)
	rc=$?
	set -e
	if [[ $rc -eq 0 ]]; then
		fail "Expected create to fail on disk full"
		return 1
	fi
	if [[ "$out" != *"Disk full"* && "$out" != *"disk full"* ]]; then
		fail "Expected disk full error message, got: $out"
		return 1
	fi
	calls=0
	if [[ -f "$marker" ]]; then
		calls=$(wc -l <"$marker" | $AWK '{print $1}')
	fi
	if [[ "$calls" -ne 1 ]]; then
		fail "Expected par2 to be invoked once after disk full, got $calls"
		return 1
	fi
}
register_test test_create_stops_on_disk_full

test_create_insufficient_space_fails_noninteractive() {
	log "test_create_insufficient_space_fails_noninteractive"
	local dir file stub_dir stub_df out rc
	dir=$(make_temp_dir)
	file="$dir/space_check.txt"
	head -c 2048 </dev/zero > "$file"

	stub_dir=$(mktemp -d --tmpdir brg_df_stub.XXXXXX)
	TEMP_DIRS+=("$stub_dir")
	stub_df="$stub_dir/df"
	cat >"$stub_df" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "Filesystem 1024-blocks Used Available Capacity Mounted on"
printf '%s\n' "/dev/disk1s1 1024 1024 0 100% /"
EOF
	chmod +x "$stub_df"

	set +e
	out=$(PATH="$stub_dir:$PATH" BRG_REDUNDANCY=10 "$TARGET_BIN" create "$file" </dev/null 2>&1)
	rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		fail "Expected create to fail when space is insufficient in non-interactive mode"
		return 1
	fi
	if [[ "$out" != *"insufficient"* && "$out" != *"Insufficient"* ]]; then
		fail "Expected insufficient space error, got: $out"
		return 1
	fi
	if [[ "$out" != *"TTY"* && "$out" != *"tty"* ]]; then
		fail "Expected non-interactive/TTY error, got: $out"
		return 1
	fi
	expect_par2_absent "$dir"
}
register_test test_create_insufficient_space_fails_noninteractive

test_sqlite_store_clear_removes_entries() {
	log "test_sqlite_store_clear_removes_entries"
	local dir file db before after
	dir=$(make_temp_dir)
	file="$dir/clear_me.txt"
	db="$dir/brg_par2.sqlite3"

	echo "clear sqlite entries" > "$file"
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file"
	before=$(sqlite3 "$db" "select count(*) from brg_par2_files;")
	if [[ "$before" -lt 1 ]]; then
		fail "Expected at least one stored par2 row before clear, got $before"
		return 1
	fi

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet clear "$file"
	after=$(sqlite3 "$db" "select count(*) from brg_par2_files;")
	if [[ "$after" -ne 0 ]]; then
		fail "Expected 0 stored par2 rows after clear, got $after"
		return 1
	fi
}
register_test test_sqlite_store_clear_removes_entries

test_sqlite_clear_directory_removes_rows_for_missing_files() {
	log "test_sqlite_clear_directory_removes_rows_for_missing_files"
	local dir file db file_abs file_sql before after
	dir=$(make_temp_dir)
	file="$dir/missing_after_clear.txt"
	db="$dir/brg_par2.sqlite3"
	file_abs=$(abs_path "$file")
	file_sql=$(printf '%s' "$file_abs" | sed "s/'/''/g")

	echo "will delete source" > "$file"
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file"
	rm -f "$file"

	before=$(sqlite3 "$db" "select count(*) from brg_par2_files where source_path = '$file_sql';")
	if [[ "$before" -lt 1 ]]; then
		fail "Expected rows before clear, got $before"
		return 1
	fi

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet clear "$dir"

	after=$(sqlite3 "$db" "select count(*) from brg_par2_files where source_path = '$file_sql';")
	if [[ "$after" -ne 0 ]]; then
		fail "Expected rows to be removed by clear($dir), got $after"
		return 1
	fi
}
register_test test_sqlite_clear_directory_removes_rows_for_missing_files

test_sqlite_clear_directory_removes_brg_empty_markers() {
	log "test_sqlite_clear_directory_removes_brg_empty_markers"
	local dir file db marker
	dir=$(make_temp_dir)
	file="$dir/empty_under_sqlite.txt"
	db="$dir/brg_par2.sqlite3"
	marker="$dir/.empty_under_sqlite.txt.brg_empty"

	: > "$file"
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$dir"

	if [[ ! -f "$marker" ]]; then
		fail "Expected marker at $marker before clear"
		return 1
	fi

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet clear "$dir"
	if [[ -f "$marker" ]]; then
		fail "Expected sqlite clear($dir) to remove marker at $marker"
		return 1
	fi
}
register_test test_sqlite_clear_directory_removes_brg_empty_markers

test_sqlite_store_update_replaces_on_mtime_change() {
	log "test_sqlite_store_update_replaces_on_mtime_change"
	local dir file db file_abs file_sql mtime_old mtime_new stored_distinct stored_max
	dir=$(make_temp_dir)
	file="$dir/update_me.txt"
	db="$dir/brg_par2.sqlite3"
	file_abs=$(abs_path "$file")
	file_sql=$(printf '%s' "$file_abs" | sed "s/'/''/g")
	mtime_old=946684800
	mtime_new=$((mtime_old + 60))

	echo "first" > "$file"
	gtouch -h --date="@$mtime_old" "$file" 2>/dev/null || touch -h --date="@$mtime_old" "$file"

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file"

	echo "second" >> "$file"
	gtouch -h --date="@$mtime_new" "$file" 2>/dev/null || touch -h --date="@$mtime_new" "$file"

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet update "$file"

	stored_distinct=$(sqlite3 "$db" "select count(distinct source_mtime) from brg_par2_files where source_path = '$file_sql';")
	if [[ "$stored_distinct" -ne 1 ]]; then
		fail "Expected exactly 1 stored mtime after update, got $stored_distinct"
		return 1
	fi

	stored_max=$(sqlite3 "$db" "select max(source_mtime) from brg_par2_files where source_path = '$file_sql';")
	if [[ "$stored_max" -ne "$mtime_new" ]]; then
		fail "Expected stored mtime $mtime_new after update, got $stored_max"
		return 1
	fi
}
register_test test_sqlite_store_update_replaces_on_mtime_change

test_sqlite_store_stats_reports_covered() {
	log "test_sqlite_store_stats_reports_covered"
	local dir file db stats
	dir=$(make_temp_dir)
	file="$dir/stats.txt"
	db="$dir/brg_par2.sqlite3"

	echo "stats me" > "$file"
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file"

	stats=$(BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" "$TARGET_BIN" stats "$file")
	if [[ "$stats" != *"Coverage: 100.00%"* ]]; then
		fail "Expected sqlite-store stats to report 100% coverage"
		return 1
	fi
}
register_test test_sqlite_store_stats_reports_covered

test_sqlite_store_prune_removes_missing_sources() {
	log "test_sqlite_store_prune_removes_missing_sources"
	local dir file db before after
	dir=$(make_temp_dir)
	file="$dir/prune_me.txt"
	db="$dir/brg_par2.sqlite3"

	echo "prune sqlite rows" > "$file"
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file"
	rm -f "$file"

	before=$(sqlite3 "$db" "select count(*) from brg_par2_files;")
	if [[ "$before" -lt 1 ]]; then
		fail "Expected rows in sqlite db before prune, got $before"
		return 1
	fi

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet prune "$dir"

	after=$(sqlite3 "$db" "select count(*) from brg_par2_files;")
	if [[ "$after" -ne 0 ]]; then
		fail "Expected 0 rows after prune, got $after"
		return 1
	fi
}
register_test test_sqlite_store_prune_removes_missing_sources

test_sqlite_prune_is_scoped_to_target_path() {
	log "test_sqlite_prune_is_scoped_to_target_path"
	local dir_a dir_b file_a file_b db file_b_abs file_b_sql count_before count_after
	dir_a=$(make_temp_dir)
	dir_b=$(make_temp_dir)
	db="$dir_a/brg_par2.sqlite3"
	file_a="$dir_a/a.txt"
	file_b="$dir_b/b.txt"
	file_b_abs=$(abs_path "$file_b")
	file_b_sql=$(printf '%s' "$file_b_abs" | sed "s/'/''/g")

	echo "aaa" > "$file_a"
	echo "bbb" > "$file_b"
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file_a"
	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file_b"
	rm -f "$file_b"

	count_before=$(sqlite3 "$db" "select count(*) from brg_par2_files where source_path = '$file_b_sql';")
	if [[ "$count_before" -lt 1 ]]; then
		fail "Expected rows for file_b before prune, got $count_before"
		return 1
	fi

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet prune "$dir_a"

	count_after=$(sqlite3 "$db" "select count(*) from brg_par2_files where source_path = '$file_b_sql';")
	if [[ "$count_after" -ne "$count_before" ]]; then
		fail "Expected prune($dir_a) not to affect $file_b_abs rows"
		return 1
	fi

	BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet prune "$dir_b"

	count_after=$(sqlite3 "$db" "select count(*) from brg_par2_files where source_path = '$file_b_sql';")
	if [[ "$count_after" -ne 0 ]]; then
		fail "Expected prune($dir_b) to remove missing $file_b_abs rows"
		return 1
	fi
}
register_test test_sqlite_prune_is_scoped_to_target_path

test_sqlite_store_does_not_require_xxd() {
	log "test_sqlite_store_does_not_require_xxd"
	local dir file db stub_dir stub_xxd real_xxd sentinel
	dir=$(make_temp_dir)
	file="$dir/no_xxd.txt"
	db="$dir/brg_par2.sqlite3"

	echo "no xxd please" > "$file"

	stub_dir=$(mktemp -d --tmpdir brg_xxd_stub.XXXXXX)
	TEMP_DIRS+=("$stub_dir")
	stub_xxd="$stub_dir/xxd"
	real_xxd=$(command -v xxd)
	sentinel="$stub_dir/xxd_was_used"
	cat >"$stub_xxd" <<EOF
#!/usr/bin/env bash
: >"$sentinel"
"$real_xxd" "\$@"
EOF
	chmod +x "$stub_xxd"

	PATH="$stub_dir:$PATH" BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet create "$file"
	PATH="$stub_dir:$PATH" BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" run_quiet verify "$file"
	if [[ -f "$sentinel" ]]; then
		fail "Expected sqlite store not to invoke xxd"
		return 1
	fi
}
register_test test_sqlite_store_does_not_require_xxd

test_sqlite_store_errors_gracefully_without_readfile_writefile() {
	log "test_sqlite_store_errors_gracefully_without_readfile_writefile"
	local dir file db stub_dir stub_sqlite3 real_sqlite3 output rc
	dir=$(make_temp_dir)
	file="$dir/no_fileio_functions.txt"
	db="$dir/brg_par2.sqlite3"
	echo "hi" > "$file"

	stub_dir=$(mktemp -d --tmpdir brg_sqlite3_stub.XXXXXX)
	TEMP_DIRS+=("$stub_dir")
	stub_sqlite3="$stub_dir/sqlite3"
	real_sqlite3=$(command -v sqlite3)
	cat >"$stub_sqlite3" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
	if [[ "\$arg" == *readfile* || "\$arg" == *writefile* ]]; then
		echo "Error: no such function: readfile" >&2
		exit 1
	fi
done
exec "$real_sqlite3" "\$@"
EOF
	chmod +x "$stub_sqlite3"

	set +e
	output=$(PATH="$stub_dir:$PATH" BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" "$TARGET_BIN" create "$file" 2>&1)
	rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		fail "Expected create to fail when sqlite3 lacks readfile/writefile"
		return 1
	fi
	if [[ "$output" != *requires*sqlite3* || "$output" != *readfile* || "$output" != *writefile* ]]; then
		fail "Expected a graceful error mentioning sqlite3 readfile/writefile requirement"
		return 1
	fi
}
register_test test_sqlite_store_errors_gracefully_without_readfile_writefile

test_scoped_store_config_uses_most_specific_match() {
	log "test_scoped_store_config_uses_most_specific_match"
	local dir sub file_root file_sub xdg config_dir config_file db
	dir=$(make_temp_dir)
	sub="$dir/sub"
	mkdir -p "$sub"
	file_root="$dir/root.txt"
	file_sub="$sub/sub.txt"
	echo "root" > "$file_root"
	echo "sub" > "$file_sub"

	xdg=$(make_temp_dir)
	config_dir="$xdg/bitrot_guard"
	mkdir -p "$config_dir"
	config_file="$config_dir/config.toml"
	db="$xdg/brg_scoped.sqlite3"

	cat >"$config_file" <<EOF
[[store]]
scope = "$dir"
backend = "filesystem"

[[store]]
scope = "$sub"
backend = "sqlite"
db_path = "$db"
EOF

	XDG_CONFIG_HOME="$xdg" run_quiet create "$dir"

	if [[ ! -f "$dir/.root.txt.par2" ]]; then
		fail "Expected filesystem par2 for $file_root"
		return 1
	fi

	if find "$sub" -name "*.par2" -print -quit | grep -q .; then
		fail "Did not expect filesystem par2 files under sqlite-scoped $sub"
		return 1
	fi
	if [[ ! -f "$db" ]]; then
		fail "Expected sqlite db at $db"
		return 1
	fi
	if [[ "$(sqlite3 "$db" "select count(*) from brg_par2_files;")" -lt 1 ]]; then
		fail "Expected rows in sqlite db for $file_sub"
		return 1
	fi
}
register_test test_scoped_store_config_uses_most_specific_match

test_cli_config_set_store_writes_toml() {
	log "test_cli_config_set_store_writes_toml"
	local dir file xdg db config_file
	dir=$(make_temp_dir)
	file="$dir/a.txt"
	echo "hi" > "$file"
	xdg=$(make_temp_dir)
	db="$xdg/cli_config.sqlite3"
	config_file="$xdg/bitrot_guard/config.toml"

	XDG_CONFIG_HOME="$xdg" "$TARGET_BIN" config set-store --scope "$dir" --backend sqlite --db "$db" >/dev/null 2>&1
	if [[ ! -f "$config_file" ]]; then
		fail "Expected config file at $config_file"
		return 1
	fi

	XDG_CONFIG_HOME="$xdg" run_quiet create "$file"
	if find "$dir" -name "*.par2" -print -quit | grep -q .; then
		fail "Did not expect filesystem par2 files under sqlite-scoped $dir"
		return 1
	fi
	if [[ ! -f "$db" ]]; then
		fail "Expected sqlite db at $db"
		return 1
	fi
}
register_test test_cli_config_set_store_writes_toml

test_cli_config_list_stores_outputs_rules() {
	log "test_cli_config_list_stores_outputs_rules"
	local dir xdg db out
	dir=$(make_temp_dir)
	xdg=$(make_temp_dir)
	db="$xdg/list.sqlite3"

	XDG_CONFIG_HOME="$xdg" "$TARGET_BIN" config set-store --scope "$dir" --backend sqlite --db "$db" >/dev/null 2>&1
	out=$(XDG_CONFIG_HOME="$xdg" "$TARGET_BIN" config list-stores 2>/dev/null)
	if [[ "$out" != *"$dir"* || "$out" != *"sqlite"* ]]; then
		fail "Expected config list-stores output to include scope and backend"
		return 1
	fi
}
register_test test_cli_config_list_stores_outputs_rules

test_store_config_file_env_var_overrides_xdg_location() {
	log "test_store_config_file_env_var_overrides_xdg_location"
	local dir sub file xdg config_file db
	dir=$(make_temp_dir)
	sub="$dir/sub"
	mkdir -p "$sub"
	file="$sub/file.txt"
	echo "hi" > "$file"

	xdg=$(make_temp_dir)
	config_file="$xdg/custom_config.toml"
	db="$xdg/custom.sqlite3"

	cat >"$config_file" <<EOF
[[store]]
scope = "$dir"
backend = "sqlite"
db_path = "$db"
EOF

	XDG_CONFIG_HOME="$xdg" BRG_CONFIG_FILE="$config_file" run_quiet create "$dir"
	if find "$dir" -name "*.par2" -print -quit | grep -q .; then
		fail "Did not expect filesystem par2 files under sqlite-scoped $dir via BRG_CONFIG_FILE"
		return 1
	fi
	if [[ ! -f "$db" ]]; then
		fail "Expected sqlite db at $db via BRG_CONFIG_FILE"
		return 1
	fi
}
register_test test_store_config_file_env_var_overrides_xdg_location

test_filesystem_prune_removes_orphaned_par2_files() {
	log "test_filesystem_prune_removes_orphaned_par2_files"
	local dir file
	dir=$(make_temp_dir)
	file="$dir/orphan.txt"

	echo "orphan par2 files" > "$file"
	run_quiet create "$file"
	rm -f "$file"

	run_quiet prune "$dir"
	expect_par2_absent "$dir"
}
register_test test_filesystem_prune_removes_orphaned_par2_files

test_empty_file_create_writes_brg_empty_marker() {
	log "test_empty_file_create_writes_brg_empty_marker"
	local dir file marker
	dir=$(make_temp_dir)
	file="$dir/empty.txt"
	: > "$file"

	run_quiet create "$file"

	marker="$dir/.empty.txt.brg_empty"
	if [[ ! -f "$marker" ]]; then
		fail "Expected empty-file marker at $marker"
		return 1
	fi
	expect_par2_absent "$dir"
}
register_test test_empty_file_create_writes_brg_empty_marker

test_empty_file_stats_reports_covered() {
	log "test_empty_file_stats_reports_covered"
	local dir file stats
	dir=$(make_temp_dir)
	file="$dir/empty_stats.txt"
	: > "$file"

	run_quiet create "$file"
	stats=$("$TARGET_BIN" stats "$file")
	if [[ "$stats" != *"Coverage: 100.00%"* ]]; then
		fail "Expected empty-file stats to report 100% coverage"
		return 1
	fi
}
register_test test_empty_file_stats_reports_covered

test_update_switches_to_empty_marker_even_if_mtime_not_newer() {
	log "test_update_switches_to_empty_marker_even_if_mtime_not_newer"
	local dir file marker old_mtime
	dir=$(make_temp_dir)
	file="$dir/update_empty.txt"
	marker="$dir/.update_empty.txt.brg_empty"
	old_mtime=946684800

	echo "not empty" > "$file"
	gtouch -h --date="@$old_mtime" "$file" 2>/dev/null || touch -h --date="@$old_mtime" "$file"
	run_quiet create "$file"

	: > "$file"
	gtouch -h --date="@$old_mtime" "$file" 2>/dev/null || touch -h --date="@$old_mtime" "$file"
	run_quiet update "$file"

	if [[ ! -f "$marker" ]]; then
		fail "Expected empty marker after update at $marker"
		return 1
	fi
	expect_par2_absent "$dir"
}
register_test test_update_switches_to_empty_marker_even_if_mtime_not_newer

test_directory_update_does_not_process_brg_empty_markers() {
	log "test_directory_update_does_not_process_brg_empty_markers"
	local dir file marker double_marker expected_markers actual_markers
	dir=$(make_temp_dir)
	file="$dir/dir_empty.txt"
	: > "$file"

	run_quiet create "$dir"

	marker="$dir/.dir_empty.txt.brg_empty"
	double_marker="$dir/..dir_empty.txt.brg_empty.brg_empty"
	expected_markers=1
	actual_markers=$(find "$dir" -maxdepth 1 -type f -name '*.brg_empty' | wc -l | tr -d ' ')
	if [[ "$actual_markers" -ne "$expected_markers" ]]; then
		fail "Expected $expected_markers brg_empty markers after create, got $actual_markers"
		return 1
	fi

	run_quiet update "$dir"

	actual_markers=$(find "$dir" -maxdepth 1 -type f -name '*.brg_empty' | wc -l | tr -d ' ')
	if [[ "$actual_markers" -ne "$expected_markers" ]]; then
		fail "Expected $expected_markers brg_empty markers after update, got $actual_markers"
		return 1
	fi
	if [[ -f "$double_marker" ]]; then
		fail "Did not expect marker-of-marker at $double_marker"
		return 1
	fi
	expect_par2_absent "$dir"
}
register_test test_directory_update_does_not_process_brg_empty_markers

test_filesystem_prune_removes_orphaned_brg_empty_markers() {
	log "test_filesystem_prune_removes_orphaned_brg_empty_markers"
	local dir file marker
	dir=$(make_temp_dir)
	file="$dir/orphan_empty.txt"
	: > "$file"

	run_quiet create "$file"
	marker="$dir/.orphan_empty.txt.brg_empty"
	if [[ ! -f "$marker" ]]; then
		fail "Expected marker at $marker before prune"
		return 1
	fi

	rm -f "$file"
	run_quiet prune "$dir"

	if [[ -f "$marker" ]]; then
		fail "Expected orphan marker to be removed by prune"
		return 1
	fi
}
register_test test_filesystem_prune_removes_orphaned_brg_empty_markers

test_ignore_defaults() {
	log "test_ignore_defaults"
	local dir paths path
	dir=$(make_temp_dir)
	mkdir -p "$dir/.git" "$dir/.jj"
	echo "ignored" > "$dir/.git/ignored.txt"
	echo "ignored" > "$dir/.jj/ignored.txt"
	echo "keep" > "$dir/keep.txt"
	echo "desktop" > "$dir/.DS_Store"
	paths=(
		".elixir_ls/cache"
		"_build/dev"
		"node_modules/pkg"
		"deps/lib"
		"target/debug"
		"dist/assets"
		"build/output"
		".venv/bin"
		"venv/lib"
		"__pycache__"
		".mypy_cache"
		".pytest_cache"
		".tox"
		".bundle"
		"vendor/bundle"
		".cache"
		".parcel-cache"
		".angular/cache"
		".gradle"
		"cmake-build-debug"
		"out"
		".idea"
		".vscode"
	)
	for path in "${paths[@]}"; do
		mkdir -p "$dir/$path"
		echo "ignored" > "$dir/$path/ignore.me"
	done
	run_quiet create "$dir"
	for path in ".git" ".jj" "${paths[@]}"; do
		if find "$dir/$path" -name "*.par2" -print -quit | grep -q .; then
			fail "Found par2 inside $path"
			return 1
		fi
		done
	if find "$dir" -name ".DS_Store.par2" -print -quit | grep -q .; then
		fail "Found par2 for .DS_Store"
		return 1
	fi
	if ! find "$dir" -name ".keep.txt.par2" -print -quit | grep -q .; then
		fail "Non-ignored files missing par2"
		return 1
	fi
}
register_test test_ignore_defaults

if ! truthy SKIP_SYMLINK_TEST; then
	test_symlinked_test_invocation() {
		log "test_symlinked_test_invocation"
		local dir symlink
		dir=$(make_temp_dir)
		symlink="$dir/bitrot_guard"
		ln -s "$TARGET_BIN" "$symlink"
		if ! SKIP_SYMLINK_TEST=1 QUIET=1 "$symlink" --test; then
			fail "Symlinked --test invocation failed"
			return 1
		fi
	}
	register_test test_symlinked_test_invocation
fi

test_job_queue_plan_distribution() {
	log "test_job_queue_plan_distribution"
	local plan expected
	plan=$(printf '700\talpha\n600\tbeta\n400\tgamma\n100\tdelta\n' | BRG_WORKERS=2 "$TARGET_BIN" queue-plan)
	expected=$'worker1\t800\talpha delta\nworker2\t1000\tbeta gamma'
	if [[ "$plan" != "$expected" ]]; then
		fail "Job queue plan mismatch: $plan"
		return 1
	fi
}
register_test test_job_queue_plan_distribution

test_queue_files_create_sorted() {
	log "test_queue_files_create_sorted"
	local dir f1 f2 f3 output expected
	dir=$(make_temp_dir)
	f1="$dir/big.bin"
	f2="$dir/medium.bin"
	f3="$dir/small.bin"
	head -c 3072 </dev/zero > "$f1"
	head -c 2048 </dev/zero > "$f2"
	head -c 1024 </dev/zero > "$f3"
	output=$("$TARGET_BIN" queue-files create "$dir")
	expected=$(printf '3\t%s\n2\t%s\n1\t%s\n' "$(abs_path "$f1")" "$(abs_path "$f2")" "$(abs_path "$f3")")
	if [[ "$output" != "$expected" ]]; then
		fail "queue-files output mismatch: $output"
		return 1
	fi
}
register_test test_queue_files_create_sorted

test_queue_files_update_filters_mtime() {
	log "test_queue_files_update_filters_mtime"
	local dir newer up_to_date missing par2_old par2_new output expected
	dir=$(make_temp_dir)
	newer="$dir/newer.bin"
	up_to_date="$dir/up_to_date.bin"
	missing="$dir/missing.bin"
	head -c 2048 </dev/zero > "$newer"
	head -c 1024 </dev/zero > "$up_to_date"
	head -c 512 </dev/zero > "$missing"
	par2_old=$(get_par2_path "$newer")
	par2_new=$(get_par2_path "$up_to_date")
	touch -t 202401010101 "$par2_old"
	touch -t 202401010201 "$par2_new"
	touch -t 202401010301 "$newer"
	touch -t 202401010100 "$up_to_date"
	output=$("$TARGET_BIN" queue-files update "$dir")
	expected=$(printf '2\t%s\n1\t%s\n' "$(abs_path "$newer")" "$(abs_path "$missing")")
	if [[ "$output" != "$expected" ]]; then
		fail "queue-files update output mismatch: $output"
		return 1
	fi
}
register_test test_queue_files_update_filters_mtime

test_performance_stub_exists() {
	log "test_performance_stub_exists"
	local script="$PROJECT_ROOT/test/perf.sh"
	if [[ ! -x "$script" ]]; then
		fail "performance script missing or not executable"
		return 1
	fi
	local help
	help=$("$script" --help)
	if [[ "$help" != *"Bitrot Guard performance suite"* ]]; then
		fail "performance script help missing expected text"
		return 1
	fi
}
register_test test_performance_stub_exists

test_ignore_env() {
	log "test_ignore_env"
	local dir
	dir=$(make_temp_dir)
	echo "skip" > "$dir/env.skip"
	echo "keep" > "$dir/env.keep"
	BRG_IGNORE_PATTERNS="*.skip" run_quiet create "$dir"
	if find "$dir" -name ".env.skip.par2" -print -quit | grep -q .; then
		fail "Env pattern did not prevent protection"
		return 1
	fi
	if ! find "$dir" -name ".env.keep.par2" -print -quit | grep -q .; then
		fail "Env non-ignored file missing par2"
		return 1
	fi
}
register_test test_ignore_env

test_ignore_config() {
	log "test_ignore_config"
	local dir config_home cfg
	dir=$(make_temp_dir)
	config_home=$(make_temp_dir)
	mkdir -p "$config_home/bitrot_guard"
	echo "config.ignore" > "$config_home/bitrot_guard/ignore"
	echo "skip me" > "$dir/config.ignore"
	echo "keep me" > "$dir/process.cfg"
	XDG_CONFIG_HOME="$config_home" run_quiet create "$dir"
	if find "$dir" -name ".config.ignore.par2" -print -quit | grep -q .; then
		fail "Config ignore file still protected"
		return 1
	fi
	if ! find "$dir" -name ".process.cfg.par2" -print -quit | grep -q .; then
		fail "Config non-ignored file missing par2"
		return 1
	fi
}
register_test test_ignore_config

test_override_default_ignore_env() {
	log "test_override_default_ignore_env"
	local dir
	dir=$(make_temp_dir)
	mkdir -p "$dir/node_modules/lib" "$dir/custom_only"
	echo "mod" > "$dir/node_modules/lib/file.js"
	echo "custom" > "$dir/custom_only/keep.txt"
	BRG_DEFAULT_IGNORE_PATTERNS="custom_only:custom_only/**" run_quiet create "$dir"
	if ! find "$dir/node_modules" -name "*.par2" -print -quit | grep -q .; then
		fail "node_modules still ignored despite override"
		return 1
	fi
	if find "$dir/custom_only" -name "*.par2" -print -quit | grep -q .; then
		fail "Override pattern failed to ignore custom_only"
		return 1
	fi
}
register_test test_override_default_ignore_env

test_additional_ignore_patterns_env() {
	log "test_additional_ignore_patterns_env"
	local dir
	dir=$(make_temp_dir)
	mkdir -p "$dir/extra_dir" "$dir/node_modules"
	echo "extra" > "$dir/extra_dir/skip.txt"
	echo "mod" > "$dir/node_modules/file.js"
	echo "keep" > "$dir/keep.txt"
	BRG_ADDITIONAL_IGNORE_PATTERNS="extra_dir/**" run_quiet create "$dir"
	if find "$dir/extra_dir" -name "*.par2" -print -quit | grep -q .; then
		fail "Additional ignore did not apply to extra_dir"
		return 1
	fi
	if find "$dir/node_modules" -name "*.par2" -print -quit | grep -q .; then
		fail "Default ignore missing for node_modules"
		return 1
	fi
	if ! find "$dir" -name ".keep.txt.par2" -print -quit | grep -q .; then
		fail "Non-ignored files missing par2"
		return 1
	fi
}
register_test test_additional_ignore_patterns_env

test_about_output() {
	log "test_about_output"
	local output
	output=$("$TARGET_BIN" about)
	if [[ "$output" != "$EXPECTED_ABOUT" ]]; then
		fail "About output mismatch: $output"
		return 1
	fi
}
register_test test_about_output

test_path_resolution_fallback() {
	log "test_path_resolution_fallback"
	local real_dir link_base file symlink fake_path err_file stderr
	real_dir=$(make_temp_dir)
	link_base=$(make_temp_dir)
	ln -s "$real_dir" "$link_base/link"
	file="$real_dir/path-test.txt"
	symlink="$link_base/link/path-test.txt"
	echo "path data" > "$file"
	run_quiet create "$symlink"
	printf 'Z' | dd of="$file" bs=1 seek=2 conv=notrunc 2>/dev/null
	fake_path=$(make_temp_dir)
	cat > "$fake_path/greadlink" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$fake_path/greadlink"
	err_file=$(mktemp)
	if PATH="$fake_path:$PATH" "$TARGET_BIN" verify "$symlink" >/dev/null 2>"$err_file"; then
		fail "Verification unexpectedly succeeded in fallback test"
		rm -f "$err_file"
		return 1
	fi
	stderr=$(cat "$err_file")
	rm -f "$err_file"
	if [[ "$stderr" != *"Verification failed for"* ]]; then
		fail "Expected verification failure message when greadlink unavailable"
		return 1
	fi
}
register_test test_path_resolution_fallback

test_newline_filename() {
	log "test_newline_filename"
	local dir file
	dir=$(make_temp_dir)
	file="$dir/newline"$'\n'"name.txt"
	printf 'data' > "$file"
	run_quiet create "$dir"
	if ! find "$dir" -name ".*.par2" -print -quit | grep -q .; then
		fail "No par2 created for newline filename"
		return 1
	fi
}
register_test test_newline_filename

test_corruption_repair() {
	log "test_corruption_repair"
	local dir file
	dir=$(make_temp_dir)
	file="$dir/corrupt.bin"
	dd if=/dev/urandom of="$file" bs=4096 count=64 >/dev/null 2>&1
	run_quiet create "$file"
	dd if=/dev/zero of="$file" bs=512 count=1 seek=10 conv=notrunc >/dev/null 2>&1
	dd if=/dev/zero of="$file" bs=512 count=1 seek=30 conv=notrunc >/dev/null 2>&1
	run_quiet repair "$file"
	run_quiet verify "$file"
}
register_test test_corruption_repair

test_resource_fork_handling() {
	[[ "$OSTYPE" == darwin* ]] || { log "Skipping resource fork test on non-macOS"; return 0; }
	log "test_resource_fork_handling"
	local dir file rsrc_path
	dir=$(make_temp_dir)
	file="$dir/resource.txt"
	rsrc_path="$file/..namedfork/rsrc"
	echo "Main content" > "$file"
	echo "Resource fork content" > "$rsrc_path"
	run_quiet create "$file"
	printf 'X' | dd of="$file" bs=1 count=1 conv=notrunc >/dev/null 2>&1
	printf 'Y' | dd of="$rsrc_path" bs=1 count=1 conv=notrunc >/dev/null 2>&1
	run_quiet repair "$file"
	if ! grep -q "Main content" "$file"; then
		fail "Main content not restored"
		return 1
	fi
	if ! grep -q "Resource fork content" "$rsrc_path"; then
		fail "Resource fork not restored"
		return 1
	fi
	run_quiet clear "$file"
}
[[ "$OSTYPE" == darwin* ]] && register_test test_resource_fork_handling

test_sqlite_verify_does_not_leak_resource_fork_tmpdir() {
	[[ "$OSTYPE" == darwin* ]] || { log "Skipping sqlite resource fork leak test on non-macOS"; return 0; }
	log "test_sqlite_verify_does_not_leak_resource_fork_tmpdir"
	local dir file rsrc_path tmpdir db leaked
	dir=$(make_temp_dir)
	file="$dir/sqlite-rsrc.txt"
	rsrc_path="$file/..namedfork/rsrc"
	tmpdir=$(make_temp_dir)
	db="$dir/par2.sqlite3"

	echo "Main content" > "$file"
	echo "Resource fork content" > "$rsrc_path"

	TMPDIR="$tmpdir" BRG_PAR2_STORE=sqlite BRG_PAR2_DB_PATH="$db" "$TARGET_BIN" verify "$file" >/dev/null 2>&1 || true

	leaked=$(find "$tmpdir" -maxdepth 1 -type d -name 'brg_rsrc.*' -print -quit)
	if [[ -n "${leaked:-}" ]]; then
		fail "Expected no leaked brg_rsrc temp dirs, found: $leaked"
		return 1
	fi
}
[[ "$OSTYPE" == darwin* ]] && register_test test_sqlite_verify_does_not_leak_resource_fork_tmpdir

test_verbose_output() {
	log "test_verbose_output"
	local dir file output
	dir=$(make_temp_dir)
	file="$dir/verbose.txt"
	echo "content" > "$file"
	output=$("$TARGET_BIN" -v create "$dir" 2>&1)
	if [[ "$output" != *"Creating protection for: $file"* ]]; then
		fail "Verbose output missing for create"
		return 1
	fi
	output=$("$TARGET_BIN" --verbose verify "$dir" 2>&1)
	if [[ "$output" != *"Verifying: $file"* ]]; then
		fail "Verbose output missing for verify"
		return 1
	fi
}
register_test test_verbose_output

test_luajit_impl_invokes_luajit() {
	log "test_luajit_impl_invokes_luajit"
	local real_luajit
	real_luajit=$(command -v luajit || true)
	[[ -n "${real_luajit:-}" ]] || { log "Skipping luajit impl test (luajit missing)"; return 0; }

	local dir shim marker out
	dir=$(make_temp_dir)
	marker="$dir/luajit_called"
	shim="$dir/luajit_shim"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'set -euo pipefail'
		printf '%s\n' ": >\"$marker\""
		printf '%s\n' "exec \"$real_luajit\" \"\$@\""
	} >"$shim"
	chmod +x "$shim"

	out=$(BRG_IMPL=luajit BRG_LUAJIT_BIN="$shim" "$TARGET_BIN" about)
	if [[ "$out" != "$EXPECTED_ABOUT" ]]; then
		fail "About output mismatch under luajit impl: $out"
		return 1
	fi
	if [[ ! -f "$marker" ]]; then
		fail "Expected wrapper to invoke luajit when BRG_IMPL=luajit"
		return 1
	fi
}
register_test test_luajit_impl_invokes_luajit

test_luajit_about_does_not_require_bash_script() {
	log "test_luajit_about_does_not_require_bash_script"
	command -v luajit >/dev/null 2>&1 || { log "Skipping luajit about test (luajit missing)"; return 0; }

	local dir bin out
	dir=$(make_temp_dir)
	bin="$dir/bitrot_guard"
	cp "$PROJECT_ROOT/bitrot_guard" "$bin"
	cp "$PROJECT_ROOT/bitrot_guard.luajit" "$dir/bitrot_guard.luajit"
	chmod +x "$bin" "$dir/bitrot_guard.luajit"

	out=$(BRG_IMPL=luajit "$bin" about)
	if [[ "$out" != "$EXPECTED_ABOUT" ]]; then
		fail "About output mismatch without bash script: $out"
		return 1
	fi
}
register_test test_luajit_about_does_not_require_bash_script

run_tests() {
	local failed=0
	for test in "${TESTS[@]}"; do
		if "$test"; then
			if (( ! QUIET_MODE )); then
				echo "TEST PASS: $test"
			fi
		else
			echo "TEST FAIL: $test" >&2
			((failed++))
		fi
	done
	if ((failed > 0)); then
		if (( ! QUIET_MODE )); then
			echo "TEST SUMMARY: $failed failed" >&2
		fi
		return $failed
	fi
	if (( ! QUIET_MODE )); then
		echo "TEST SUMMARY: All tests passed"
	fi
	return 0
}

run_tests
