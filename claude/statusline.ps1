# Claude Code status line (3 lines, truecolor) - PowerShell port of wallace921029/statusline (claude/statusline.sh)
#   Sonnet 5.5 | high | 89 tok/s | <branch>
#   ctx .......... 3%
#   5h ---------- 75% 2h 13m (14:30) | 7d ---------- 6% 2d 5h (Sat 14:30)
# NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI);
#       glyphs are built from char codes below.

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$raw = [Console]::In.ReadToEnd()
$j = $null
try { $j = $raw | ConvertFrom-Json } catch {}

# ---------- glyphs ----------
$G_BAR   = [string][char]0x2501   # heavy horizontal
$G_DOT   = [string][char]0x2022   # bullet
$G_BR    = [string][char]0x2387   # branch symbol
$G_MINUS = [string][char]0x2212   # minus sign
$G_BOLT  = [string][char]0x26A1   # high voltage

# ---------- palette (truecolor) ----------
$E = [char]27
$RST = "$E[0m"; $BOLD = "$E[1m"
function Fg([int]$r, [int]$g, [int]$b) { return "$E[38;2;$r;$g;${b}m" }
$DIM     = "$E[2;37m"
$C_LABEL = $DIM
$C_TRACK = Fg 55 60 72
$C_BLUE  = Fg 91 206 250
$C_PINK  = Fg 245 169 184
$C_WHITE = Fg 255 255 255
$C_TEXT  = $DIM
$C_MODEL = $C_PINK
$C_BRANCH = $C_BLUE
$C_SPEED = $C_BLUE
$C_OK = $C_BLUE; $C_WARN = $C_PINK; $C_BAD = $C_WHITE
$SEP = "$C_LABEL | $RST"

function Get-LevelColor([int]$p) {
    if ($p -ge 90) { return $C_BAD }
    elseif ($p -ge 60) { return $C_WARN }
    else { return $C_OK }
}

function Tr([double]$x) { return [int][math]::Truncate($x) }

# gradient color for cell i of n: blue -> pink -> white
function Get-Grad([int]$i, [int]$n) {
    $t = 0
    if ($n -gt 1) { $t = Tr ($i * 100 / ($n - 1)) }
    if ($t -le 50) {
        $f = $t * 2
        $r = 91  + (Tr ((245 - 91)  * $f / 100))
        $g = 206 + (Tr ((169 - 206) * $f / 100))
        $b = 250 + (Tr ((184 - 250) * $f / 100))
    } else {
        $f = ($t - 50) * 2
        $r = 245 + (Tr ((255 - 245) * $f / 100))
        $g = 169 + (Tr ((255 - 169) * $f / 100))
        $b = 184 + (Tr ((255 - 184) * $f / 100))
    }
    return Fg $r $g $b
}

# row: "label bar 42% suffix" (1 cell = 10%)
function Get-Row([string]$label, $pct, [string]$suffix = '', [int]$width = 10) {
    $out = "$C_LABEL$($label.PadRight(4))$RST"
    if ($null -eq $pct -or "$pct" -eq '') { return $out + "${C_LABEL}n/a$RST" }
    $p = [int][math]::Floor([double]$pct + 0.5)
    $filled = [int][math]::Floor(($p * $width + 50) / 100)
    if ($filled -gt $width) { $filled = $width }
    $bar = ''
    if ($label -eq 'ctx') {
        for ($i = 0; $i -lt $width; $i++) {
            if ($i -lt $filled) { $bar += (Get-Grad $i $width) + $G_DOT } else { $bar += $C_TRACK + $G_DOT }
        }
        $gi = 0; if ($filled -gt 0) { $gi = $filled - 1 }
        $col = Get-Grad $gi $width
    } else {
        $col = Get-LevelColor $p
        for ($i = 0; $i -lt $width; $i++) {
            if ($i -lt $filled) { $bar += $col + $G_BAR } else { $bar += $C_TRACK + $G_BAR }
        }
    }
    $out += "$bar$RST $col$BOLD$p%$RST"
    if ($suffix) { $out += " $C_LABEL$suffix$RST" }
    return $out
}

function Get-Rel($epoch) {
    if ($null -eq $epoch -or "$epoch" -eq '') { return '' }
    $s = [long]$epoch - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($s -le 0) { return 'now' }
    $d = [math]::Floor($s / 86400); $h = [math]::Floor(($s % 86400) / 3600); $m = [math]::Floor(($s % 3600) / 60)
    if ($d -gt 0) { return "${d}d ${h}h" }
    elseif ($h -gt 0) { return "${h}h ${m}m" }
    else { return "${m}m" }
}

function Get-At($epoch) {
    if ($null -eq $epoch -or "$epoch" -eq '') { return '' }
    $t = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).ToLocalTime()
    if ($t.Date -eq (Get-Date).Date) { return $t.ToString('HH:mm', $inv) }
    else { return $t.ToString('ddd HH:mm', $inv) }
}

function Get-ResetHint($epoch) {
    if ($null -eq $epoch -or "$epoch" -eq '') { return '' }
    return "$(Get-Rel $epoch) ($(Get-At $epoch))"
}

function Get-Human($n) {
    $n = [double]$n
    if ($n -ge 1000000) { return ($n / 1000000).ToString('0.0', $inv) + 'M' }
    elseif ($n -ge 1000) { return "$([math]::Floor($n / 1000))k" }
    else { return "$([int]$n)" }
}

# ---------- data ----------
$model  = if ($j.model.display_name) { $j.model.display_name } else { '?' }
$effort = $j.effort.level
$ctx    = if ($null -ne $j.context_window.used_percentage) { [math]::Floor([double]$j.context_window.used_percentage) } else { 0 }
$h5  = $j.rate_limits.five_hour.used_percentage
$h5r = $j.rate_limits.five_hour.resets_at
$d7  = $j.rate_limits.seven_day.used_percentage
$d7r = $j.rate_limits.seven_day.resets_at

$ctxUsed = if ($j.context_window.total_input_tokens) { [double]$j.context_window.total_input_tokens } else { 0 }
$ctxSize = if ($j.context_window.context_window_size) { [double]$j.context_window.context_window_size } else { 0 }
$added   = if ($j.cost.total_lines_added)   { [int]$j.cost.total_lines_added }   else { 0 }
$removed = if ($j.cost.total_lines_removed) { [int]$j.cost.total_lines_removed } else { 0 }
$hit  = $j.prompt_cache.hit_ratio
$warm = $j.prompt_cache.warm
$fast = $j.fast_mode
$pr   = $j.pr.number

$cwd = $j.workspace.current_dir
if (-not $cwd) { $cwd = $j.cwd }
if (-not $cwd) { $cwd = '.' }
$branch = (& git --no-optional-locks -C $cwd symbolic-ref --short HEAD 2>$null)
if (-not $branch) { $branch = (& git --no-optional-locks -C $cwd rev-parse --short HEAD 2>$null) }
if ($branch) { $branch = ($branch | Select-Object -First 1) }

# ---------- tok/s from the session transcript (latest completed response) ----------
function ConvertTo-Ts($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { return ([DateTimeOffset]$v.ToUniversalTime()) }
    return [DateTimeOffset]::Parse([string]$v, $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

function Get-Tps([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    $fi = Get-Item -LiteralPath $path
    # cache by transcript identity so we only parse when it changes
    $cacheFile = Join-Path $env:TEMP 'claude-statusline-tps.cache'
    $key = "$path|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    if (Test-Path -LiteralPath $cacheFile) {
        $lines = @(Get-Content -LiteralPath $cacheFile -Encoding UTF8)
        if ($lines.Count -ge 2 -and $lines[0] -eq $key) { return $lines[1] }
    }
    $result = ''
    $all = @(Get-Content -LiteralPath $path -Tail 100 -Encoding UTF8 | ForEach-Object {
        if ($_) { try { $_ | ConvertFrom-Json } catch {} }
    } | Where-Object { $_ })
    $done = @($all | Where-Object { $_.type -eq 'assistant' -and $null -ne $_.message.stop_reason })
    if ($done.Count -gt 0) {
        $id = $done[-1].message.id
        $blocks = @($done | Where-Object { $_.message.id -eq $id })
        $byUuid = @{}
        foreach ($e in $all) { if ($e.uuid) { $byUuid[[string]$e.uuid] = $e } }
        $cur = $byUuid[[string]$blocks[0].parentUuid]
        for ($k = 0; $k -lt 20; $k++) {
            if ($null -ne $cur -and $cur.type -in @('attachment', 'system', 'progress')) {
                $cur = $byUuid[[string]$cur.parentUuid]
            } else { break }
        }
        if ($null -ne $cur) {
            $end = ConvertTo-Ts $blocks[-1].timestamp
            $start = ConvertTo-Ts $cur.timestamp
            $out = $blocks[-1].message.usage.output_tokens
            if ($end -and $start -and $out) {
                $secs = ($end - $start).TotalSeconds
                if ($secs -ge 0.5 -and $out -gt 0) { $result = "$([math]::Floor($out / $secs))" }
            }
        }
    }
    try { Set-Content -LiteralPath $cacheFile -Value @($key, $result) -Encoding UTF8 } catch {}
    return $result
}
$tps = Get-Tps $j.transcript_path

# ---------- line 1: header ----------
$l1 = "$C_MODEL$BOLD$model$RST"
if ($effort) { $l1 += "$SEP$C_TEXT$effort$RST" }
if ($tps) { $l1 += "$SEP$C_SPEED$tps tok/s$RST" }
$bn = if ($branch) { $branch } else { 'no git' }
$l1 += "$SEP$C_BRANCH$G_BR $bn$RST"
if ($added -gt 0 -or $removed -gt 0) { $l1 += "$SEP$C_BLUE+$added$RST $C_PINK$G_MINUS$removed$RST" }
if ($pr) { $l1 += "$SEP${C_BRANCH}PR #$pr$RST" }
if ($fast -eq $true) { $l1 += "$SEP$C_WHITE$G_BOLT" + "fast$RST" }

# ---------- lines 2-3: bars ----------
$ctxExtra = ''
if ($ctxSize -gt 0) { $ctxExtra = "$(Get-Human $ctxUsed)/$(Get-Human $ctxSize)" }
if ($null -ne $hit -and "$hit" -ne '') {
    $hp = [int][math]::Floor([double]$hit * 100 + 0.5)
    if ($hp -ge 80) { $hc = $C_OK } elseif ($hp -ge 50) { $hc = $C_WARN } else { $hc = $C_BAD }
    if ($ctxExtra) { $ctxExtra += "$RST$SEP" }
    $ctxExtra += "${C_LABEL}cache $hc$hp%$RST"
    if ($warm -eq $false) { $ctxExtra += "$C_LABEL (cold)$RST" }
}
$l2 = Get-Row 'ctx' $ctx $ctxExtra
$l3 = (Get-Row '5h' $h5 (Get-ResetHint $h5r)) + $SEP + (Get-Row '7d' $d7 (Get-ResetHint $d7r))

[Console]::Out.Write($l1 + "`n" + $l2 + "`n" + $l3 + "`n")
