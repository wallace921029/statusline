#!/bin/bash
# Claude Code status line
# Line 1: model, effort, context usage
# Line 2: 5-hour quota percent + reset time
# Line 3: 7-day (weekly) quota percent + reset time

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# Line 1
line1="$model"
[ -n "$effort" ] && line1="$line1 | effort: $effort"
if [ -n "$used" ]; then
  line1="$line1 | ctx: $(printf '%.0f' "$used")%"
fi

# Line 2
line2=""
if [ -n "$five_pct" ]; then
  line2="5h: $(printf '%.0f' "$five_pct")%"
  if [ -n "$five_reset" ]; then
    five_time=$(date -r "${five_reset%.*}" "+%a %I:%M%p" 2>/dev/null)
    [ -n "$five_time" ] && line2="$line2 (resets $five_time)"
  fi
else
  line2="5h: n/a"
fi

# Line 3
line3=""
if [ -n "$week_pct" ]; then
  line3="7d: $(printf '%.0f' "$week_pct")%"
  if [ -n "$week_reset" ]; then
    week_time=$(date -r "${week_reset%.*}" "+%a %b %d %I:%M%p" 2>/dev/null)
    [ -n "$week_time" ] && line3="$line3 (resets $week_time)"
  fi
else
  line3="7d: n/a"
fi

printf '%s\n%s\n%s\n' "$line1" "$line2" "$line3"
