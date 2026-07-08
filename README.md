# ncdu-ps

An `ncdu`-style interactive disk usage browser for Windows, written in
pure PowerShell. Point it at a drive or folder, wait for the scan, then
walk the tree to find whatever is eating your space.

```
 ncdu-ps 1.0  --  C:\Users\dirk -------------------------------------------------
   45.2 GiB [##########]  87.3%   4.2k  /AppData
    3.1 GiB [######    ]  60.1%   1.8k  /Downloads
    1.9 GiB [####      ]  36.8%    987  /Documents
  512.0 MiB [#         ]  10.0%     42  /Desktop
   12.3 MiB [          ]   0.2%      1  /OneDrive
    ...
 Total disk usage: 51.4 GiB  Items: 7,213  Errors: 0    n/s/C sort | Enter open | ← up | d del | r rescan | ? help | q quit
```

## Why

`ncdu` is the fastest way to answer "what's filling up this disk?" on
Linux and macOS. Windows has nothing quite like it — WinDirStat is a
GUI, `Get-ChildItem -Recurse | Measure-Object Length -Sum` is slow and
non-interactive, and PowerShell's own tooling gives you a list, not a
tree you can browse. This script fills that gap: single file, no
install, works over RDP and SSH sessions where a GUI is inconvenient.

## Requirements

- Windows 10 or later (or Windows Server 2016+)
- Windows PowerShell 5.1, or PowerShell 7+
- A terminal that supports ANSI/VT escape sequences — Windows Terminal,
  VS Code integrated terminal, and the Windows 10+ conhost all do.
  Fallback is provided for older terminals via `-NoColor`.

No modules to install, no external dependencies. `ncdu.ps1` is the
entire program.

## Install

Copy `ncdu.ps1` anywhere on your machine. If you want to run it as
`ncdu` from any prompt, drop it in a directory that is on your `PATH`
and, optionally, add a wrapper function or alias in your PowerShell
profile:

```powershell
# In $PROFILE
function ncdu { & 'C:\Tools\ncdu.ps1' @args }
```

If script execution is blocked, either unblock the file:

```powershell
Unblock-File .\ncdu.ps1
```

or run it once with a scoped execution policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\ncdu.ps1 C:\
```

## Usage

```
.\ncdu.ps1 [-Path <string>] [-FollowReparsePoints] [-ExcludeHidden] [-NoColor]
```

Examples:

```powershell
# scan the current directory
.\ncdu.ps1

# scan the whole C: drive
.\ncdu.ps1 C:\

# scan a UNC share, follow junctions and symlinks, skip hidden/system items
.\ncdu.ps1 \\fileserver\projects -FollowReparsePoints -ExcludeHidden
```

While the scan runs, a one-line progress indicator ticks along with
files, directories, total bytes seen and error count. When the scan is
done the browser opens on the root of the tree.

## Keys

### Navigation

| Key                          | Action                              |
| ---------------------------- | ----------------------------------- |
| `Up` / `Down`, `k` / `j`     | Move the cursor                     |
| `PgUp` / `PgDn`              | Page up / down                      |
| `Home` / `End`               | Jump to first / last entry          |
| `Enter`, `Right`, `l`        | Descend into highlighted directory  |
| `Backspace`, `Left`, `h`     | Go up one level                     |

### Sorting

| Key | Action                                                       |
| --- | ------------------------------------------------------------ |
| `n` | Sort by name (repeat to flip ascending/descending)           |
| `s` | Sort by size (default; repeat to flip)                       |
| `C` | Sort by item count (uppercase; repeat to flip)               |
| `t` | Toggle "directories always first"                            |

### Display

| Key | Action                                                       |
| --- | ------------------------------------------------------------ |
| `g` | Cycle graph style: bar, percent, both (default), none        |

### Actions

| Key         | Action                                                          |
| ----------- | --------------------------------------------------------------- |
| `r`         | Rescan the current directory (subtree)                          |
| `d`         | Delete the highlighted file or directory (asks `y/N` first)     |
| `i`         | Show detailed info about the highlighted entry                  |
| `?`         | Show a help overlay                                             |
| `q`, `Esc`  | Quit                                                            |

Delete recurses — deleting a directory removes it and everything below
it. The confirmation prompt requires literal `y` or `Y`; anything else
cancels. After a successful delete the in-memory tree is updated in
place so parent totals stay accurate without a rescan.

## Options

| Parameter                | Purpose                                                                                                                                                                          |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-Path <string>`         | Directory to scan (positional, defaults to the current directory).                                                                                                               |
| `-FollowReparsePoints`   | Recurse into junctions, symbolic links and other NTFS reparse points. Off by default — matches `ncdu` behaviour and avoids double-counting a target that shows up twice in a tree. |
| `-ExcludeHidden`         | Skip entries with the `Hidden` or `System` attribute during scanning.                                                                                                            |
| `-NoColor`               | Disable ANSI color output and reverse-video row highlighting. Useful for terminals that render VT sequences as literal `ESC[...m` gibberish.                                     |

## What the columns mean

```
    45.2 GiB [##########]  87.3%   4.2k  /AppData
    │         │            │      │      └── name (dirs prefixed with `/`)
    │         │            │      └───────── recursive item count (files + dirs beneath)
    │         │            └──────────────── size as a percentage of the largest sibling
    │         └───────────────────────────── proportional bar (same denominator as percent)
    └─────────────────────────────────────── size (IEC units: KiB, MiB, GiB, TiB, ...)
```

Sizes are aggregated recursively: for a directory, the size shown is
the sum of everything inside it. The bar and percent are relative to
the *largest sibling in the current directory*, so they always fill
the row to 100% once — this is the standard `ncdu` convention and
makes it easy to eyeball where the weight is.

Directory names are shown in bold blue and prefixed with `/`.
Reparse points (junctions / symlinks) are shown in magenta.
Directories that could not be entered are shown in red.

## Reparse points, junctions, symlinks

By default `ncdu-ps` records reparse points as zero-sized leaves and
does not follow them. This keeps totals honest — following
`C:\Users\All Users` (a junction to `C:\ProgramData`) would count
`ProgramData` twice. If you actually want targets included, pass
`-FollowReparsePoints`; be aware that circular junctions will send the
scanner into an infinite loop.

## Errors and access denials

Files and directories that can't be read (permission denied, path too
long, in use by another process, etc.) increment the error counter
shown in the footer. Their size contribution is zero, the entry is
kept in the listing marked in red, and the scan continues. If you need
full coverage of `C:\Windows\System32\Config\` and similar, run the
script from an elevated ("Administrator") PowerShell.

## Performance notes

The scanner uses `System.IO.DirectoryInfo.EnumerateFileSystemInfos`
directly instead of `Get-ChildItem`. On a typical developer machine
this scans ~200-500k files per minute; a full `C:\` scan takes
2-10 minutes depending on the disk. Memory usage is roughly
`~250 bytes per entry`, so a million-file tree fits comfortably.

If you kick off a scan on a giant tree by accident, `Ctrl+C` will
abort. Once inside the browser, `r` rescans only the current subtree,
which is handy after freeing up space with `d`.

## Known limitations

- File sizes are the **logical** size reported by the file system, not
  the allocated size on disk. Sparse files, compressed files and
  deduplicated files will appear larger than the space they actually
  occupy on the volume.
- Deep directory trees (thousands of levels) can hit PowerShell's
  recursion limit. Realistic trees are fine.
- Unicode display widths are approximated as one column per code unit;
  East Asian double-width characters may cause slight misalignment.
- Terminal resizing during use is picked up on the next redraw, not
  instantly.

## License

`ncdu-ps` is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
[GNU General Public License](LICENSE) for more details.
