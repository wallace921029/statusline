#!/usr/bin/env bash

# Read JSON payload from stdin
PAYLOAD=$(cat)

if [ -z "$PAYLOAD" ]; then
    echo "  Unknown | effort: N/A | ctx: 0%"
    echo "  5h: N/A"
    echo "  7d: N/A"
    exit 0
fi

# Helper function to format ISO 8601 UTC timestamp to local datetime
format_reset_time() {
    local iso="$1"
    local fmt="$2"
    if [ -z "$iso" ] || [ "$iso" = "null" ]; then
        echo "N/A"
        return
    fi

    # Try GNU date (Linux)
    local formatted
    formatted=$(date -d "$iso" "+$fmt" 2>/dev/null)
    if [ -n "$formatted" ]; then
        echo "$formatted"
        return
    fi

    # Try BSD date (macOS) - parse UTC (-u) and convert to local time (-r)
    local ts
    ts=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" "+%s" 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%S%z" "$iso" "+%s" 2>/dev/null)
    if [ -n "$ts" ]; then
        date -r "$ts" "+$fmt" 2>/dev/null && return
    fi

    # Fallback to python3
    formatted=$(python3 -c "import datetime; print(datetime.datetime.fromisoformat('$iso'.replace('Z', '+00:00')).astimezone().strftime('$fmt'))" 2>/dev/null)
    if [ -n "$formatted" ]; then
        echo "$formatted"
        return
    fi

    echo "$iso"
}

# --- Line 1: Gemini 3.6 Flash | effort: high | ctx: 2% ---
RAW_MODEL=$(echo "$PAYLOAD" | jq -r '.model.display_name // .model.id // "Unknown"')
MODEL_NAME=$(echo "$RAW_MODEL" | sed -E 's/\s*\([^)]*\)//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
EFFORT=$(echo "$PAYLOAD" | jq -r '.model.effort // empty')

if [ -z "$EFFORT" ]; then
    EFFORT=$(echo "$RAW_MODEL" | sed -n -E 's/.*\(([^)]+)\).*/\1/p')
    [ -z "$EFFORT" ] && EFFORT="N/A"
fi
EFFORT_LOWER=$(echo "$EFFORT" | tr '[:upper:]' '[:lower:]')

CTX_USED=$(echo "$PAYLOAD" | jq -r '.context_window.used_percentage // 0')
CTX_PCT=$(awk "BEGIN {printf \"%.0f%%\", $CTX_USED}")

echo "  ${MODEL_NAME} | effort: ${EFFORT_LOWER} | ctx: ${CTX_PCT}"

# --- Helper to format all matching buckets in .quota ---
format_buckets() {
    local pattern="$1"
    local time_fmt="$2"
    local result=""

    # Get matching keys from .quota, order gemini first (1), then 3p (2), then others (3)
    local keys
    keys=$(echo "$PAYLOAD" | jq -r ".quota | keys[]? | select(test(\"$pattern\"; \"i\"))" | jq -R -s -r 'split("\n") | map(select(length > 0)) | sort_by(if startswith("gemini") then 1 elif startswith("3p") then 2 else 3 end)[]')

    for k in $keys; do
        local rem=$(echo "$PAYLOAD" | jq -r ".quota[\"$k\"].remaining_fraction // empty")
        local rtime=$(echo "$PAYLOAD" | jq -r ".quota[\"$k\"].reset_time // empty")
        if [ -n "$rem" ] && [ "$rem" != "null" ]; then
            local pct=$(awk "BEGIN {printf \"%.0f%%\", (1 - $rem) * 100}")
            local rfmt=$(format_reset_time "$rtime" "$time_fmt")
            
            # Simplify label: e.g. gemini-5h / gemini-weekly -> gemini, 3p-5h / 3p-weekly -> 3p
            local label=$(echo "$k" | sed -E 's/-(5h|5hour|weekly|week|7d)$//i')

            if [ -n "$result" ]; then
                result="${result} | ${label}: ${pct} (resets ${rfmt})"
            else
                result="${label}: ${pct} (resets ${rfmt})"
            fi
        fi
    done

    if [ -z "$result" ]; then
        echo "N/A"
    else
        echo "$result"
    fi
}

LINE2_5H=$(format_buckets "5h|5hour|session" "%a %I:%M%p")
LINE3_7D=$(format_buckets "week|7d" "%a %b %d %I:%M%p")

echo "  5h: ${LINE2_5H}"
echo "  7d: ${LINE3_7D}"
