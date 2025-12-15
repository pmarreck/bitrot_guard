# Project Plan

## Objectives

1. Ensure the built-in test suite runs when `bitrot_guard` is executed via a symlinked path.
   - Status: Completed (tests cover symlinked `--test` usage).
2. Evaluate concurrency and performance strategies for scaling to thousands of files.
   - Status: Completed; see notes below for short-term and long-term options.
3. Add optional centralized sqlite par2 storage.
   - Status: Completed (create/verify/repair/update/clear support; db excluded from protection; CLI flags and env vars).
4. Add a prune command for orphaned par2 data.
   - Status: Completed (filesystem: removes orphan `.par2` files; sqlite: removes rows whose source files are missing).
5. Explore compression of stored par2 data (spike).
   - Status: Planned.
   - Idea: build a zstd dictionary trained on existing `.par2` corpus; store `codec` + `dict_id` per blob; measure size/time wins.
6. Explore sqlite storage fallback when `readfile()/writefile()` are unavailable (spike).
   - Status: Planned.
   - Idea: evaluate `printable_binary` encoding pipeline and/or a small compiled helper for streaming inserts/extracts without giant SQL literals.
7. Explore a “fork/xattr” parity backend (spike).
   - Status: In progress (macOS experiments captured below).
   - Goal: store parity on filesystems that support it (APFS first), and treat stripped forks/xattrs as “unprotected”.

## Notes

- Keep the test harness (`test/test.sh`) as the single entry point for unit tests; use `./bitrot_guard --test` to run it so CLI code paths stay exercised.
- Honor the TDD loop for any future behavior changes.

## macOS xattrs/resource forks (2025-12-15)

- `..namedfork/rsrc` (resource fork) supports at least `512MiB` on APFS in local tests.
- macOS does not support arbitrary named forks via `..namedfork/<name>` (only `rsrc` worked).
- `cp -a` preserved the resource fork in local tests; `zip` dropped it.
- `tar` extraction failed with `tar: Special header too large: %llu` once the resource fork was `1MiB` (creation succeeded, extraction failed), so tar is not a safe transport for large forks/xattrs without additional validation.

## Concurrency evaluation (2025-11-12)

- **Short term (stay in Bash):** introduce a bounded worker pool (e.g., using `xargs -P` or a manual job queue) so directory walks enqueue `par2` work while keeping process counts capped at CPU cores. Requires careful locking (unique `.par2` paths already unique per target) and aggregated exit-code handling, but keeps deployment simple.
- **Mid term:** wrap the hot paths (file discovery, hashing, par2 invocations) in a lightweight compiled helper (e.g., Zig or Rust) while keeping the existing Bash orchestration. This trims process-launch overhead without a full rewrite and still shells out to `par2cmdline`.
- **Long term rewrite:** reimplement core logic in a systems language with first-class concurrency (Rust, Go). Bind directly to `libpar2` for zero-copy hashing and chunk management; expect higher initial cost (FFI, packaging, parity with current CLI) but best throughput and easier parallel scheduling. This path also unlocks richer progress reporting and structured logging.

### Performance test suite (planned)

- Add a separate `performance` test entry point that fabricates sample directories by `dd`’ing deterministic chunks from `/dev/random` (seeded via `LC_CTYPE=C tr` and a fixed PRNG) so runs are reproducible.
- Measure baseline single-thread throughput vs. the soon-to-be parallel workers; store metrics (elapsed time, MB/s) in temp files and assert the multi-worker run is at least as fast as single-thread within a tolerance.
- Include teardown steps that remove generated data/par2 artifacts so repeated executions don’t balloon disk usage.
