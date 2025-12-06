#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET_BIN=${1:-"$PROJECT_ROOT/bitrot_guard"}
TARGET_BIN="$(cd "$(dirname "$TARGET_BIN")" && pwd)/$(basename "$TARGET_BIN")"

TESTS=()
TEMP_DIRS=()
EXPECTED_ABOUT="Bitrot Guard creates and uses par2 redundancy to detect and repair bitrot in your files and directories."
QUIET_MODE=0

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

test_ignore_defaults() {
	log "test_ignore_defaults"
	local dir
	dir=$(make_temp_dir)
	mkdir -p "$dir/.git" "$dir/.jj"
	echo "ignored" > "$dir/.git/ignored.txt"
	echo "ignored" > "$dir/.jj/ignored.txt"
	echo "keep" > "$dir/keep.txt"
	run_quiet create "$dir"
	if find "$dir/.git" -name "*.par2" -print -quit | grep -q .; then
		fail "Found par2 inside .git"
		return 1
	fi
	if find "$dir/.jj" -name "*.par2" -print -quit | grep -q .; then
		fail "Found par2 inside .jj"
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
		if ! SKIP_SYMLINK_TEST=1 QUIET=1 "$symlink" --test >/dev/null 2>&1; then
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
