# par2z-cli compatibility notes

## Summary

`par2z-cli` is **not a drop-in replacement** for `par2cmdline` in `bitrot_guard` yet.
With `BRG_PAR2_BIN=bin/macos/par2z-cli`, create succeeds, but **repair is a no-op**
and `verify` fails with `error: SliceError`.

## Repro (macOS)

```
BRG_PAR2_BIN=./bin/macos/par2z-cli DEBUG=1 ./bitrot_guard create /tmp/sample.txt
```

Observed output (trimmed, current build):

```
DEBUG: PAR2 command: .../par2z-cli create -s4 -r5 -n1 -T"16" -a "/tmp/.sample.txt.par2" "/tmp/sample.txt"
default redundancy percent: 5
derived plan: total_size=11 block_size=4 data_blocks=3 recovery_blocks=1

... par2 files created ...

DEBUG: PAR2 command: .../par2z-cli repair -q "/tmp/.sample.txt.par2" "/tmp/sample.txt"
DEBUG: File content after repair: HeXlo World

DEBUG: PAR2 command: .../par2z-cli verify "/tmp/.sample.txt.par2" "/tmp/sample.txt"
error: SliceError
Verification failed for /tmp/sample.txt
```

Exit code: `0` for create/repair, but repair does not fix data; verify fails.

## Root causes (CLI mismatch)

`bitrot_guard` currently invokes par2 with:

- `create` uses: `create -s <bytes> -r <percent> -n1 -T <threads> -a <par2_path> <file>`
- `verify` uses: `verify <par2_path> <file>` (or `verify -B <dir> ...` for sqlite materialization)
- `repair` uses: `repair -q <par2_path> <file>` (or `repair -q -B <dir> ...`)

`par2z-cli --help` shows:

- `create` syntax is `par2z-cli create <par2 file> <data files...>`
  - No `-a` option (par2 output file is positional)
  - No `-T` threading flag
- `repair` is called **`recover`**
- `verify` exists and appears compatible

So the current invocation cannot work (or is incomplete):

- `-T` is unsupported (if ignored, OK; if parsed, should no-op).
- `repair` should be `recover`.
- `verify` currently errors with `SliceError` against files created by `par2z-cli` + damaged data, which suggests a mismatch in expected packet layout or missing data for recovery.

## What needs to change for compatibility

To support `par2z-cli`, `bitrot_guard` needs a compatibility adapter that:

- Switches `repair` → `recover`
- Emits `create` as: `par2z-cli create <par2_file> <data files...>`
  - Drop `-a`
  - Drop `-T` (unless par2z implements threads later)
- Keep `-s`, `-r`, `-n` as supported (these appear in `par2z-cli --help`)
- Preserve `-B` where currently used (verify/recover basepath)

## Test failure observed

Running the test suite with:

```
BRG_PAR2_BIN=./bin/macos/par2z-cli ./test/test.sh
```

still fails at:

- `test_single_file_repair`: “Repair did not restore file content”

This is consistent with **repair being a no-op**, leaving corrupted data in place.
