#Requires -Version 5.1
# ncdu-ps -- ncdu-style hierarchical disk usage browser for Windows PowerShell.
# Copyright (C) 2026  ncdu-ps contributors
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.

<#
.SYNOPSIS
    ncdu-style hierarchical disk usage browser for Windows PowerShell.

.DESCRIPTION
    Scans a directory tree, then presents an interactive TUI similar to `ncdu`
    on Unix. Main purpose: quickly find what is eating a drive.

.PARAMETER Path
    The directory to scan. Defaults to the current directory.

.PARAMETER FollowReparsePoints
    Recurse into junctions, symbolic links and other NTFS reparse points.
    Off by default (mirrors ncdu, avoids cycles and double counting).

.PARAMETER ExcludeHidden
    Skip hidden and system items.

.PARAMETER NoColor
    Disable ANSI colors and reverse-video highlighting.

.EXAMPLE
    .\ncdu.ps1 C:\Users

.NOTES
    Keys:
      Up/Down, k/j   move cursor
      PgUp/PgDn      page
      Home/End       jump to first/last
      Enter, Right, l   descend into directory
      Backspace, Left, h   go up
      n              sort by name
      s              sort by size (default)
      C              sort by item count
      t              toggle "directories first"
      d              delete highlighted entry (with confirmation)
      r              rescan current directory
      i              show info about highlighted entry
      g              cycle graph style (bar / percent / both / none)
      ?              show this help
      q, Esc         quit
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path = (Get-Location).Path,

    [switch]$FollowReparsePoints,

    [switch]$ExcludeHidden,

    [switch]$NoColor
)

#region -------- constants & globals --------

$Script:ESC = [char]27
$Script:UseVT = -not $NoColor -and $Host.UI.SupportsVirtualTerminal

# Sort modes
$Script:SortMode      = 'Size'   # Name | Size | Count
$Script:SortDescending = $true
$Script:DirsFirst     = $true

# Graph style: 0 = bar, 1 = percent, 2 = bar+percent, 3 = none
$Script:GraphStyle    = 2

# Suppressed hidden/system items?
$Script:SkipHidden    = $ExcludeHidden.IsPresent
$Script:FollowLinks   = $FollowReparsePoints.IsPresent

# Runtime state
$Script:StatusMessage = ''

#endregion

#region -------- terminal helpers --------

function Get-TermSize {
    try {
        $w = [Console]::WindowWidth
        $h = [Console]::WindowHeight
        if ($w -lt 40) { $w = 40 }
        if ($h -lt 10) { $h = 10 }
        return @{ Width = $w; Height = $h }
    } catch {
        return @{ Width = 100; Height = 30 }
    }
}

function Clear-Screen {
    if ($Script:UseVT) {
        [Console]::Write("$Script:ESC[2J$Script:ESC[H")
    } else {
        Clear-Host
    }
}

function Move-Cursor([int]$Row, [int]$Col) {
    if ($Script:UseVT) {
        [Console]::Write("$Script:ESC[$($Row+1);$($Col+1)H")
    } else {
        try { [Console]::SetCursorPosition($Col, $Row) } catch {}
    }
}

function Hide-Cursor { if ($Script:UseVT) { [Console]::Write("$Script:ESC[?25l") } else { [Console]::CursorVisible = $false } }
function Show-Cursor { if ($Script:UseVT) { [Console]::Write("$Script:ESC[?25h") } else { [Console]::CursorVisible = $true  } }

function Style([string]$Text, [string]$Sgr) {
    if ($Script:UseVT -and $Sgr) { return "$Script:ESC[${Sgr}m$Text$Script:ESC[0m" }
    return $Text
}

# Truncate/pad a string to a visual width. PowerShell strings are UTF-16;
# for the character mix ncdu users see this "one code unit == one column"
# approximation is fine, and we avoid dragging in wcwidth logic.
function Fit-Text([string]$Text, [int]$Width) {
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) {
        if ($Width -le 3) { return $Text.Substring(0, $Width) }
        return $Text.Substring(0, $Width - 1) + '~'
    }
    return $Text.PadRight($Width)
}

#endregion

#region -------- formatting --------

# All branches yield exactly 10 columns so rows align.
function Format-Size([long]$Bytes) {
    if ($Bytes -lt 0) { return '         ?' }
    $units = @('  B','KiB','MiB','GiB','TiB','PiB','EiB')
    $v = [double]$Bytes
    $i = 0
    while ($v -ge 1024 -and $i -lt ($units.Count - 1)) { $v = $v / 1024; $i++ }
    if ($v -ge 100) { return ('{0,6:0} {1}'    -f $v, $units[$i]) }
    if ($v -ge 10)  { return ('{0,6:0.0} {1}'  -f $v, $units[$i]) }
    return                   ('{0,6:0.00} {1}' -f $v, $units[$i])
}

# 5-column count.
function Format-Count([long]$Count) {
    if ($Count -lt 10000)       { return ('{0,5}'   -f $Count) }
    if ($Count -lt 10000000)    { return ('{0,4:0}k' -f ($Count/1000)) }
    if ($Count -lt 10000000000) { return ('{0,4:0}M' -f ($Count/1000000)) }
    return                        ('{0,4:0}G' -f ($Count/1000000000))
}

function Make-Bar([double]$Fraction, [int]$Width) {
    if ($Width -le 0) { return '' }
    if ($Fraction -lt 0) { $Fraction = 0 }
    if ($Fraction -gt 1) { $Fraction = 1 }
    $filled = [int][math]::Round($Fraction * $Width)
    if ($filled -gt $Width) { $filled = $Width }
    return ('#' * $filled) + (' ' * ($Width - $filled))
}

#endregion

#region -------- data model & scan --------

# Node object shape:
#   Name          [string]
#   FullPath      [string]
#   Size          [long]      total bytes (recursive for dirs)
#   ItemCount     [long]      total files+dirs beneath (recursive)
#   IsDirectory   [bool]
#   IsReparsePoint[bool]
#   IsError       [bool]      access denied or other
#   Children      [List]      populated for directories
#   Parent        [object]

function New-Node {
    param([string]$Name, [string]$FullPath, [bool]$IsDirectory)
    return [PSCustomObject]@{
        Name           = $Name
        FullPath       = $FullPath
        Size           = [long]0
        ItemCount      = [long]0
        IsDirectory    = $IsDirectory
        IsReparsePoint = $false
        IsError        = $false
        Children       = if ($IsDirectory) { [System.Collections.Generic.List[object]]::new() } else { $null }
        Parent         = $null
    }
}

# Progress state used by the scan
$Script:ScanFiles     = 0
$Script:ScanDirs      = 0
$Script:ScanErrors    = 0
$Script:ScanBytes     = 0L
$Script:ScanTicker    = 0
$Script:ScanCurrent   = ''
$Script:LastErrorMsg  = ''       # first error encountered — surfaced in footer

# Print progress every N iterations. Small N keeps the UI responsive but too
# small burns time on Console.Write. 32 hits a good balance.
$Script:ScanProgressEvery = 32

function Print-ScanStatus {
    param([switch]$Force)
    $Script:ScanTicker++
    if (-not $Force -and (($Script:ScanTicker % $Script:ScanProgressEvery) -ne 0)) { return }
    $term = Get-TermSize
    Move-Cursor 0 0
    $line = ('Scanning... {0} files, {1} dirs, {2}, {3} errors  {4}' -f `
        $Script:ScanFiles, $Script:ScanDirs, (Format-Size $Script:ScanBytes).Trim(), $Script:ScanErrors, $Script:ScanCurrent)
    [Console]::Write((Fit-Text $line $term.Width))
}

# Bit flags as plain ints — avoids surprises from PowerShell 5.1 enum arithmetic.
$Script:ATTR_HIDDEN      = 0x2
$Script:ATTR_SYSTEM      = 0x4
$Script:ATTR_DIRECTORY   = 0x10
$Script:ATTR_REPARSE     = 0x400

# GetAttributes returns -1 (all bits) on Windows when the OS reports the file
# exists but its attributes could not be retrieved — for drive roots on some
# volumes this happens. Treat that as "unknown" so we don't flag it as a
# reparse point (all-bits-set would otherwise match the reparse mask).
function Get-SafeAttributes {
    param([string]$Path)
    try {
        $a = [int]([System.IO.File]::GetAttributes($Path))
        if ($a -eq -1) { return $null }
        return $a
    } catch {
        return $null
    }
}

function Test-IsDriveRoot {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $p = $Path.TrimEnd('\', '/')
    # "C:" style local root
    if ($p.Length -eq 2 -and $p[1] -eq ':') { return $true }
    # "\\server\share" style UNC root — 0, 1, or 2 segments after the "\\"
    if ($Path.StartsWith('\\')) {
        $rest  = $Path.Substring(2).TrimEnd('\', '/')
        $parts = $rest.Split([char]'\', [StringSplitOptions]::RemoveEmptyEntries)
        return ($parts.Length -le 2)
    }
    return $false
}

function Scan-Path {
    param([string]$AbsolutePath)

    $name = ''
    try { $name = [System.IO.Path]::GetFileName($AbsolutePath) } catch { }
    if ([string]::IsNullOrEmpty($name)) { $name = $AbsolutePath }

    $node = New-Node -Name $name -FullPath $AbsolutePath -IsDirectory $true
    $Script:ScanCurrent = $AbsolutePath

    # Reparse-point short circuit. Drive roots are never reparse points even if
    # Windows momentarily says otherwise; skipping them here also avoids a nasty
    # false positive when Attributes returns -1 (all bits set).
    if (-not (Test-IsDriveRoot $AbsolutePath)) {
        $rootAttrs = Get-SafeAttributes $AbsolutePath
        if ($null -ne $rootAttrs -and (($rootAttrs -band $Script:ATTR_REPARSE) -ne 0) -and -not $Script:FollowLinks) {
            $node.IsReparsePoint = $true
            return $node
        }
    }

    $dirInfo = $null
    try { $dirInfo = [System.IO.DirectoryInfo]::new($AbsolutePath) }
    catch {
        $node.IsError = $true
        $Script:ScanErrors++
        if (-not $Script:LastErrorMsg) { $Script:LastErrorMsg = "$AbsolutePath : $($_.Exception.Message)" }
        return $node
    }

    # Iterate with an explicit enumerator so a throw from MoveNext (which
    # `foreach` cannot catch mid-iteration) is caught cleanly and the scan
    # keeps whatever entries came before the failure.
    $enumerator = $null
    try { $enumerator = $dirInfo.EnumerateFileSystemInfos().GetEnumerator() }
    catch {
        $node.IsError = $true
        $Script:ScanErrors++
        if (-not $Script:LastErrorMsg) { $Script:LastErrorMsg = "$AbsolutePath : $($_.Exception.Message)" }
        return $node
    }

    try {
        while ($true) {
            $hasNext = $false
            try { $hasNext = $enumerator.MoveNext() }
            catch {
                $Script:ScanErrors++
                if (-not $Script:LastErrorMsg) { $Script:LastErrorMsg = "$AbsolutePath : $($_.Exception.Message)" }
                break
            }
            if (-not $hasNext) { break }
            $entry = $enumerator.Current

            try {
                $attrs = 0
                try { $attrs = [int]$entry.Attributes } catch { $attrs = 0 }

                if ($Script:SkipHidden -and (($attrs -band $Script:ATTR_HIDDEN) -ne 0)) { continue }
                if ($Script:SkipHidden -and (($attrs -band $Script:ATTR_SYSTEM) -ne 0)) { continue }

                if ($entry -is [System.IO.DirectoryInfo]) {
                    $child = Scan-Path -AbsolutePath $entry.FullName
                    $child.Parent = $node
                    [void]$node.Children.Add($child)
                    $node.Size += $child.Size
                    $node.ItemCount += $child.ItemCount + 1
                    $Script:ScanDirs++
                } else {
                    $len = [long]0
                    try { $len = [long]$entry.Length } catch { $len = 0 }
                    $fileNode = New-Node -Name $entry.Name -FullPath $entry.FullName -IsDirectory $false
                    $fileNode.Size = $len
                    $fileNode.IsReparsePoint = (($attrs -band $Script:ATTR_REPARSE) -ne 0)
                    $fileNode.Parent = $node
                    [void]$node.Children.Add($fileNode)
                    $node.Size += $len
                    $node.ItemCount++
                    $Script:ScanFiles++
                    $Script:ScanBytes += $len
                }
            } catch {
                $Script:ScanErrors++
                if (-not $Script:LastErrorMsg) { $Script:LastErrorMsg = "$($entry.FullName) : $($_.Exception.Message)" }
            }
            Print-ScanStatus
        }
    } finally {
        try { $enumerator.Dispose() } catch { }
    }

    return $node
}

function Start-Scan {
    param([string]$AbsolutePath)

    $Script:ScanFiles    = 0
    $Script:ScanDirs     = 0
    $Script:ScanErrors   = 0
    $Script:ScanBytes    = 0L
    $Script:ScanTicker   = 0
    $Script:LastErrorMsg = ''

    Clear-Screen
    Move-Cursor 0 0
    [Console]::Write("Scanning $AbsolutePath ...")

    $root = Scan-Path -AbsolutePath $AbsolutePath
    Print-ScanStatus -Force
    return $root
}

#endregion

#region -------- sort --------

function Sort-Children {
    param($Node)

    if (-not $Node -or -not $Node.IsDirectory -or -not $Node.Children) { return }

    $items = @($Node.Children)

    switch ($Script:SortMode) {
        'Name'  { $items = $items | Sort-Object -Property @{Expression = 'Name'; Descending = $Script:SortDescending}, @{Expression = 'FullPath'} }
        'Count' { $items = $items | Sort-Object -Property @{Expression = 'ItemCount'; Descending = $Script:SortDescending}, @{Expression = 'Name'} }
        default { $items = $items | Sort-Object -Property @{Expression = 'Size'; Descending = $Script:SortDescending}, @{Expression = 'Name'} }
    }

    if ($Script:DirsFirst) {
        $dirs  = @($items | Where-Object { $_.IsDirectory })
        $files = @($items | Where-Object { -not $_.IsDirectory })
        $items = $dirs + $files
    }

    $Node.Children.Clear()
    foreach ($it in $items) { [void]$Node.Children.Add($it) }
}

#endregion

#region -------- rendering --------

function Draw-Header {
    param([string]$FullPath, [int]$Width)
    Move-Cursor 0 0
    $title = " ncdu-ps 1.0  --  $FullPath "
    $line  = $title.PadRight($Width, '-')
    [Console]::Write((Style (Fit-Text $line $Width) '1;36'))  # bold cyan
}

function Draw-Footer {
    param($Node, [int]$Width, [int]$Row)

    Move-Cursor $Row 0
    $left = ' Total disk usage: {0}  Items: {1}  Errors: {2} ' -f `
        (Format-Size $Node.Size).Trim(), $Node.ItemCount, $Script:ScanErrors
    $right = ' n/s/C sort | Enter open | ← up | d del | r rescan | ? help | q quit '

    $mid = $Width - $left.Length - $right.Length
    if ($mid -lt 1) {
        [Console]::Write((Style (Fit-Text $left $Width) '1;36'))
    } else {
        $line = $left + (' ' * $mid) + $right
        [Console]::Write((Style (Fit-Text $line $Width) '1;36'))
    }

    if ($Script:StatusMessage) {
        Move-Cursor ($Row + 1) 0
        [Console]::Write((Fit-Text (' ' + $Script:StatusMessage) $Width))
    } elseif ($Script:LastErrorMsg -and $Script:ScanErrors -gt 0) {
        Move-Cursor ($Row + 1) 0
        [Console]::Write((Style (Fit-Text (' first error: ' + $Script:LastErrorMsg) $Width) '31'))
    }
}

function Draw-Row {
    param($Item, [long]$MaxSize, [int]$Width, [bool]$Selected)

    # Layout: "  99.9 MiB [##########]  99.9%  count  name"
    $sizeStr = Format-Size $Item.Size
    $pct = if ($MaxSize -gt 0) { [double]$Item.Size / [double]$MaxSize } else { 0 }

    $graph = ''
    switch ($Script:GraphStyle) {
        0 { $graph = '[' + (Make-Bar $pct 10) + ']' }
        1 { $graph = ('{0,5:0.0}%' -f ($pct * 100)) }
        2 { $graph = '[' + (Make-Bar $pct 10) + '] ' + ('{0,5:0.0}%' -f ($pct * 100)) }
        3 { $graph = '' }
    }

    $countStr = if ($Item.IsDirectory) { Format-Count $Item.ItemCount } else { '     ' }

    $nameColor = ''
    if ($Item.IsDirectory) {
        if ($Item.IsError)            { $nameColor = '31' }
        elseif ($Item.IsReparsePoint) { $nameColor = '35' }
        else                          { $nameColor = '1;34' }
    } elseif ($Item.IsReparsePoint) {
        $nameColor = '35'
    }

    $displayName = if ($Item.IsDirectory) { '/' + $Item.Name } else { $Item.Name }

    # Build the plain (uncolored) row, THEN apply color/highlight.
    # Applying VT codes first would confuse Fit-Text, which measures raw string length.
    $prefix = '   ' + $sizeStr + ' ' + $graph + '  ' + $countStr + '  '
    $nameCols = $Width - $prefix.Length
    if ($nameCols -lt 5) { $nameCols = 5 }
    $nameCell = Fit-Text $displayName $nameCols
    $plain = Fit-Text ($prefix + $nameCell) $Width

    if ($Selected) {
        [Console]::Write((Style $plain '7'))
    } elseif ($nameColor -and $Script:UseVT) {
        $split = $prefix.Length
        [Console]::Write($plain.Substring(0, $split) + (Style $plain.Substring($split) $nameColor))
    } else {
        [Console]::Write($plain)
    }
}

function Draw-UI {
    param($Node, [int]$Cursor, [int]$Scroll)

    $term = Get-TermSize
    $width = $term.Width
    $height = $term.Height

    Clear-Screen
    Draw-Header $Node.FullPath $width

    $listTop = 1
    $hasSecondFooterRow = ($Script:StatusMessage) -or ($Script:LastErrorMsg -and $Script:ScanErrors -gt 0)
    $footerRows = if ($hasSecondFooterRow) { 2 } else { 1 }
    $listRows = $height - $listTop - $footerRows
    if ($listRows -lt 1) { $listRows = 1 }

    $items = $Node.Children
    $count = if ($items) { $items.Count } else { 0 }

    # Special empty case
    if ($count -eq 0) {
        Move-Cursor $listTop 0
        [Console]::Write((Fit-Text '   <empty directory>' $width))
    } else {
        $maxSize = 0L
        foreach ($it in $items) { if ($it.Size -gt $maxSize) { $maxSize = $it.Size } }

        $end = [math]::Min($count - 1, $Scroll + $listRows - 1)
        for ($i = $Scroll; $i -le $end; $i++) {
            Move-Cursor ($listTop + ($i - $Scroll)) 0
            Draw-Row -Item $items[$i] -MaxSize $maxSize -Width $width -Selected ($i -eq $Cursor)
        }
        # blank the remainder
        for ($r = $end - $Scroll + 1; $r -lt $listRows; $r++) {
            Move-Cursor ($listTop + $r) 0
            [Console]::Write((' ' * $width))
        }
    }

    Draw-Footer $Node $width ($height - $footerRows)
}

#endregion

#region -------- info / help / delete overlays --------

function Wait-AnyKey {
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    [void][Console]::ReadKey($true)
}

function Show-Info {
    param($Item)
    if (-not $Item) { return }

    Clear-Screen
    Move-Cursor 0 0
    $lines = @(
        '  Item information',
        '  ================',
        ''
        '  Name        : ' + $Item.Name,
        '  Full path   : ' + $Item.FullPath,
        '  Type        : ' + $(if ($Item.IsDirectory) { 'Directory' } else { 'File' }),
        '  Size        : ' + (Format-Size $Item.Size).Trim() + '  (' + $Item.Size + ' bytes)',
        '  Items below : ' + $Item.ItemCount,
        '  Reparse pt  : ' + $Item.IsReparsePoint,
        '  Scan error  : ' + $Item.IsError,
        ''
        '  Press any key to return...'
    )
    for ($i = 0; $i -lt $lines.Count; $i++) {
        Move-Cursor $i 0
        [Console]::Write($lines[$i])
    }
    Wait-AnyKey
}

function Show-Help {
    Clear-Screen
    Move-Cursor 0 0
    $lines = @(
        '  ncdu-ps quick help',
        '  ==================',
        '',
        '  Navigation',
        '    Up/Down, k/j       move cursor',
        '    PgUp/PgDn          page up / down',
        '    Home/End           jump to first / last entry',
        '    Enter, Right, l    descend into directory',
        '    Backspace, Left, h go up one level',
        '',
        '  Sorting',
        '    n                  sort by name',
        '    s                  sort by size (default)',
        '    C                  sort by item count',
        '    t                  toggle "directories first"',
        '    (repeat key to flip ascending/descending)',
        '',
        '  Display',
        '    g                  cycle graph (bar / percent / both / none)',
        '',
        '  Actions',
        '    r                  rescan the current directory',
        '    d                  delete highlighted entry (confirmation required)',
        '    i                  show info about highlighted entry',
        '    q, Esc             quit',
        '',
        '  Press any key to return...'
    )
    for ($i = 0; $i -lt $lines.Count; $i++) {
        Move-Cursor $i 0
        [Console]::Write($lines[$i])
    }
    Wait-AnyKey
}

function Confirm-Delete {
    param($Item)
    if (-not $Item) { return $false }

    $term = Get-TermSize
    $msg = if ($Item.IsDirectory) {
        "  Delete DIRECTORY '$($Item.FullPath)' and ALL its contents? [y/N] "
    } else {
        "  Delete file '$($Item.FullPath)'? [y/N] "
    }

    Move-Cursor ($term.Height - 1) 0
    [Console]::Write((Style (Fit-Text $msg $term.Width) '1;31'))

    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    $key = [Console]::ReadKey($true)
    return ($key.KeyChar -eq 'y' -or $key.KeyChar -eq 'Y')
}

function Remove-Node {
    param($Item)
    if (-not $Item) { return $false }
    try {
        if ($Item.IsDirectory) {
            [System.IO.Directory]::Delete($Item.FullPath, $true)
        } else {
            [System.IO.File]::Delete($Item.FullPath)
        }
        return $true
    } catch {
        $Script:StatusMessage = "Delete failed: $($_.Exception.Message)"
        return $false
    }
}

#endregion

#region -------- main loop --------

function Adjust-Scroll {
    param([int]$Cursor, [ref]$Scroll, [int]$Rows, [int]$Count)
    if ($Count -eq 0) { $Scroll.Value = 0; return }
    if ($Cursor -lt $Scroll.Value) { $Scroll.Value = $Cursor }
    if ($Cursor -ge ($Scroll.Value + $Rows)) { $Scroll.Value = $Cursor - $Rows + 1 }
    if ($Scroll.Value -lt 0) { $Scroll.Value = 0 }
}

function Run-Browser {
    param($Root)

    Hide-Cursor
    try {
        $current = $Root
        Sort-Children $current
        $cursor = 0
        $scroll = 0

        while ($true) {
            $term = Get-TermSize
            $hasSecondFooterRow = ($Script:StatusMessage) -or ($Script:LastErrorMsg -and $Script:ScanErrors -gt 0)
            $listRows = $term.Height - 1 - ($(if ($hasSecondFooterRow) { 2 } else { 1 }))
            if ($listRows -lt 1) { $listRows = 1 }
            $count = if ($current.Children) { $current.Children.Count } else { 0 }

            if ($cursor -ge $count) { $cursor = [math]::Max(0, $count - 1) }
            if ($cursor -lt 0) { $cursor = 0 }
            Adjust-Scroll -Cursor $cursor -Scroll ([ref]$scroll) -Rows $listRows -Count $count

            Draw-UI -Node $current -Cursor $cursor -Scroll $scroll

            $key = [Console]::ReadKey($true)
            $Script:StatusMessage = ''

            switch ($key.Key) {
                'UpArrow'    { $cursor-- }
                'DownArrow'  { $cursor++ }
                'PageUp'     { $cursor -= $listRows }
                'PageDown'   { $cursor += $listRows }
                'Home'       { $cursor = 0 }
                'End'        { $cursor = $count - 1 }
                'LeftArrow'  {
                    if ($current.Parent) { $current = $current.Parent; $cursor = 0; $scroll = 0 }
                }
                'Backspace'  {
                    if ($current.Parent) { $current = $current.Parent; $cursor = 0; $scroll = 0 }
                }
                'RightArrow' {
                    if ($count -gt 0 -and $current.Children[$cursor].IsDirectory -and -not $current.Children[$cursor].IsReparsePoint) {
                        $current = $current.Children[$cursor]; Sort-Children $current; $cursor = 0; $scroll = 0
                    }
                }
                'Enter'      {
                    if ($count -gt 0 -and $current.Children[$cursor].IsDirectory -and -not $current.Children[$cursor].IsReparsePoint) {
                        $current = $current.Children[$cursor]; Sort-Children $current; $cursor = 0; $scroll = 0
                    }
                }
                'Escape'     { return }
                default {
                    switch -CaseSensitive ($key.KeyChar) {
                        'q' { return }
                        'k' { $cursor-- }
                        'j' { $cursor++ }
                        'h' { if ($current.Parent) { $current = $current.Parent; $cursor = 0; $scroll = 0 } }
                        'l' {
                            if ($count -gt 0 -and $current.Children[$cursor].IsDirectory -and -not $current.Children[$cursor].IsReparsePoint) {
                                $current = $current.Children[$cursor]; Sort-Children $current; $cursor = 0; $scroll = 0
                            }
                        }
                        'n' {
                            if ($Script:SortMode -eq 'Name') { $Script:SortDescending = -not $Script:SortDescending }
                            else { $Script:SortMode = 'Name'; $Script:SortDescending = $false }
                            Sort-Children $current
                        }
                        's' {
                            if ($Script:SortMode -eq 'Size') { $Script:SortDescending = -not $Script:SortDescending }
                            else { $Script:SortMode = 'Size'; $Script:SortDescending = $true }
                            Sort-Children $current
                        }
                        'C' {
                            if ($Script:SortMode -eq 'Count') { $Script:SortDescending = -not $Script:SortDescending }
                            else { $Script:SortMode = 'Count'; $Script:SortDescending = $true }
                            Sort-Children $current
                        }
                        't' {
                            $Script:DirsFirst = -not $Script:DirsFirst
                            Sort-Children $current
                            $Script:StatusMessage = "Directories first: $Script:DirsFirst"
                        }
                        'g' {
                            $Script:GraphStyle = ($Script:GraphStyle + 1) % 4
                        }
                        'i' {
                            if ($count -gt 0) { Show-Info $current.Children[$cursor] }
                        }
                        '?' { Show-Help }
                        'r' {
                            Show-Cursor
                            $rescanPath = $current.FullPath
                            $new = Start-Scan -AbsolutePath $rescanPath
                            Hide-Cursor
                            $new.Parent = $current.Parent
                            if ($current.Parent) {
                                # replace in parent's children
                                for ($i = 0; $i -lt $current.Parent.Children.Count; $i++) {
                                    if ($current.Parent.Children[$i].FullPath -eq $current.FullPath) {
                                        $current.Parent.Children[$i] = $new
                                        break
                                    }
                                }
                                # Recompute parent totals lazily: full rescan of parent chain is expensive,
                                # so just accept slightly stale sizes upstream until user rescans higher.
                            }
                            $current = $new
                            Sort-Children $current
                            $cursor = 0; $scroll = 0
                        }
                        'd' {
                            if ($count -gt 0) {
                                $victim = $current.Children[$cursor]
                                Show-Cursor
                                if (Confirm-Delete $victim) {
                                    if (Remove-Node $victim) {
                                        # detach from tree
                                        $current.Children.RemoveAt($cursor)
                                        # walk up subtracting size and count
                                        $n = $current
                                        while ($n) {
                                            $n.Size -= $victim.Size
                                            $n.ItemCount -= ($victim.ItemCount + 1)
                                            $n = $n.Parent
                                        }
                                        $Script:StatusMessage = "Deleted: $($victim.Name)"
                                        if ($cursor -ge $current.Children.Count) { $cursor = [math]::Max(0, $current.Children.Count - 1) }
                                    }
                                }
                                Hide-Cursor
                            }
                        }
                    }
                }
            }
        }
    } finally {
        Show-Cursor
        Clear-Screen
        Move-Cursor 0 0
    }
}

function Main {
    $resolved = $null
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    } catch {
        Write-Error "Path not found: $Path"
        return
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        Write-Error "Not a directory: $resolved"
        return
    }

    $root = Start-Scan -AbsolutePath $resolved
    Run-Browser -Root $root
}

#endregion

Main
