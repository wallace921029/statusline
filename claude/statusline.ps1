$ErrorActionPreference = 'SilentlyContinue'
$raw = [Console]::In.ReadToEnd()
$j = $raw | ConvertFrom-Json
$inv = [Globalization.CultureInfo]::InvariantCulture

function Fmt-Reset($epoch, $fmt) {
    [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).ToLocalTime().ToString($fmt, $inv)
}

$parts = @($j.model.display_name)
if ($j.effort.level) { $parts += "effort: $($j.effort.level)" }
if ($null -ne $j.context_window.used_percentage) {
    $parts += ("ctx: {0:N0}%" -f [double]$j.context_window.used_percentage)
}
$lines = @($parts -join ' | ')

$five = $j.rate_limits.five_hour
if ($five) {
    $lines += ("5h: {0:N0}% (resets {1})" -f [double]$five.used_percentage, (Fmt-Reset $five.resets_at 'ddd hh:mmtt'))
}
$week = $j.rate_limits.seven_day
if ($week) {
    $lines += ("7d: {0:N0}% (resets {1})" -f [double]$week.used_percentage, (Fmt-Reset $week.resets_at 'ddd MMM dd hh:mmtt'))
}
[Console]::Out.Write(($lines -join "`n"))
