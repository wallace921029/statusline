
#!/usr/bin/env bash
# Antigravity CLI (agy) status line (5 aligned lines, truecolor, trans flag palette):
#   Gemini 4 Argon | high | 70 tok/s | ⎇ main | +12 -3
#   ctx       ••••••••••  12% 117k/1.0M | cache 98%
#   argon 7d  ━━━━━━━━━━  11% 6d 19h (Wed 14:00)
#   gem   5h  ━━━━━━━━━━   0% 4h 57min (18:59) | 7d ━━━━━━━━━━   0% 6d  0h (Tue 11:14)
#   3p    5h  ━━━━━━━━━━   0% 4h 57min (18:59) | 7d ━━━━━━━━━━   0% 6d 23h (Wed 13:59)

export LC_TIME=C
export LC_NUMERIC=C
input=$(cat)

# ---------- palette (truecolor) ----------
RST=$'\033[0m'; BOLD=$'\033[1m'
fg() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
DIM=$'\033[2;37m'            # dim white: plain text (labels, separators, hints)
C_LABEL=$DIM
C_TRACK=$(fg 55 60 72)       # dark   : empty part of bars
C_BLUE=$(fg 91 206 250)      # trans flag light blue  #5BCEFA
C_PINK=$(fg 245 169 184)     # trans flag pink        #F5A9B8
C_WHITE=$(fg 255 255 255)    # trans flag white
C_TEXT=$DIM
C_MODEL=$C_PINK
C_BRANCH=$C_BLUE
C_SPEED=$C_BLUE
C_ADD=$(fg 120 215 140)      # soft green for git additions
C_DEL=$(fg 245 130 140)      # soft red for git deletions
# quota level colors: <60% blue, 60-89% pink, >=90% white
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

human() {  # 6123 -> 6k, 1048576 -> 1.0M
  local n=${1:-0}
  if   [ "$n" -ge 1000000 ]; then LC_NUMERIC=C awk -v n="$n" 'BEGIN{printf "%.1fM", n/1000000}'
  elif [ "$n" -ge 1000 ];    then printf '%dk' $((n/1000))
  else printf '%d' "$n"; fi
}

# ctx row: 9-char prefix ("ctx      ") + 10-dot gradient bar (1 dot = 10%)
ctx_row() {
  local pct=$1 suffix=$2 width=10 filled i col out=""
  printf '%s%-9s%s' "$C_LABEL" "ctx" "$RST"
  if [ -z "$pct" ] || [ "$pct" = "null" ]; then printf '%sn/a%s' "$C_LABEL" "$RST"; return; fi
  pct=$(LC_NUMERIC=C printf '%.0f' "$pct")
  filled=$(( (pct * width + 50) / 100 )); [ "$filled" -gt "$width" ] && filled=$width
  for ((i=0; i<width; i++)); do
    if [ "$i" -lt "$filled" ]; then col=$(grad "$i" "$width"); out+="${col}•"; else out+="${C_TRACK}•"; fi
  done
  col=$(grad $(( filled > 0 ? filled - 1 : 0 )) "$width")
  printf '%s%s %s%s%3s%%%s' "$out" "$RST" "$col" "$BOLD" "$pct" "$RST"
  [ -n "$suffix" ] && printf ' %s%s%s' "$C_LABEL" "$suffix" "$RST"
}

# quota segment: <prefix_label> <used_pct> <rstr> [pad_reset] (width=10, 1 cell = 10%)
quota_seg() {
  local label=$1 pct=$2 rstr=$3 pad=${4:-0} width=10 filled i col out=""
  printf '%s%s%s' "$C_LABEL" "$label" "$RST"
  if [ -z "$pct" ] || [ "$pct" = "null" ]; then
    if [ "$pad" -eq 1 ]; then
      printf '%s%-32s%s' "$C_LABEL" "n/a" "$RST"
    else
      printf '%sn/a%s' "$C_LABEL" "$RST"
    fi
    return
  fi
  pct=$(LC_NUMERIC=C printf '%.0f' "$pct")
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  filled=$(( (pct * width + 50) / 100 )); [ "$filled" -gt "$width" ] && filled=$width
  col=$(level_color "$pct")
  for ((i=0; i<width; i++)); do
    if [ "$i" -lt "$filled" ]; then out+="${col}━"; else out+="${C_TRACK}━"; fi
  done
  printf '%s%s %s%s%3s%%%s' "$out" "$RST" "$col" "$BOLD" "$pct" "$RST"
  if [ "$pad" -eq 1 ]; then
    printf ' %s%-16s%s' "$C_LABEL" "$rstr" "$RST"
  elif [ -n "$rstr" ]; then
    printf ' %s%s%s' "$C_LABEL" "$rstr" "$RST"
  fi
}

# ---------- single-pass jq extraction ----------
eval "$(
  echo "$input" | jq -r '
    def used_pct(b):
      if b == null or b.remaining_fraction == null then ""
      else ((1 - b.remaining_fraction) * 100 | if . < 0 then 0 elif . > 100 then 100 else . end | tostring)
      end;
    def p2: tostring | if length < 2 then " " + . else . end;
    def fmt_rst(b; is_7d):
      if b == null then ""
      else
        (if b.reset_in_seconds != null then b.reset_in_seconds
         elif b.reset_time != null then (((b.reset_time | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - now) | floor)
         else null end) as $s |
        if $s == null then ""
        elif $s <= 0 then "now"
        else
          ($s / 86400 | floor) as $d |
          ((if is_7d then ($s % 86400) else $s end) / 3600 | floor) as $h |
          (($s % 3600) / 60 | floor) as $m |
          (if is_7d and $d > 0 then "\($d)d \($h | p2)h"
           elif $s < 60 then "   <1min"
           else "\($h)h \($m | p2)min" end) +
          " (" + ((now + $s) | strflocaltime(if is_7d then "%a %H:%M" else "%H:%M" end)) + ")"
        end
      end;
    (.quota["gemini-argon-wtu-weekly"] // (.quota // {} | to_entries | map(select(.key | test("argon"))) | first | .value)) as $argon |
    @sh "
      raw_model=\(.model.display_name // "?")
      effort=\(.model.effort // "")
      state=\(.agent_state // "idle")
      cycle_mode=\(.cycle_mode // "")
      confirm=\(.tool_confirmation_pending // false)
      ctx=\(.context_window.used_percentage // 0)
      ctx_total_in=\(.context_window.total_input_tokens // 0)
      ctx_size=\(.context_window.context_window_size // 0)
      cur_in=\(.context_window.current_usage.input_tokens // 0)
      cur_cache=\(.context_window.current_usage.cache_read_input_tokens // 0)
      cwd=\(.workspace.current_dir // .cwd // ".")
      vcs_branch=\(.vcs.branch // "")
      tp=\(.transcript_path // "")
      tasks=\(.task_count // 0)
      sub_running=\([.subagents // [] | .[] | select(.status == "running")] | length)
      gem5_pct=\(used_pct(.quota["gemini-5h"]))
      gem5_rst=\(fmt_rst(.quota["gemini-5h"]; false))
      gem7_pct=\(used_pct(.quota["gemini-weekly"]))
      gem7_rst=\(fmt_rst(.quota["gemini-weekly"]; true))
      arg7_pct=\(used_pct($argon))
      arg7_rst=\(fmt_rst($argon; true))
      tp5_pct=\(used_pct(.quota["3p-5h"]))
      tp5_rst=\(fmt_rst(.quota["3p-5h"]; false))
      tp7_pct=\(used_pct(.quota["3p-weekly"]))
      tp7_rst=\(fmt_rst(.quota["3p-weekly"]; true))
    "
  ' 2>/dev/null
)"

# Clean model name & extract effort fallback if embedded in display_name (e.g., "Gemini 4 Argon (High)")
model="$raw_model"
if [[ "$raw_model" =~ ^(.*)[[:space:]]\((Low|Medium|High|Max)\)$ ]]; then
  model="${BASH_REMATCH[1]}"
  [ -z "$effort" ] && effort=$(echo "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')
fi

# Git branch fallback if .vcs.branch is empty
branch="$vcs_branch"
if [ -z "$branch" ] && [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null || true)
fi

# Git diff stats (+added -deleted)
git_diff=""
if [ -n "$branch" ] && [ -n "$cwd" ]; then
  diff_stat=$(git -C "$cwd" diff HEAD --numstat 2>/dev/null || git -C "$cwd" diff --cached --numstat 2>/dev/null || git -C "$cwd" diff --numstat 2>/dev/null || true)
  read -r added removed < <(echo "$diff_stat" | awk '{a+=$1; r+=$2} END {print a+0, r+0}')
  added=${added:-0}
  removed=${removed:-0}
  c_add="$DIM"; [ "$added" -gt 0 ] && c_add="$C_ADD"
  c_del="$DIM"; [ "$removed" -gt 0 ] && c_del="$C_DEL"
  git_diff="${c_add}+${added}${RST} ${c_del}-${removed}${RST}"
fi

# ---------- real tok/s from agy transcript.jsonl ----------
if [ -n "$tp" ] && [ ! -r "$tp" ]; then
  tp="${tp/\/.gemini\/antigravity\//\/.gemini\/antigravity-cli\/}"
fi

read -r -d '' TPS_JQ <<'JQEOF'
def ts: (.[0:19] + "Z") | fromdateiso8601;
. as $all
| [ range(0; $all | length) as $i
    | ($all[$i]) as $cur
    | select($cur.type == "PLANNER_RESPONSE" and ($cur.output_tokens // 0) > 0 and $cur.created_at != null)
    | ($cur.created_at | ts) as $start
    | (if ($i + 1) < ($all | length) and $all[$i + 1].type == "GENERIC" and $all[$i + 1].created_at != null then
         ($all[$i + 1].created_at | ts)
       elif ($i + 1) == ($all | length) and $mtime > $start then
         $mtime
       else
         null
       end) as $end
    | select($end != null and ($end - $start) > 0)
    | (($cur.output_tokens) / ($end - $start) | floor)
  ]
| last // empty
JQEOF

tps=""
if [ -n "$tp" ] && [ -r "$tp" ]; then
  mtime=$(stat -c %Y "$tp" 2>/dev/null || stat -f %m "$tp" 2>/dev/null || echo 0)
  tps=$(tail -n 120 "$tp" | jq -s -r --argjson mtime "${mtime:-0}" "$TPS_JQ" 2>/dev/null || true)
fi

# ---------- line 1: header ----------
l1="${C_MODEL}${BOLD}${model}${RST}"
[ -n "$effort" ] && l1+="${SEP}${C_TEXT}${effort}${RST}"
[ -n "$tps" ] && l1+="${SEP}${C_SPEED}${tps} tok/s${RST}"
l1+="${SEP}${C_BRANCH}⎇ ${branch:-no git}${RST}"
[ -n "$git_diff" ] && l1+="${SEP}${git_diff}"
[ -n "$cycle_mode" ] && l1+="${SEP}${C_TEXT}${cycle_mode}${RST}"
if [ "${sub_running:-0}" -gt 0 ]; then
  l1+="${SEP}${C_BLUE}${sub_running} sub${RST}"
fi
if [ "${tasks:-0}" -gt 0 ]; then
  l1+="${SEP}${C_BLUE}${tasks} task${RST}"
fi
if [ "$confirm" = "true" ]; then
  l1+="${SEP}${C_PINK}${BOLD}⚠ confirm${RST}"
fi

# ---------- line 2: ctx ----------
ctx_extra=""
ctx_used=$(( cur_in + cur_cache ))
[ "$ctx_used" -le 0 ] && ctx_used=${ctx_total_in:-0}
if [ "${ctx_size:-0}" -gt 0 ]; then
  ctx_extra="$(human "$ctx_used")/$(human "$ctx_size")"
fi
if [ $(( cur_in + cur_cache )) -gt 0 ]; then
  hp=$(( (cur_cache * 100 + (cur_in + cur_cache) / 2) / (cur_in + cur_cache) ))
  if   [ "$hp" -ge 80 ]; then hc=$C_OK; elif [ "$hp" -ge 50 ]; then hc=$C_WARN; else hc=$C_BAD; fi
  [ -n "$ctx_extra" ] && ctx_extra+="${RST}${SEP}"
  ctx_extra+="${C_LABEL}cache ${hc}${hp}%${RST}"
fi
l2=$(ctx_row "$ctx" "$ctx_extra")

# ---------- line 3: argon (7d standalone row above gem) ----------
l3=$(quota_seg "argon 7d " "$arg7_pct" "$arg7_rst")

# ---------- line 4: gem (5h + 7d) ----------
l4=$(printf '%s%s%s' \
  "$(quota_seg "gem   5h " "$gem5_pct" "$gem5_rst" 1)" \
  "$SEP" \
  "$(quota_seg "7d " "$gem7_pct" "$gem7_rst")")

# ---------- line 5: 3p (5h + 7d) ----------
l5=$(printf '%s%s%s' \
  "$(quota_seg "3p    5h " "$tp5_pct" "$tp5_rst" 1)" \
  "$SEP" \
  "$(quota_seg "7d " "$tp7_pct" "$tp7_rst")")

printf '%s\n%s\n%s\n%s\n%s\n' "$l1" "$l2" "$l3" "$l4" "$l5"
