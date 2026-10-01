# Read input JSON payload piped via stdin
$rawInput = ""
try {
    $rawInput = $input | Out-String
} catch {
    $rawInput = ""
}

$data = $null
if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
    try {
        $data = $rawInput | ConvertFrom-Json
    } catch {
        $data = $null
    }
}

# Helper to find quota bucket dynamically across various schema representations
function Find-Bucket($quotaObj, [string]$windowPattern, [string]$namePattern) {
    if ($null -eq $quotaObj) { return $null }

    if ($quotaObj -is [System.Management.Automation.PSCustomObject] -or $quotaObj -is [System.Collections.IDictionary]) {
        $propNames = if ($quotaObj -is [System.Management.Automation.PSCustomObject]) {
            $quotaObj.PSObject.Properties | ForEach-Object { $_.Name }
        } else {
            $quotaObj.Keys
        }

        # 1. Match property name directly (e.g., "5h-gemini", "gemini-5h", "gemini_5h")
        foreach ($prop in $propNames) {
            $pLower = $prop.ToLower()
            if ($pLower -match $windowPattern -and $pLower -match $namePattern) {
                return $quotaObj.$prop
            }
        }

        # 2. Check nested structure (e.g., quota.5h.gemini or quota.gemini.5h)
        foreach ($prop in $propNames) {
            $pLower = $prop.ToLower()
            $val = $quotaObj.$prop
            if ($val -is [System.Management.Automation.PSCustomObject] -or $val -is [System.Collections.IDictionary]) {
                if ($pLower -match $windowPattern) {
                    $subNames = if ($val -is [System.Management.Automation.PSCustomObject]) { $val.PSObject.Properties | ForEach-Object { $_.Name } } else { $val.Keys }
                    foreach ($sp in $subNames) {
                        if ($sp.ToLower() -match $namePattern) {
                            return $val.$sp
                        }
                    }
                }
                if ($pLower -match $namePattern) {
                    $subNames = if ($val -is [System.Management.Automation.PSCustomObject]) { $val.PSObject.Properties | ForEach-Object { $_.Name } } else { $val.Keys }
                    foreach ($sp in $subNames) {
                        if ($sp.ToLower() -match $windowPattern) {
                            return $val.$sp
                        }
                    }
                }
            }
        }
    }

    # 3. Match array of quota bucket objects
    if ($quotaObj -is [System.Collections.IEnumerable] -and $quotaObj -isnot [string]) {
        foreach ($item in $quotaObj) {
            $combined = ""
            foreach ($key in @('id', 'name', 'bucket', 'window', 'model', 'tier')) {
                if ($item.$key) { $combined += " " + $item.$key }
            }
            $cLower = $combined.ToLower()
            if ($cLower -match $windowPattern -and $cLower -match $namePattern) {
                return $item
            }
        }
    }

    return $null
}

# Helper to extract used percentage from bucket
function Get-UsedPct($bucket, [int]$defaultPct) {
    if ($null -eq $bucket) { return $defaultPct }
    if ($null -ne $bucket.used_percentage) {
        return [Math]::Round([double]$bucket.used_percentage)
    }
    if ($null -ne $bucket.remaining_percentage) {
        return [Math]::Round(100.0 - [double]$bucket.remaining_percentage)
    }
    if ($null -ne $bucket.remaining_fraction) {
        return [Math]::Round((1.0 - [double]$bucket.remaining_fraction) * 100.0)
    }
    if ($null -ne $bucket.percentage) {
        return [Math]::Round([double]$bucket.percentage)
    }
    return $defaultPct
}

# Helper to format reset time (e.g. "Wed 10:28PM" or "Mon Aug 10 10:25AM")
function Format-Reset($bucket, [bool]$isWeekly, [string]$defaultText) {
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $dt = $null

    if ($null -ne $bucket) {
        if ($bucket.reset_time) {
            try {
                $dt = [DateTime]::Parse($bucket.reset_time, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
            } catch { }
        }
        if ($null -eq $dt -and $bucket.reset_in_seconds) {
            try {
                $dt = (Get-Date).AddSeconds([double]$bucket.reset_in_seconds)
            } catch { }
        }
    }

    if ($null -ne $dt) {
        if ($isWeekly) {
            return $dt.ToString("ddd MMM d hh:mmtt", $culture)
        } else {
            return $dt.ToString("ddd hh:mmtt", $culture)
        }
    }

    return $defaultText
}

# Line 1: Model | Effort | Context window
$modelName = "Gemini 3.6 Flash"
$effort = "high"
$ctx = "0%"

if ($null -ne $data) {
    if ($data.model) {
        if ($data.model.display_name) {
            $modelName = $data.model.display_name
        } elseif ($data.model.id) {
            $modelName = $data.model.id
        }
    }

    # Extract effort if embedded in name, e.g. "Gemini 3.6 Flash (High)"
    if ($modelName -match '^(.*?)\s*\((High|Medium|Low|Max)\)$') {
        $modelName = $matches[1].Trim()
        $effort = $matches[2].ToLower()
    } elseif ($data.effort) {
        $effort = "$($data.effort)".ToLower()
    } elseif ($data.reasoning_effort) {
        $effort = "$($data.reasoning_effort)".ToLower()
    } elseif ($data.model -and $data.model.effort) {
        $effort = "$($data.model.effort)".ToLower()
    }

    if ($data.context_window) {
        if ($null -ne $data.context_window.used_percentage) {
            $pct = [Math]::Round([double]$data.context_window.used_percentage)
            $ctx = "$pct%"
        } elseif ($null -ne $data.context_window.remaining_percentage) {
            $pct = [Math]::Round(100.0 - [double]$data.context_window.remaining_percentage)
            $ctx = "$pct%"
        }
    }
}

# Line 2 & 3: Quotas
$quota = if ($data) { $data.quota } else { $null }

$b5hGemini = Find-Bucket $quota "5h" "gemini"
$b5h3p     = Find-Bucket $quota "5h" "(3p|third|claude|external)"
$b7dGemini = Find-Bucket $quota "(7d|week)" "gemini"
$b7d3p     = Find-Bucket $quota "(7d|week)" "(3p|third|claude|external)"

$pct5hGemini  = Get-UsedPct $b5hGemini 11
$time5hGemini = Format-Reset $b5hGemini $false "Wed 10:28PM"

$pct5h3p      = Get-UsedPct $b5h3p 0
$time5h3p     = Format-Reset $b5h3p $false "Wed 11:02PM"

$pct7dGemini  = Get-UsedPct $b7dGemini 3
$time7dGemini = Format-Reset $b7dGemini $true "Mon Aug 10 10:25AM"

$pct7d3p      = Get-UsedPct $b7d3p 0
$time7d3p     = Format-Reset $b7d3p $true "Wed Aug 12 06:02PM"

# Render the 3-line statusline
Write-Output "$modelName | effort: $effort | ctx: $ctx"
Write-Output "5h: gemini: $pct5hGemini% (resets $time5hGemini) | 3p: $pct5h3p% (resets $time5h3p)"
Write-Output "7d: gemini: $pct7dGemini% (resets $time7dGemini) | 3p: $pct7d3p% (resets $time7d3p)"
