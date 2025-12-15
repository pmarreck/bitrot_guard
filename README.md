# Bitrot Guard

A lightweight tool for detecting and repairing bitrot in files and directories using par2, with special handling for macOS resource forks on macOS systems.

## The Problem: Silent Data Corruption

The size of hard drives has grown steadily over the years, but their bit error rate has remained relatively unchanged. As an example, the Seagate "Barracuda" line has a "Non Recoverable Bit Error per bit Read" rate of 1 bit per 1e14 bits read (see: [Barracuda datasheet](https://www.seagate.com/staticfiles/docs/pdf/datasheet/disc/barracuda-ds1737-1-1111us.pdf)). This means that 1 bit may be incorrectly reported every 1e14 bits read from the drive, or 11 TB of data. With 4-6+ TB drives becoming commonplace, the problem becomes very obvious very quickly at human timescales.

The situation is even worse with solid state media. Many flash cards fail silently and don't report error conditions to the host operating system. By the time the problem is detected, even backups may already contain corrupt data.

While some read errors are detectable by drive firmware (generating visible error messages), our main concern is "invisible" bit read errors, known as bitrot, which can cause silent data corruption without any warning.

## Existing Solutions and Their Limitations

The "proper" solution for bitrot protection is to use an advanced file system like ZFS, specifically created to address data integrity issues. However, ZFS comes with significant drawbacks:

- Requires significant technical overhead and expertise
- Complex licensing structure
- Requires 100% redundancy (double the capacity) for a mirrored setup
- Without mirroring, can only detect but not repair corruption
- Even with RAID-Z, requires ~20% overhead just for parity

## How bitrot_guard Helps

This tool provides a middle ground: bitrot protection for long-term archiving without requiring full redundancy or filesystem changes. Key features:

- Uses par2 to create error-correction data for files and directories
- Default 5% redundancy (configurable up to 100%)
- Warns if redundancy exceeds 20% (assuming use case mismatch)
- Works with any filesystem
- Files remain normally accessible
- Special handling for macOS resource forks
- Detects AND repairs corruption
- Efficient updates based on modification times

## Requirements

- `par2` command line tool (available via most package managers)
- Bash shell 4.2+
- The GNU version of standard Unix utilities (`find`, `stat`, etc.)

## Platform Support

- macOS (full support, including resource fork handling)
- Linux (full support, except resource fork handling)
- WSL (should work but untested)

## Usage

```bash
./bitrot_guard <command> <target>

Global options:
  --par2-store filesystem|sqlite
  --par2-db <path>  (only used when --par2-store sqlite)

Commands:
  config  - Configure store backend scoping
  create  - Create par2 files for target file/directory
  verify  - Check integrity of target using par2 files
  repair  - Attempt to repair any corruption detected
  update  - Update par2 files if target has changed
  clear   - Remove all par2 files
  prune   - Remove par2 data with no source file (filesystem or sqlite)
  stats   - Show protection coverage statistics
  test    - Run the test suite (or run `./test/test.sh` directly)
  about   - Show a one-line project description
```

## Environment Variables

- `NUM_PAR2_THREADS`: Number of threads for par2 (default: CPU core count)
- `BRG_REDUNDANCY`: Percentage of redundancy (default: 5)
- `PROTECT_DOTFILES`: Whether to protect hidden files (default: 1)
- `BRG_PAR2_STORE`: Par2 storage backend (`filesystem` default, or `sqlite`)
- `BRG_PAR2_DB_PATH`: Path to sqlite db when `BRG_PAR2_STORE=sqlite` (default: `$XDG_DATA_HOME/bitrot_guard/par2.sqlite3` or `~/.local/share/bitrot_guard/par2.sqlite3`)
- `BRG_DEFAULT_IGNORE_PATTERNS`: Colon-separated glob patterns that replace the built-in defaults. If unset, defaults ignore common VCS/build/cache artifacts such as `.git/**`, `.jj/**`, `.elixir_ls/**`, `_build/**`, `node_modules/**`, `deps/**`, `target/**`, `dist/**`, `build/**`, virtualenvs (`.venv/**`, `venv/**`), Python caches (`__pycache__`, `.mypy_cache`, `.pytest_cache`), `.tox`, `.bundle`, `vendor/bundle`, `.cache`, `.parcel-cache`, `.angular/cache`, `.gradle`, `cmake-build-*`, `out`, `.idea`, `.vscode`, and `.DS_Store`.
- `BRG_ADDITIONAL_IGNORE_PATTERNS`: Colon-separated globs appended after the defaults (or after `BRG_DEFAULT_IGNORE_PATTERNS` when it is set).
- `BRG_IGNORE_PATTERNS`: Colon-separated globs appended last. Useful for per-invocation overrides. Example: `BRG_IGNORE_PATTERNS="*.bak:node_modules/**"`.

Ignore patterns can also be stored one per line (with `#` comments) in `"$XDG_CONFIG_HOME/bitrot_guard/ignore"` or `~/.config/bitrot_guard/ignore`.
- `DEBUG`: Set to 1 to enable verbose debug output

## Store Backend Scoping (TOML)

By default, `BRG_PAR2_STORE=auto`, and the storage backend can be selected by path scope rules.

Config file:
- `$XDG_CONFIG_HOME/bitrot_guard/config.toml` (or `~/.config/bitrot_guard/config.toml`)
  - Override with `BRG_CONFIG_FILE=/path/to/config.toml`

Example:
```toml
[[store]]
scope = "/"
backend = "filesystem"

[[store]]
scope = "/Applications"
backend = "sqlite"
db_path = "/path/to/par2.sqlite3"
```

Commands:
```bash
./bitrot_guard config set-store --scope /Applications --backend sqlite --db ~/brg.sqlite3
./bitrot_guard config list-stores
```

## How It Works

1. For each file, creates par2 recovery files with specified redundancy
2. On macOS, separately protects resource forks if present
3. Verification compares current file state against par2 data
4. Repair uses par2's error correction to fix corrupted bits
5. Update checks modification times to efficiently refresh protection

## Limitations

- Not a replacement for backups or RAID (won't help if entire drive fails)

## Roadmap (near-term)

- TOML config upgrade to support multiple backends per scope (including `!backend` negation).
- Add a “fork/xattr” store backend (macOS first), with clear behavior when forks/xattrs are stripped by copies/archives.
- Spike: optional compression for sqlite-stored parity blobs (likely dictionary-trained zstd).
- Adds storage overhead (default 5%)
- Requires manual verification/repair (no automatic monitoring)
- Resource fork handling only available on macOS

## Why Not Just Use ZFS?

While ZFS is excellent for data integrity, it's overkill for many use cases. This tool:
- Works on any filesystem
- Requires minimal overhead (5% vs 100% for ZFS mirror)
- Simpler to set up and maintain
- Focused solely on bitrot protection
- Portable (par2 files can move with the data)

## Best Practices

1. Choose redundancy based on data importance (5% good for most cases)
2. Regularly verify important archives
3. Update par2 files after intentional modifications
4. Keep par2 files with the data they protect
5. Consider higher redundancy for critical small files

Remember: This is not a backup solution! It protects against bitrot, not drive failure or accidental deletion.
