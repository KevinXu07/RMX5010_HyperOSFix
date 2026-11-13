#!/system/bin/sh
# Adaptive game frame rate, chosen from the game's measured frame rate.
#
# Why this exists (see docs/游戏24fps诊断_ACE与帧率策略.md):
#   On this port the frame rate is decided by HyperOS' own SurfaceFlinger
#   strategy (ro.display.move_frame_rate_strategy_up=true; SF ignores the
#   DisplayManager policy from boot, debugDisplayModeSetByDebugEnhance=true).
#   It follows what the content draws and locks itself there: a game idling
#   in a lobby is dropped to 24Hz (heavier games then fall to the teens), and
#   a 120fps game standing still is dropped to 60Hz although it renders 124fps
#   as soon as it is allowed to.  Only touch lifts it, for the touch timer.
#
# Policy (no package list, no fixed 60/90/120 table):
#   * render tiers are read from SurfaceFlinger (mAppRequestFrameRates);
#   * while a foreground game runs at the top tier, its real frame rate is
#     measured from SF frame timestamps (--latency); the highest value is
#     remembered per package in $LEARN;
#   * a game's tier is the smallest tier >= 0.9 x its measured rate, never
#     below the floor (60).  When the game runs below 0.9 x its tier for 5s
#     (or below 30Hz when its rate is not known yet, after a 2s probe at the
#     top tier) the tier is enforced:
#       - top tier: SurfaceFlinger backdoor 1035 pins the top display mode
#         while the game is in the foreground; 1036 1 hands control back to
#         the dynamic strategy when it leaves (same-resolution modes only);
#       - lower tiers: GameManager custom frame rate, which SF honours as a
#         vote for the game's layers (lifts the 24Hz lock to 60);
#   * a game capped below the top tier that saturates its cap is re-probed
#     (every 30s, backing off to 5 min), so a menu measured at 60 does not cap
#     the 120fps gameplay that follows;
#   * packages set by this script are listed in $MANAGED and stay managed
#     across sessions; any other custom mode is the user's and left alone,
#     except a GameManager custom Fps:60 left by 1.4.1-1.7.20, reset once.
#
# Optional overrides in /data/adb/rmx5010_game_fps.conf:
#   package:fps    fixed tier for one game, e.g. com.example.game:120
#   package:off    never touch this game
#   default:fps    floor for every other game, default 60
MODDIR=${0%/*}
LOG="$MODDIR/game_fps.log"
CONF=/data/adb/rmx5010_game_fps.conf
LEARN=/data/adb/rmx5010_game_fps.learned
MANAGED=/data/adb/rmx5010_game_fps.managed
MIGRATED=/data/adb/rmx5010_game_fps.migrated
PIN_STATE="$MODDIR/.game_fps_pinned"
NON_GAME_LIST=""

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

# conf_value <package|default>: value from $CONF, empty if absent.
conf_value() {
  [ -f "$CONF" ] || return
  sed -n "s/^$1:\([0-9a-z]*\).*/\1/p" "$CONF" | head -n 1
}

# kv_get <file> <package> / kv_set <file> <package> [value]
kv_get() {
  [ -f "$1" ] || return
  sed -n "s/^$2:\([0-9]*\)$/\1/p" "$1" | head -n 1
}

kv_set() {
  if [ -f "$1" ]; then
    grep -v "^$2:" "$1" > "$1.tmp" 2>/dev/null
    mv -f "$1.tmp" "$1"
  fi
  [ -n "$3" ] && echo "$2:$3" >> "$1"
}

# 0 = game (mode printed), 2 = not a game.  stdout is the current mode.
game_mode() {
  out=$(cmd game list-modes "$1" 2>&1)
  case "$out" in
    *"is not of game type"*) return 2 ;;
    *"current mode:"*)
      printf '%s\n' "$out" \
        | sed -n 's/.*current mode: \([a-z]*\).*/\1/p' | head -n 1
      return 0
      ;;
  esac
  return 2
}

uid_for() {
  dumpsys package "$1" 2>/dev/null \
    | sed -n 's/^    uid=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# SF's per-UID render rate for the game, e.g. 24.00.
sf_rate_for() {
  [ -n "$1" ] || return
  dumpsys SurfaceFlinger 2>/dev/null \
    | grep -oE "\(uid, frameRate\)=\{$1, [0-9.]+" \
    | head -n 1 | sed 's/.*, //'
}

# Render tiers SurfaceFlinger can give an app, ascending integers.
load_tiers() {
  dumpsys SurfaceFlinger 2>/dev/null \
    | sed -n 's/.*mAppRequestFrameRates\[[0-9]*\]=fps=\([0-9.]*\) Hz.*/\1/p' \
    | awk '{ printf "%d\n", $1 + 0.5 }' | sort -n -u | tr '\n' ' '
}

# Smallest tier >= 0.9 x measured fps, never below the floor.
tier_for() {
  for t in $TIERS; do
    [ "$t" -ge "$FLOOR" ] || continue
    if awk -v t="$t" -v m="$1" 'BEGIN { exit !(t >= m * 0.9) }'; then
      echo "$t"
      return
    fi
  done
  echo "$TOP"
}

below() {  # below <rate> <tier>: rate < 0.9 x tier (empty rate counts)
  [ -n "$1" ] || return 0
  awk -v r="$1" -v t="$2" 'BEGIN { exit !(r < t * 0.9) }'
}

# GameManager value for a tier.  SF ignores a value equal (or within ~1Hz)
# to the top tier because it matches game_default_frame_rate_override, so
# ask for one between the top two tiers that SF still rounds up.
gm_value() {
  if [ "$1" -ge "$TOP" ]; then
    echo $((TOP - (TOP - NEXT) / 3))
  else
    echo "$1"
  fi
}

# Display mode id of the top tier at the current resolution.
top_mode_id() {
  # (no "$(dumpsys)" in a variable: printf is not a builtin in mksh and the
  # dump exceeds the argument size limit)
  dumpsys SurfaceFlinger 2>/dev/null \
    | sed -n '/^Pacesetter Display/,/displayManagerPolicy/p' \
    | awk -v top="$TOP" '
        /activeMode=\{/ { if (match($0, /resolution=[0-9x]+/))
                            res = substr($0, RSTART + 11, RLENGTH - 11) }
        /^ *\{id=/      { modes[++n] = $0 }
        END { for (i = 1; i <= n; i++) {
                if (index(modes[i], "resolution=" res ",") \
                    && index(modes[i], "vsyncRate=" top ".")) {
                  match(modes[i], /\{id=[0-9]+/)
                  print substr(modes[i], RSTART + 4, RLENGTH - 4); exit } } }'
}

# Pin the top display mode (SF backdoor 1035).  1036 0 first, so a previous
# "all rates" override does not mask the pinned policy.
pin() {
  [ -f "$PIN_STATE" ] && return 0
  id=$(top_mode_id)
  [ -n "$id" ] || { log "pin $1: no ${TOP}Hz mode found"; return 1; }
  service call SurfaceFlinger 1036 i32 0 >/dev/null 2>&1
  out=$(service call SurfaceFlinger 1035 i32 "$id" 2>&1)
  case "$out" in
    *Error*)
      service call SurfaceFlinger 1036 i32 1 >/dev/null 2>&1
      log "pin $1 failed: $out"
      return 1
      ;;
  esac
  echo "$1" > "$PIN_STATE"
  return 0
}

# Give the frame rate back to the dynamic strategy: override policy that
# allows every rate of the current resolution (what SF had from boot).
unpin() {
  [ -f "$PIN_STATE" ] || return 0
  service call SurfaceFlinger 1036 i32 1 >/dev/null 2>&1
  rm -f "$PIN_STATE"
}

# enforce <package> <tier> [probe]: GameManager value for the tier (records
# the package as ours unless probing) plus the SF pin for the top tier.
enforce() {
  v=$(gm_value "$2")
  out=$(cmd game set --fps "$v" "$1" 2>&1)
  case "$out" in
    *"fps-override"*) ;;
    *) log "GameManager fps $v for $1 failed: $out"; return 1 ;;
  esac
  [ "$3" = probe ] || kv_set "$MANAGED" "$1" "$2"
  if [ "$2" -ge "$TOP" ]; then
    pin "$1"
  else
    unpin
  fi
}

release() {
  unpin
  cmd game reset "$1" >/dev/null 2>&1
  kv_set "$MANAGED" "$1"
}

# Buffer layers belonging to a package, one name per line.
game_layers() {
  dumpsys SurfaceFlinger --list 2>/dev/null | while IFS= read -r l; do
    case "$l" in
      *"$1"*) ;;
      *) continue ;;
    esac
    case "$l" in
      RequestedLayerState\{*)
        l=${l#RequestedLayerState\{}
        l=${l%% parentId=*}
        l=${l%\}}
        ;;
    esac
    case "$l" in
      *"(BLAST)"*|*SurfaceView*|VRI-*|*"/"*) echo "$l" ;;
    esac
  done
}

# measure_fps <package> <seconds>: frames actually presented per second by
# the busiest layer of the package over the window (integer, 0 if none).
measure_fps() {
  layers=$(game_layers "$1")
  [ -n "$layers" ] || { echo 0; return; }
  printf '%s\n' "$layers" | while IFS= read -r l; do
    dumpsys SurfaceFlinger --latency-clear "$l" >/dev/null 2>&1
  done
  sleep "$2"
  printf '%s\n' "$layers" | while IFS= read -r l; do
    dumpsys SurfaceFlinger --latency "$l" 2>/dev/null \
      | awk 'NR > 1 && $2 > 0 && $2 < 9e18 { n++; if (!f) f = $2; l = $2 }
             END { if (n > 2 && l > f) printf "%d\n", (n - 1) / ((l - f) / 1e9) + 0.5;
                   else print 0 }'
  done | sort -n | tail -n 1
}

# probe <package>: fps measured with the top tier enforced (not recorded).
probe() {
  enforce "$1" "$TOP" probe || { echo 0; return; }
  sleep 1
  measure_fps "$1" 2
}

# One-time cleanup of the GameManager custom Fps:60 written by 1.4.1-1.7.20.
migrate_legacy_custom() {
  grep -qxF "$1" "$MIGRATED" 2>/dev/null && return 1
  echo "$1" >> "$MIGRATED"
  [ -n "$(conf_value "$1")" ] && return 1
  cfg=$(cmd game list-configs "$1" 2>&1)
  case "$cfg" in
    *"Scaling:-1.0"*"Fps:60,"*)
      cmd game reset "$1" >/dev/null 2>&1
      log "reset legacy GameManager custom 60 for $1"
      return 0
      ;;
  esac
  return 1
}

i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ] && [ $i -lt 180 ]; do
  sleep 1
  i=$((i+1))
done
sleep 2

# A restart of this script (module update) must not leave a pinned mode.
unpin

TIERS=$(load_tiers)
[ -n "$TIERS" ] || TIERS="60 120"
TOP=$(echo $TIERS | awk '{ print $NF }')
NEXT=$(echo $TIERS | awk '{ print (NF > 1) ? $(NF - 1) : $NF }')
FLOOR=$(conf_value default)
case "$FLOOR" in ''|*[!0-9]*) FLOOR=60 ;; esac
log "adaptive game fps watch (tiers: $TIERS; top ${TOP}Hz pinned via SF 1035; floor $FLOOR)"

last_pkg=
state=
low_since=0
uid=
cap=0
last_measure=0
last_probe=0
probe_every=30

while true; do
  pkg=$(dumpsys window 2>/dev/null \
    | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' \
    | head -n 1)

  if [ "$pkg" != "$last_pkg" ]; then
    if [ -f "$PIN_STATE" ]; then
      unpin
      log "unpin: $last_pkg left the foreground"
    fi
    last_pkg=$pkg
    state=pending
    low_since=0
    uid=
    cap=0
    probe_every=30
  fi

  if [ -z "$pkg" ]; then
    sleep 2
    continue
  fi

  case " $NON_GAME_LIST " in
    *" $pkg "*)
      sleep 5
      continue
      ;;
  esac

  mode=$(game_mode "$pkg")
  rc=$?
  if [ "$rc" = 2 ]; then
    NON_GAME_LIST="$NON_GAME_LIST $pkg"
    state=nongame
    sleep 5
    continue
  fi
  if [ "$state" = nongame ]; then
    sleep 5
    continue
  fi

  fixed=$(conf_value "$pkg")
  case "$fixed" in off|'') ;; *[!0-9]*) fixed= ;; esac
  mine=$(kv_get "$MANAGED" "$pkg")
  if [ "$fixed" = off ]; then
    if [ "$state" != off ]; then
      [ -n "$mine" ] && release "$pkg"
      log "leave $pkg: off in conf"
      state=off
    fi
    sleep 5
    continue
  fi

  now=$(date +%s)

  if [ "$mode" = custom ]; then
    if [ -z "$mine" ]; then
      migrate_legacy_custom "$pkg" && continue
      if [ "$state" != custom ]; then
        log "leave $pkg: GameManager custom mode set by user"
        state=custom
      fi
      sleep 5
      continue
    fi
    # Ours: carry on from the tier set earlier (also across reboots).
    if [ "$state" != managed ]; then
      cap=$mine
      last_probe=$now
      state=managed
      enforce "$pkg" "$cap" && log "keep $pkg at ${cap}Hz"
    fi
    # Capped below the top tier and running flat out against the cap?
    # Lift the cap briefly to see whether the game can go faster.
    if [ -z "$fixed" ] && [ "$cap" -lt "$TOP" ] \
       && [ $((now - last_probe)) -ge "$probe_every" ]; then
      last_probe=$now
      m=$(measure_fps "$pkg" 2)
      if awk -v m="$m" -v c="$cap" 'BEGIN { exit !(m >= c * 0.9) }'; then
        m=$(probe "$pkg")
        t=$(tier_for "$m")
        if [ "$t" -gt "$cap" ]; then
          kv_set "$LEARN" "$pkg" "$m"
          log "raise $pkg to ${t}Hz: measured ${m}fps above the ${cap}Hz cap"
          cap=$t
        elif [ "$probe_every" -lt 300 ]; then
          # Really a ${cap}fps game: probe less and less often (max 5 min).
          probe_every=$((probe_every * 2))
        fi
        enforce "$pkg" "$cap"
      fi
    fi
    sleep 5
    continue
  fi

  # Standard mode but listed as ours: cleared by the user or the system.
  if [ -n "$mine" ]; then
    kv_set "$MANAGED" "$pkg"
    unpin
  fi
  case "$state" in custom|managed) state=pending ;; esac

  [ -n "$uid" ] || uid=$(uid_for "$pkg")
  rate=$(sf_rate_for "$uid")
  learned=$(kv_get "$LEARN" "$pkg")
  if [ -n "$fixed" ]; then
    want=$(tier_for "$((fixed * 10 / 9))")
  elif [ -n "$learned" ]; then
    want=$(tier_for "$learned")
  else
    want=30   # unknown game: only a lock below 30Hz counts
  fi

  # Running at the top tier: learn the game's real frame rate.
  if [ -n "$rate" ] \
     && awk -v r="$rate" -v t="$TOP" 'BEGIN { exit !(r >= t * 0.9) }' \
     && [ $((now - last_measure)) -ge 10 ]; then
    last_measure=$now
    m=$(measure_fps "$pkg" 2)
    if [ "$m" -gt "${learned:-0}" ]; then
      kv_set "$LEARN" "$pkg" "$m"
      log "learn $pkg: ${m}fps at ${rate}Hz (was ${learned:-none})"
    fi
  fi

  if ! below "$rate" "$want"; then
    if [ "$state" != native ]; then
      log "observe $pkg: ${rate}Hz (tier ${want}Hz)"
      state=native
    fi
    low_since=0
    sleep 2
    continue
  fi

  # Below its tier: wait 5s to skip loading transitions and touch gaps.
  [ "$low_since" -gt 0 ] || low_since=$now
  if [ $((now - low_since)) -lt 5 ]; then
    sleep 1
    continue
  fi

  if [ -n "$fixed" ]; then
    target=$want
    why="conf $fixed"
  elif [ -n "$learned" ]; then
    target=$want
    why="learned ${learned}fps"
  else
    m=$(probe "$pkg")
    kv_set "$LEARN" "$pkg" "$m"
    target=$(tier_for "$m")
    why="probed ${m}fps"
  fi

  if enforce "$pkg" "$target"; then
    cap=$target
    last_probe=$(date +%s)
    log "apply $pkg ${target}Hz ($why; was ${rate:-none}Hz)"
    state=managed
  fi
  sleep 5
done
