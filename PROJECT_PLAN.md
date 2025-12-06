# Project Plan

## Objectives

1. Ensure the built-in test suite runs when `bitrot_guard` is executed via a symlinked path.
   - Status: Completed (tests cover symlinked `--test` usage).
2. Evaluate concurrency and performance strategies for scaling to thousands of files.
   - Status: Completed; see notes below for short-term and long-term options.

## Notes

- Keep the test harness (`test/test.sh`) as the single entry point for unit tests; use `./bitrot_guard --test` to run it so CLI code paths stay exercised.
- Honor the TDD loop for any future behavior changes.

## Concurrency evaluation (2025-11-12)

- **Short term (stay in Bash):** introduce a bounded worker pool (e.g., using `xargs -P` or a manual job queue) so directory walks enqueue `par2` work while keeping process counts capped at CPU cores. Requires careful locking (unique `.par2` paths already unique per target) and aggregated exit-code handling, but keeps deployment simple.
- **Mid term:** wrap the hot paths (file discovery, hashing, par2 invocations) in a lightweight compiled helper (e.g., Zig or Rust) while keeping the existing Bash orchestration. This trims process-launch overhead without a full rewrite and still shells out to `par2cmdline`.
- **Long term rewrite:** reimplement core logic in a systems language with first-class concurrency (Rust, Go). Bind directly to `libpar2` for zero-copy hashing and chunk management; expect higher initial cost (FFI, packaging, parity with current CLI) but best throughput and easier parallel scheduling. This path also unlocks richer progress reporting and structured logging.

### Performance test suite (planned)

- Add a separate `performance` test entry point that fabricates sample directories by `dd`’ing deterministic chunks from `/dev/random` (seeded via `LC_CTYPE=C tr` and a fixed PRNG) so runs are reproducible.
- Measure baseline single-thread throughput vs. the soon-to-be parallel workers; store metrics (elapsed time, MB/s) in temp files and assert the multi-worker run is at least as fast as single-thread within a tolerance.
- Include teardown steps that remove generated data/par2 artifacts so repeated executions don’t balloon disk usage.
