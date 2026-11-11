
#!/usr/bin/env bash
# Claude Code status line (3 lines, truecolor):
#   Sonnet 5 | high | 89 tok/s | ⎇ main
#   ctx •••••••••• 3%
#   5h ━━━━━━━━━━ 75% 2h 13m (14:30) | 7d ━━━━━━━━━━ 6% 2d 5h (Sat 14:30)
input=$(cat)
j() { echo "$input" | jq -r "$1" 2>/dev/null; }

# ---------- palette (truecolor) ----------
RST=$'\033[0m'; BOLD=$'\033[1m'
fg() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
DIM=$'\033[2;37m'           # dim white: plain text (labels, separators, hints)
C_LABEL=$DIM
C_TRACK=$(fg 55 60 72)       # dark   : empty part of bars
C_BLUE=$(fg 91 206 250)      # trans flag light blue  #5BCEFA
C_PINK=$(fg 245 169 184)     # trans flag pink        #F5A9B8
C_WHITE=$(fg 255 255 255)    # trans flag white
C_TEXT=$DIM
C_MODEL=$C_PINK
C_BRANCH=$C_BLUE
C_SPEED=$C_BLUE
# 5h/7d level colors: <60% blue, 60-90% pink, >=90% white
C_OK=$C_BLUE; C_WARN=$C_PINK; C_BAD=$C_WHITE
SEP="${C_LABEL} | ${RST}"

level_color() {  # $1 = integer percent
  if   [ "$1" -ge 90 ]; then printf '%s' "$C_BAD"
  elif [ "$1" -ge 60 ]; then printf '%s' "$C_WARN"
  else                       printf '%s' "$C_OK"; fi
}

# gradient color for cell i of n: blue -> pink -> white (flag order)
grad() {
  local i=$1 n=$2 t f r g b
  t=$(( n > 1 ? i * 100 / (n - 1) : 0 ))
  if [ "$t" -le 50 ]; then
    f=$((t * 2));        r=$((91  + (245-91)  * f / 100)); g=$((206 + (169-206) * f / 100)); b=$((250 + (184-250) * f / 100))
  else
    f=$(((t - 50) * 2)); r=$((245 + (255-245) * f / 100)); g=$((169 + (255-169) * f / 100)); b=$((184 + (255-184) * f / 100))
  fi
  fg "$r" "$g" "$b"
}

# row <label> <pct> [suffix] [width=10] -> "label ━━━━━━━━━━ 42% suffix" (1 cell = 10%)
row() {
  local label=$1 pct=$2 suffix=$3 width=${4:-10} filled i col out=""
  printf '%s%-4s%s' "$C_LABEL" "$label" "$RST"
  if [ -z "$pct" ]; then printf '%sn/a%s' "$C_LABEL" "$RST"; return; fi
  pct=$(printf '%.0f' "$pct")
  filled=$(( (pct * width + 50) / 100 )); [ "$filled" -gt "$width" ] && filled=$width
  if [ "$label" = "ctx" ]; then   # ctx: per-cell gradient, so it never looks like 5h/7d
    for ((i=0; i<width; i++)); do
      if [ "$i" -lt "$filled" ]; then col=$(grad "$i" "$width"); out+="${col}•"; else out+="${C_TRACK}•"; fi
    done
    col=$(grad $(( filled > 0 ? filled - 1 : 0 )) "$width")
  else
    col=$(level_color "$pct")
    for ((i=0; i<width; i++)); do
      if [ "$i" -lt "$filled" ]; then out+="${col}━"; else out+="${C_TRACK}━"; fi
    done
  fi
  printf '%s%s %s%s%s%%%s' "$out" "$RST" "$col" "$BOLD" "$pct" "$RST"
  [ -n "$suffix" ] && printf ' %s%s%s' "$C_LABEL" "$suffix" "$RST"
}

rel() {  # epoch -> "2d 5h" / "2h 13m" / "12m"
  [ -z "$1" ] && return
  local s=$(( $1 - $(date +%s) )) d h m
  [ "$s" -le 0 ] && { printf 'now'; return; }
  d=$((s/86400)); h=$((s%86400/3600)); m=$((s%3600/60))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else                      printf '%dm' "$m"; fi
}

at() {  # epoch -> "14:30" (today) / "Sat 14:30" (other day), local time
  [ -z "$1" ] && return
  if [ "$(date -d "@$1" +%Y%m%d)" = "$(date +%Y%m%d)" ]; then date -d "@$1" +%H:%M
  else date -d "@$1" '+%a %H:%M'; fi
}

reset_hint() {  # epoch -> "2h 13m (14:30)" / "2d 4h (Sat 14:30)"
  [ -z "$1" ] && return
  printf '%s (%s)' "$(rel "$1")" "$(at "$1")"
}

human() {  # 6123 -> 6k, 1200000 -> 1.2M
  local n=${1:-0}
  if   [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
  elif [ "$n" -ge 1000 ];    then printf '%dk' $((n/1000))
  else printf '%d' "$n"; fi
}

# ---------- data ----------
model=$(j '.model.display_name // "?"')
effort=$(j '.effort.level // empty')
ctx=$(j '.context_window.used_percentage // 0' | cut -d. -f1)
h5=$(j '.rate_limits.five_hour.used_percentage // empty')
h5r=$(j '.rate_limits.five_hour.resets_at // empty')
d7=$(j '.rate_limits.seven_day.used_percentage // empty')
d7r=$(j '.rate_limits.seven_day.resets_at // empty')

ctx_used=$(j '.context_window.total_input_tokens // 0')
ctx_size=$(j '.context_window.context_window_size // 0')
added=$(j '.cost.total_lines_added // 0')
removed=$(j '.cost.total_lines_removed // 0')
hit=$(j '.prompt_cache.hit_ratio // empty')
warm=$(j '.prompt_cache.warm // empty')
fast=$(j '.fast_mode // false')
pr=$(j '.pr.number // empty')

cwd=$(j '.workspace.current_dir // .cwd // "."')
branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

# jq program: find the latest completed response in the transcript and compute
# output_tokens / (end time of its last block - time of its parent entry)
read -r -d '' TPS_JQ <<'JQEOF'
def ts: (.[0:19] + "Z") as $s | ($s | fromdateiso8601) + (if (.|length) > 20 then ((.[20:23] | tonumber) / 1000) else 0 end);
. as $all
| ($all | map(select(.type=="assistant" and .message.stop_reason != null))) as $done
| if ($done|length)==0 then empty else
  ($done | last | .message.id) as $id
  | ($done | map(select(.message.id==$id))) as $blocks
  | ($all | map(select(.uuid==$blocks[0].parentUuid)) | first) as $parent
  | ($blocks | last | .timestamp | ts) as $end
  | ($parent.timestamp | ts) as $start
  | ($blocks[0].message.usage.output_tokens) as $out
  | {out:$out, secs:($end-$start), tps:($out/($end-$start))} end
JQEOF

# tps: measured from the session transcript (real timestamps + real output_tokens of the
# latest completed response; includes thinking tokens and time-to-first-token)
tp=$(j '.transcript_path // empty'); tps=""
if [ -n "$tp" ] && [ -r "$tp" ]; then
  r=$(tail -n 200 "$tp" | jq -s -c "$TPS_JQ" 2>/dev/null)
  [ -n "$r" ] && tps=$(echo "$r" | jq -r '.tps | floor')
fi

# ---------- line 1: header ----------
l1="${C_MODEL}${BOLD}${model}${RST}"
[ -n "$effort" ] && l1+="${SEP}${C_TEXT}${effort}${RST}"
[ -n "$tps" ] && l1+="${SEP}${C_SPEED}${tps} tok/s${RST}"
l1+="${SEP}${C_BRANCH}⎇ ${branch:-no git}${RST}"
if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
  l1+="${SEP}${C_BLUE}+${added}${RST} ${C_PINK}−${removed}${RST}"
fi
[ -n "$pr" ] && l1+="${SEP}${C_BRANCH}PR #${pr}${RST}"
[ "$fast" = "true" ] && l1+="${SEP}${C_WHITE}⚡fast${RST}"

# ---------- lines 2-4: aligned bars ----------
ctx_extra=""
[ "$ctx_size" -gt 0 ] && ctx_extra="$(human "$ctx_used")/$(human "$ctx_size")"
if [ -n "$hit" ]; then
  hp=$(awk -v h="$hit" 'BEGIN{printf "%d", h*100+0.5}')
  if   [ "$hp" -ge 80 ]; then hc=$C_OK; elif [ "$hp" -ge 50 ]; then hc=$C_WARN; else hc=$C_BAD; fi
  [ -n "$ctx_extra" ] && ctx_extra+="${RST}${SEP}"
  ctx_extra+="${C_LABEL}cache ${hc}${hp}%${RST}"
  [ "$warm" = "false" ] && ctx_extra+="${C_LABEL} (cold)${RST}"
fi
l2=$(row ctx "$ctx" "$ctx_extra")
# 5h and 7d share one line; every bar (ctx/5h/7d) is 10 cells, 1 cell = 10%
SEP2="${C_LABEL} | ${RST}"
l3="$(row 5h "$h5" "$(reset_hint "$h5r")")${SEP2}$(row 7d "$d7" "$(reset_hint "$d7r")")"

printf '%s\n%s\n%s\n' "$l1" "$l2" "$l3"
