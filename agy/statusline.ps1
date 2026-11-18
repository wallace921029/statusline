# Antigravity CLI (agy) status line for Windows (PowerShell 5.1+)
# Faithful port of https://github.com/wallace921029/statusline/blob/main/agy/statusline.sh
# 5 aligned lines, truecolor, trans flag palette:
#   Gemini 4 Argon | high | 70 tok/s | <branch> main | +12 -3
#   ctx       ..........  12% 117k/1.0M | cache 98%
#   argon 7d  ----------  11% 6d 19h (Wed 14:00)
#   gem   5h  ----------   0% 4h 57min (18:59) | 7d ----------   0% 6d  0h (Tue 11:14)
#   3p    5h  ----------   0% 4h 57min (18:59) | 7d ----------   0% 6d 23h (Wed 13:59)
# (This file is intentionally pure ASCII; Unicode glyphs are built from code points.)

# NOTE: for speed this script avoids PowerShell cmdlets (module auto-loading costs
# hundreds of ms on Windows PowerShell 5.1) and uses .NET APIs directly.
$ErrorActionPreference = 'SilentlyContinue'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# JSON parser (JavaScriptSerializer -> Dictionary[string,object] / object[])
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Web.Extensions')
$JSS = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
$JSS.MaxJsonLength = [int]::MaxValue
$JSS.RecursionLimit = 1000

# ---------- read stdin (UTF-8) ----------
$inputText = ''
try {
  $reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8)
  $inputText = $reader.ReadToEnd()
} catch {}
$data = $null
try { if ($inputText.Trim()) { $data = $JSS.DeserializeObject($inputText) } } catch { $data = $null }

$script:NOW = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0

# ---------- glyphs ----------
$DOT     = [string][char]0x2022   # bullet
$HBAR    = [string][char]0x2501   # heavy horizontal
$SYM_BR  = [string][char]0x2387   # alternative key symbol (branch)
$SYM_WRN = [string][char]0x26A0   # warning sign

# ---------- palette (truecolor) ----------
$E = [char]27
$RST  = "${E}[0m"; $BOLD = "${E}[1m"
function fg($r, $g, $b) { "${E}[38;2;${r};${g};${b}m" }
$DIM      = "${E}[2;37m"          # dim white: plain text (labels, separators, hints)
$C_LABEL  = $DIM
$C_TRACK  = fg 55 60 72           # dark   : empty part of bars
$C_BLUE   = fg 91 206 250         # trans flag light blue  #5BCEFA
$C_PINK   = fg 245 169 184        # trans flag pink        #F5A9B8
$C_WHITE  = fg 255 255 255        # trans flag white
$C_TEXT   = $DIM
$C_MODEL  = $C_PINK
$C_BRANCH = $C_BLUE
$C_SPEED  = $C_BLUE
$C_ADD    = fg 120 215 140        # soft green for git additions
$C_DEL    = fg 245 130 140        # soft red for git deletions
# quota level colors: <60% blue, 60-89% pink, >=90% white
$C_OK = $C_BLUE; $C_WARN = $C_PINK; $C_BAD = $C_WHITE
$SEP = "${C_LABEL} | ${RST}"

# ---------- helpers ----------
# integer division truncating toward zero (bash arithmetic semantics)
function idiv([long]$a, [long]$b) { [long][Math]::Truncate($a / $b) }
function round0($x) { [long][Math]::Round([double]$x, 0, [MidpointRounding]::ToEven) }
function toLong($v) { if ($null -eq $v -or "$v" -eq '') { return [long]0 }; try { [long][Math]::Truncate([double]$v) } catch { [long]0 } }

function Get-Prop($obj, [string]$name) {
  if ($obj -is [System.Collections.Generic.IDictionary[string, object]]) {
    if ($obj.ContainsKey($name)) { return $obj[$name] }
  }
  return $null
}
# jq "//" : alternative when value is null or false
function J($v, $def) { if ($null -eq $v -or ($v -is [bool] -and -not $v)) { return $def }; return $v }

function level_color([long]$p) {
  if ($p -ge 90) { $C_BAD } elseif ($p -ge 60) { $C_WARN } else { $C_OK }
}

# gradient color for cell i of n: blue -> pink -> white (flag order)
# (bash integer arithmetic, truncating toward zero; inlined for speed)
function grad([long]$i, [long]$n) {
  $t = if ($n -gt 1) { [long][Math]::Truncate(($i * 100) / ($n - 1)) } else { [long]0 }
  if ($t -le 50) {
    $f = $t * 2
    $r = 91  + [Math]::Truncate((154 * $f) / 100)
    $g = 206 + [Math]::Truncate((-37 * $f) / 100)
    $b = 250 + [Math]::Truncate((-66 * $f) / 100)
  } else {
    $f = ($t - 50) * 2
    $r = 245 + [Math]::Truncate((10 * $f) / 100)
    $g = 169 + [Math]::Truncate((86 * $f) / 100)
    $b = 184 + [Math]::Truncate((71 * $f) / 100)
  }
  "${E}[38;2;${r};${g};${b}m"
}
# precomputed gradient for the 10-cell ctx bar
$GRAD10 = foreach ($gi in 0..9) { grad $gi 10 }

function human($v) {  # 6123 -> 6k, 1048576 -> 1.0M
  $n = toLong $v
  if ($n -ge 1000000) { return ($n / 1000000).ToString('0.0', $inv) + 'M' }
  elseif ($n -ge 1000) { return "$(idiv $n 1000)k" }
  else { return "$n" }
}

# ctx row: 9-char prefix ("ctx      ") + 10-dot gradient bar (1 dot = 10%)
function ctx_row($pct, [string]$suffix) {
  $width = 10
  $s = $C_LABEL + 'ctx'.PadRight(9) + $RST
  if ($null -eq $pct -or "$pct" -eq '' -or "$pct" -eq 'null') { return $s + $C_LABEL + 'n/a' + $RST }
  $pct = round0 $pct
  $filled = idiv ($pct * $width + 50) 100; if ($filled -gt $width) { $filled = $width }
  $out = ''
  for ($i = 0; $i -lt $width; $i++) {
    if ($i -lt $filled) { $out += $GRAD10[$i] + $DOT } else { $out += $C_TRACK + $DOT }
  }
  $ci = if ($filled -gt 0) { $filled - 1 } else { 0 }
  $col = $GRAD10[$ci]
  $s += $out + $RST + ' ' + $col + $BOLD + "$pct".PadLeft(3) + '%' + $RST
  if ($suffix) { $s += ' ' + $C_LABEL + $suffix + $RST }
  return $s
}

# quota segment: <prefix_label> <used_pct> <rstr> [pad_reset] (width=10, 1 cell = 10%)
function quota_seg([string]$label, $pct, [string]$rstr, [int]$pad = 0) {
  $width = 10
  $s = $C_LABEL + $label + $RST
  if ($null -eq $pct -or "$pct" -eq '' -or "$pct" -eq 'null') {
    if ($pad -eq 1) { return $s + $C_LABEL + 'n/a'.PadRight(32) + $RST }
    return $s + $C_LABEL + 'n/a' + $RST
  }
  $pct = round0 $pct
  if ($pct -lt 0) { $pct = 0 }
  if ($pct -gt 100) { $pct = 100 }
  $filled = idiv ($pct * $width + 50) 100; if ($filled -gt $width) { $filled = $width }
  $col = level_color $pct
  $out = ''
  for ($i = 0; $i -lt $width; $i++) {
    if ($i -lt $filled) { $out += $col + $HBAR } else { $out += $C_TRACK + $HBAR }
  }
  $s += $out + $RST + ' ' + $col + $BOLD + "$pct".PadLeft(3) + '%' + $RST
  if ($pad -eq 1) { $s += ' ' + $C_LABEL + $rstr.PadRight(16) + $RST }
  elseif ($rstr) { $s += ' ' + $C_LABEL + $rstr + $RST }
  return $s
}

# ---------- quota helpers (ported from the jq program) ----------
function used_pct($b) {
  if ($null -eq $b) { return $null }
  $rf = Get-Prop $b 'remaining_fraction'
  if ($null -eq $rf) { return $null }
  $v = (1 - [double]$rf) * 100
  if ($v -lt 0) { return 0.0 } elseif ($v -gt 100) { return 100.0 } else { return $v }
}
function p2($v) { "$v".PadLeft(2) }
function fmt_rst($b, [bool]$is7d) {
  if ($null -eq $b) { return '' }
  $s = $null
  $ris = Get-Prop $b 'reset_in_seconds'
  $rt  = Get-Prop $b 'reset_time'
  if ($null -ne $ris) { $s = [double]$ris }
  elseif ($null -ne $rt) {
    try {
      $dto = [DateTimeOffset]::Parse("$rt", $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal)
      $s = [Math]::Floor($dto.ToUnixTimeSeconds() - $script:NOW)
    } catch { $s = $null }
  }
  if ($null -eq $s) { return '' }
  if ($s -le 0) { return 'now' }
  $si = [long][Math]::Floor($s)
  $d = idiv $si 86400
  $h = if ($is7d) { idiv ($si % 86400) 3600 } else { idiv $si 3600 }
  $m = idiv ($si % 3600) 60
  if ($is7d -and $d -gt 0) { $txt = "${d}d $(p2 $h)h" }
  elseif ($s -lt 60)       { $txt = '   <1min' }
  else                     { $txt = "${h}h $(p2 $m)min" }
  $fmt = if ($is7d) { 'ddd HH:mm' } else { 'HH:mm' }
  $when = [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Floor($script:NOW + $s)).ToLocalTime().ToString($fmt, $inv)
  return "$txt ($when)"
}

# ---------- field extraction ----------
$m_o   = Get-Prop $data 'model'
$cw_o  = Get-Prop $data 'context_window'
$cu_o  = Get-Prop $cw_o 'current_usage'
$ws_o  = Get-Prop $data 'workspace'
$vcs_o = Get-Prop $data 'vcs'
$quota = Get-Prop $data 'quota'

$raw_model    = [string](J (Get-Prop $m_o 'display_name') '?')
$effort       = [string](J (Get-Prop $m_o 'effort') '')
$cycle_mode   = [string](J (Get-Prop $data 'cycle_mode') '')
$confirm      = J (Get-Prop $data 'tool_confirmation_pending') $false
$ctx          = J (Get-Prop $cw_o 'used_percentage') 0
$ctx_total_in = toLong (J (Get-Prop $cw_o 'total_input_tokens') 0)
$ctx_size     = toLong (J (Get-Prop $cw_o 'context_window_size') 0)
$cur_in       = toLong (J (Get-Prop $cu_o 'input_tokens') 0)
$cur_cache    = toLong (J (Get-Prop $cu_o 'cache_read_input_tokens') 0)
$cwd          = [string](J (Get-Prop $ws_o 'current_dir') (J (Get-Prop $data 'cwd') '.'))
$vcs_branch   = [string](J (Get-Prop $vcs_o 'branch') '')
$tp           = [string](J (Get-Prop $data 'transcript_path') '')
$tasks        = toLong (J (Get-Prop $data 'task_count') 0)
$sub_running  = 0
foreach ($sa in @(Get-Prop $data 'subagents')) { if ($null -ne $sa -and (Get-Prop $sa 'status') -ceq 'running') { $sub_running++ } }

$argon = J (Get-Prop $quota 'gemini-argon-wtu-weekly') $null
if ($null -eq $argon -and $quota -is [System.Collections.Generic.IDictionary[string, object]]) {
  foreach ($k in @($quota.Keys)) { if ($k -cmatch 'argon') { $argon = $quota[$k]; break } }
}
$q_g5 = Get-Prop $quota 'gemini-5h'
$q_g7 = Get-Prop $quota 'gemini-weekly'
$q_t5 = Get-Prop $quota '3p-5h'
$q_t7 = Get-Prop $quota '3p-weekly'

$gem5_pct = used_pct $q_g5;  $gem5_rst = fmt_rst $q_g5  $false
$gem7_pct = used_pct $q_g7;  $gem7_rst = fmt_rst $q_g7  $true
$arg7_pct = used_pct $argon; $arg7_rst = fmt_rst $argon $true
$tp5_pct  = used_pct $q_t5;  $tp5_rst  = fmt_rst $q_t5  $false
$tp7_pct  = used_pct $q_t7;  $tp7_rst  = fmt_rst $q_t7  $true

# Clean model name & extract effort fallback if embedded in display_name (e.g., "Gemini 4 Argon (High)")
$model = $raw_model
if ($raw_model -cmatch '^(.*)\s\((Low|Medium|High|Max)\)$') {
  $model = $Matches[1]
  if (-not $effort) { $effort = $Matches[2].ToLowerInvariant() }
}

# ---------- git ----------
# locate git.exe on PATH (no Get-Command); resolve scoop shims to the real exe
$GIT = $null
foreach ($dir in ($env:PATH -split ';')) {
  if (-not $dir) { continue }
  $cand = [System.IO.Path]::Combine($dir.Trim('"'), 'git.exe')
  if ([System.IO.File]::Exists($cand)) {
    $GIT = $cand
    $shim = [System.IO.Path]::ChangeExtension($cand, '.shim')
    if ([System.IO.File]::Exists($shim)) {
      foreach ($sl in [System.IO.File]::ReadAllLines($shim)) {
        if ($sl -match '^\s*path\s*=\s*"?([^"]+?)"?\s*$' -and [System.IO.File]::Exists($Matches[1])) { $GIT = $Matches[1]; break }
      }
    }
    break
  }
}
$hasGit = [bool]$GIT
function Invoke-Git([string[]]$gitArgs) {
  # returns @{ ok = <exit code 0>; out = <stdout text> }
  try {
    $o = & $GIT @gitArgs 2>$null
    return @{ ok = ($LASTEXITCODE -eq 0); out = ((@($o) -join "`n").TrimEnd("`r", "`n")) }
  } catch { return @{ ok = $false; out = '' } }
}

# Git branch fallback if .vcs.branch is empty
$branch = $vcs_branch
if (-not $branch -and $cwd -and $hasGit) {
  $r = Invoke-Git @('-C', $cwd, 'symbolic-ref', '--short', 'HEAD')
  if ($r.ok) { $branch = $r.out } else {
    $r2 = Invoke-Git @('-C', $cwd, 'rev-parse', '--short', 'HEAD')
    $branch = ($r.out + $r2.out)
  }
}

# Git diff stats (+added -deleted)
$git_diff = ''
if ($branch -and $cwd) {
  $diff_stat = ''
  if ($hasGit) {
    foreach ($ga in @(@('diff', 'HEAD', '--numstat'), @('diff', '--cached', '--numstat'), @('diff', '--numstat'))) {
      $r = Invoke-Git (@('-C', $cwd) + $ga)
      $diff_stat += $r.out + "`n"
      if ($r.ok) { break }
    }
  }
  [long]$added = 0; [long]$removed = 0
  foreach ($line in ($diff_stat -split "`r?`n")) {
    $f = $line.Trim() -split '\s+'
    if ($f.Count -ge 1) { $x = 0L; if ([long]::TryParse($f[0], [ref]$x)) { $added += $x } }
    if ($f.Count -ge 2) { $x = 0L; if ([long]::TryParse($f[1], [ref]$x)) { $removed += $x } }
  }
  # (PowerShell variables are case-insensitive, so don't reuse the bash names c_add/c_del)
  $col_add = $DIM; if ($added -gt 0) { $col_add = $C_ADD }
  $col_del = $DIM; if ($removed -gt 0) { $col_del = $C_DEL }
  $git_diff = "${col_add}+${added}${RST} ${col_del}-${removed}${RST}"
}

# ---------- real tok/s from agy transcript.jsonl ----------
if ($tp -and -not [System.IO.File]::Exists($tp)) {
  $tp = ([regex]'([\\/])\.gemini([\\/])antigravity([\\/])').Replace($tp, '$1.gemini$2antigravity-cli$3', 1)
}

function ts([string]$v) {
  $x = if ($v.Length -gt 19) { $v.Substring(0, 19) } else { $v }
  [DateTimeOffset]::ParseExact($x + 'Z', "yyyy-MM-dd'T'HH:mm:ss'Z'", $inv, [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUnixTimeSeconds()
}

# equivalent of `tail -n <count>`: read blocks backwards from EOF (file may be open by agy)
function Read-TailLines([string]$path, [int]$count) {
  $fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
  try {
    $len = $fs.Length
    if ($len -le 0) { return @() }
    $block = 65536; $pos = $len; $nl = 0
    $buf = [byte[]]::new($block)
    # skip a trailing newline so it is not counted as a line separator
    $fs.Position = $len - 1; $endAdj = if ($fs.ReadByte() -eq 10) { 1 } else { 0 }
    $limit = $len - $endAdj   # newlines at absolute offset >= $limit are ignored
    $start = 0L
    :outer while ($pos -gt 0) {
      $rd = [int][Math]::Min([long]$block, $pos)
      $pos -= $rd
      $fs.Position = $pos
      $got = 0; while ($got -lt $rd) { $c = $fs.Read($buf, $got, $rd - $got); if ($c -le 0) { break }; $got += $c }
      $k = $rd - 1
      while ($k -ge 0) {
        $k = [Array]::LastIndexOf($buf, [byte]10, $k, $k + 1)
        if ($k -lt 0) { break }
        if (($pos + $k) -lt $limit) {
          $nl++
          if ($nl -ge $count) { $start = $pos + $k + 1; break outer }
        }
        $k--
      }
    }
    $size = [int]($len - $start)
    $all = [byte[]]::new($size)
    $fs.Position = $start
    $got = 0; while ($got -lt $size) { $c = $fs.Read($all, $got, $size - $got); if ($c -le 0) { break }; $got += $c }
    $text = $utf8.GetString($all, 0, $got)
    return ,($text -split "`r?`n")
  } finally { $fs.Dispose() }
}

$tps = ''
if ($tp -and [System.IO.File]::Exists($tp)) {
  try {
    $mtime = ([DateTimeOffset][System.IO.File]::GetLastWriteTimeUtc($tp)).ToUnixTimeSeconds()
    $lines = Read-TailLines $tp 120
    # Same result as the jq program (`[ ...per-entry tok/s... ] | last`), but walks
    # backwards and stops at the first match, parsing only the lines it needs.
    $nx = $null; $isLast = $true; $lastTps = $null
    for ($li = $lines.Count - 1; $li -ge 0; $li--) {
      $ln = $lines[$li]
      if (-not $ln -or -not $ln.Trim()) { continue }
      try { $cur = $JSS.DeserializeObject($ln) } catch { continue }
      $isCand = $false
      if ((Get-Prop $cur 'type') -ceq 'PLANNER_RESPONSE') {
        $ot = J (Get-Prop $cur 'output_tokens') 0
        $ca = Get-Prop $cur 'created_at'
        if ([double]$ot -gt 0 -and $null -ne $ca) {
          $start = ts ([string]$ca)
          $end = $null
          if (-not $isLast) {
            if ((Get-Prop $nx 'type') -ceq 'GENERIC' -and $null -ne (Get-Prop $nx 'created_at')) { $end = ts ([string](Get-Prop $nx 'created_at')) }
          } elseif ($mtime -gt $start) {
            $end = $mtime
          }
          if ($null -ne $end -and ($end - $start) -gt 0) {
            $lastTps = [long][Math]::Floor([double]$ot / ($end - $start))
            break
          }
        }
      }
      $nx = $cur; $isLast = $false
    }
    if ($null -ne $lastTps) { $tps = "$lastTps" }
  } catch { $tps = '' }
}

# ---------- line 1: header ----------
$l1 = "${C_MODEL}${BOLD}${model}${RST}"
if ($effort) { $l1 += "${SEP}${C_TEXT}${effort}${RST}" }
if ($tps) { $l1 += "${SEP}${C_SPEED}${tps} tok/s${RST}" }
$brTxt = if ($branch) { $branch } else { 'no git' }
$l1 += "${SEP}${C_BRANCH}${SYM_BR} ${brTxt}${RST}"
if ($git_diff) { $l1 += "${SEP}${git_diff}" }
if ($cycle_mode) { $l1 += "${SEP}${C_TEXT}${cycle_mode}${RST}" }
if ($sub_running -gt 0) { $l1 += "${SEP}${C_BLUE}${sub_running} sub${RST}" }
if ($tasks -gt 0) { $l1 += "${SEP}${C_BLUE}${tasks} task${RST}" }
if ("$confirm" -eq 'True' -or "$confirm" -eq 'true') { $l1 += "${SEP}${C_PINK}${BOLD}${SYM_WRN} confirm${RST}" }

# ---------- line 2: ctx ----------
$ctx_extra = ''
$ctx_used = $cur_in + $cur_cache
if ($ctx_used -le 0) { $ctx_used = $ctx_total_in }
if ($ctx_size -gt 0) { $ctx_extra = "$(human $ctx_used)/$(human $ctx_size)" }
$sumc = $cur_in + $cur_cache
if ($sumc -gt 0) {
  $hp = idiv ($cur_cache * 100 + (idiv $sumc 2)) $sumc
  if ($hp -ge 80) { $hc = $C_OK } elseif ($hp -ge 50) { $hc = $C_WARN } else { $hc = $C_BAD }
  if ($ctx_extra) { $ctx_extra += "${RST}${SEP}" }
  $ctx_extra += "${C_LABEL}cache ${hc}${hp}%${RST}"
}
$l2 = ctx_row $ctx $ctx_extra

# ---------- line 3: argon (7d standalone row above gem) ----------
$l3 = quota_seg 'argon 7d ' $arg7_pct $arg7_rst

# ---------- line 4: gem (5h + 7d) ----------
$l4 = (quota_seg 'gem   5h ' $gem5_pct $gem5_rst 1) + $SEP + (quota_seg '7d ' $gem7_pct $gem7_rst)

# ---------- line 5: 3p (5h + 7d) ----------
$l5 = (quota_seg '3p    5h ' $tp5_pct $tp5_rst 1) + $SEP + (quota_seg '7d ' $tp7_pct $tp7_rst)

# ---------- emit (raw UTF-8 bytes, no BOM, LF line endings) ----------
$text = "$l1`n$l2`n$l3`n$l4`n$l5`n"
$bytes = $utf8.GetBytes($text)
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
