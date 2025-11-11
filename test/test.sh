#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET_BIN=${1:-"$PROJECT_ROOT/bitrot_guard"}
TARGET_BIN="$(cd "$(dirname "$TARGET_BIN")" && pwd)/$(basename "$TARGET_BIN")"

TESTS=()
TEMP_DIRS=()
EXPECTED_ABOUT="Bitrot Guard creates and uses par2 redundancy to detect and repair bitrot in your files and directories."

cleanup() {
	for dir in "${TEMP_DIRS[@]}"; do
		[[ -d "$dir" ]] && rm -rf "$dir"
	done
}
trap cleanup EXIT

log() {
	echo "TEST DEBUG: $*" >&2
}

fail() {
	echo "TEST ERROR: $*" >&2
	return 1
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

	"$TARGET_BIN" create "$dir" >/dev/null
	"$TARGET_BIN" verify "$dir" >/dev/null
	echo "gamma" >> "$file1"
	"$TARGET_BIN" update "$dir" >/dev/null
	"$TARGET_BIN" repair "$dir" >/dev/null
	stats=$("$TARGET_BIN" stats "$dir")
	if [[ "$stats" != *"Coverage:"* ]]; then
		fail "Stats missing coverage line"
		return 1
	fi
	"$TARGET_BIN" clear "$dir" >/dev/null
	expect_par2_absent "$dir"
}
register_test test_directory_lifecycle

test_single_file_repair() {
	log "test_single_file_repair"
	local dir file
	dir=$(make_temp_dir)
	file="$dir/single.txt"
	echo "This is a test file for single file operations" > "$file"
	"$TARGET_BIN" create "$file" >/dev/null
	printf 'X' | dd of="$file" bs=1 seek=5 conv=notrunc 2>/dev/null
	"$TARGET_BIN" repair "$file" >/dev/null
	"$TARGET_BIN" verify "$file" >/dev/null
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
	"$TARGET_BIN" --create "$file" >/dev/null
	if [[ ! -f "$dir/.sample.txt.par2" ]]; then
		fail "Alias --create did not create par2"
		return 1
	fi
	"$TARGET_BIN" --verify "$file" >/dev/null
	"$TARGET_BIN" --clear "$file" >/dev/null
	expect_par2_absent "$dir"
}
register_test test_cli_aliases

test_protect_dotfiles() {
	log "test_protect_dotfiles"
	local dir hidden
	dir=$(make_temp_dir)
	hidden="$dir/.hidden.txt"
	echo "secret" > "$hidden"
	PROTECT_DOTFILES=0 "$TARGET_BIN" create "$dir" >/dev/null
	if find "$dir" -name ".hidden.txt*.par2" -print -quit | grep -q .; then
		fail "Dotfile was protected despite PROTECT_DOTFILES=0"
		return 1
	fi
	PROTECT_DOTFILES=1 "$TARGET_BIN" update "$dir" >/dev/null
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
	"$TARGET_BIN" create "$dir" >/dev/null
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

test_ignore_env() {
	log "test_ignore_env"
	local dir
	dir=$(make_temp_dir)
	echo "skip" > "$dir/env.skip"
	echo "keep" > "$dir/env.keep"
	BRG_IGNORE_PATTERNS="*.skip" "$TARGET_BIN" create "$dir" >/dev/null
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
	XDG_CONFIG_HOME="$config_home" "$TARGET_BIN" create "$dir" >/dev/null
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
	"$TARGET_BIN" create "$symlink" >/dev/null
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
	"$TARGET_BIN" create "$dir" >/dev/null
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
	"$TARGET_BIN" create "$file" >/dev/null
	dd if=/dev/zero of="$file" bs=512 count=1 seek=10 conv=notrunc >/dev/null 2>&1
	dd if=/dev/zero of="$file" bs=512 count=1 seek=30 conv=notrunc >/dev/null 2>&1
	"$TARGET_BIN" repair "$file" >/dev/null
	"$TARGET_BIN" verify "$file" >/dev/null
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
	"$TARGET_BIN" create "$file" >/dev/null
	printf 'X' | dd of="$file" bs=1 count=1 conv=notrunc >/dev/null 2>&1
	printf 'Y' | dd of="$rsrc_path" bs=1 count=1 conv=notrunc >/dev/null 2>&1
	"$TARGET_BIN" repair "$file" >/dev/null
	if ! grep -q "Main content" "$file"; then
		fail "Main content not restored"
		return 1
	fi
	if ! grep -q "Resource fork content" "$rsrc_path"; then
		fail "Resource fork not restored"
		return 1
	fi
	"$TARGET_BIN" clear "$file" >/dev/null
}
[[ "$OSTYPE" == darwin* ]] && register_test test_resource_fork_handling

run_tests() {
	local failed=0
	for test in "${TESTS[@]}"; do
		if ! "$test"; then
			log "$test failed"
			((failed++))
		fi
	done
	if ((failed > 0)); then
		fail "$failed test suite(s) failed"
		return 1
	fi
	log "All tests passed"
	return 0
}

run_tests
