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

This tool provides a middle ground: bitrot protection for long-term archival without requiring full redundancy or filesystem changes. Key features:

- Uses par2 to create error-correction data for files and directories
- Default 5% redundancy (configurable up to 100%)
- Warns if redundancy exceeds 20% (assuming use case mismatch)
- Works with any filesystem
- Files remain normally accessible
- Special handling for macOS resource forks
- Detects AND repairs corruption
- Efficient updates based on modification times

## Usage

```bash
./bitrot_guard <command> <target>

Commands:
  create  - Create par2 files for target file/directory
  verify  - Check integrity of target using par2 files
  repair  - Attempt to repair any corruption detected
  update  - Update par2 files if target has changed
  clear   - Remove all par2 files
  stats   - Show protection coverage statistics
```

## Environment Variables

- `NUM_PAR2_THREADS`: Number of threads for par2 (default: CPU core count)
- `BRG_REDUNDANCY`: Percentage of redundancy (default: 5)
- `PROTECT_DOTFILES`: Whether to protect hidden files (default: 1)

## How It Works

1. For each file, creates par2 recovery files with specified redundancy
2. On macOS, separately protects resource forks if present
3. Verification compares current file state against par2 data
4. Repair uses par2's error correction to fix corrupted bits
5. Update checks modification times to efficiently refresh protection

## Limitations

- Not a replacement for backups or RAID (won't help if entire drive fails)
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
