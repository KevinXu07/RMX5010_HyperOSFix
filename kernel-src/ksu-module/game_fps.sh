#!/system/bin/sh
# Adaptive game frame-rate floor, chosen from the game's measured frame rate.
#
# Why this exists (see docs/游戏24fps诊断_ACE与帧率策略.md):
#   On this port HyperOS' SurfaceFlinger drops the whole display render rate to
#   24Hz while some games sit in a menu/lobby, although the game layer carries
#   no explicit frame-rate request (renderFrameRate=24, frameRateOverrides=[]).
#   The game's Choreographer then only gets 24 vsyncs/s; heavier games that
#   miss those slots fall to the teens.  Touch boosts it back to 120Hz for the
#   touch timer, then it falls again.
#
# Policy (no package list, no fixed 60/90/120 table):
#   * render tiers are read from SurfaceFlinger (mAppRequestFrameRates);
#   * while a foreground game runs at the top tier uncapped, its real frame
#     rate is measured from SF frame timestamps (--latency) and the highest
#     value is remembered per package in $LEARN;
#   * when the game is locked below 30Hz for 5s, it gets a GameManager custom
#     frame rate for the smallest tier >= 0.9 x its measured rate, never below
#     the floor (60).  A game never measured yet is first probed for 2s at the
#     top tier;
#   * GameManager is the only lever that raises the rate: its override acts as
#     a vote for the game's layers.  The SF backdoor (1039) only throttles.
#     A GameManager value equal (or within ~1Hz) to the top tier is ignored by
#     SF because it matches ro.surface_flinger.game_default_frame_rate_override,
#     so the top tier is requested as top - (top - next tier) / 3 (100 for
#     60/120), which SF rounds to the top tier without capping the game;
#   * while capped below the top tier, a game that saturates its cap is
#     re-probed (every 30s, backing off to 5 min), so a menu measured at 60 does not cap the 120fps
#     gameplay that follows;
#   * packages set by this script are listed in $MANAGED and stay managed
#     across sessions; any other custom mode is the user's and left alone,
#     except a GameManager custom Fps:60 left by 1.4.1-1.7.20, reset once.
#
# Optional overrides in /data/adb/rmx5010_game_fps.conf:
#   package:fps    fixed floor for one game, e.g. com.example.game:120
#   package:off    never touch this game
#   default:fps    floor for every other game, default 60
MODDIR=${0%/*}
LOG="$MODDIR/game_fps.log"
CONF=/data/adb/rmx5010_game_fps.conf
LEARN=/data/adb/rmx5010_game_fps.learned
MANAGED=/data/adb/rmx5010_game_fps.managed
MIGRATED=/data/adb/rmx5010_game_fps.migrated
NON_GAME_LIST=""

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

# conf_value <package|default>: value from $CONF, empty if absent.
conf_value() {
  [ -f "$CONF" ] || return
  sed -n "s/^$1:\([0-9a-z]*\).*/\1/p" "$CONF" | head -n 1
}

# kv_get <file> <package> / kv_set <file> <package> <value>
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

# SF's per-UID render rate for the game (content/touch driven), e.g. 24.00.
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

# GameManager value that makes SF pick <tier>.  The top tier itself is
# ignored by SF (same as game_default_frame_rate_override), so ask for a
# value between the top two tiers that SF still rounds up to the top.
gm_value() {
  if [ "$1" -ge "$TOP" ]; then
    echo $((TOP - (TOP - NEXT) / 3))
  else
    echo "$1"
  fi
}

# set_tier <package> <tier> [probe]: GameManager custom frame rate for that
# tier.  A probe is not recorded, so being killed mid-probe cannot leave the
# temporary top tier behind as the game's setting.
set_tier() {
  v=$(gm_value "$2")
  out=$(cmd game set --fps "$v" "$1" 2>&1)
  case "$out" in
    *"fps-override"*)
      [ "$3" = probe ] || kv_set "$MANAGED" "$1" "$2"
      return 0
      ;;
  esac
  log "GameManager fps $v for $1 failed: $out"
  return 1
}

release() {
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

# probe <package>: fps measured with the top tier requested.
probe() {
  set_tier "$1" "$TOP" probe || { echo 0; return; }
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

TIERS=$(load_tiers)
[ -n "$TIERS" ] || TIERS="60 120"
TOP=$(echo $TIERS | awk '{ print $NF }')
NEXT=$(echo $TIERS | awk '{ print (NF > 1) ? $(NF - 1) : $NF }')
FLOOR=$(conf_value default)
case "$FLOOR" in ''|*[!0-9]*) FLOOR=60 ;; esac
log "adaptive game fps watch (tiers: $TIERS; top via GameManager $(gm_value "$TOP"); floor $FLOOR)"

last_pkg=
state=
started=0
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
    last_pkg=$pkg
    state=pending
    started=$(date +%s)
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
    if [ "$state" != boosted ]; then
      cap=$mine
      last_probe=$now
      state=boosted
      log "keep $pkg at ${cap}Hz"
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
        set_tier "$pkg" "$cap"
      fi
    fi
    sleep 5
    continue
  fi

  # Standard mode but listed as ours: cleared by the user or the system.
  [ -n "$mine" ] && kv_set "$MANAGED" "$pkg"
  [ "$state" = custom ] || [ "$state" = boosted ] && state=pending

  [ -n "$uid" ] || uid=$(uid_for "$pkg")
  rate=$(sf_rate_for "$uid")

  # Not locked: let the game run, and learn its real frame rate whenever it
  # is uncapped at the top tier (gameplay, or the touch boost in menus).
  if [ -n "$rate" ] \
     && awk -v r="$rate" 'BEGIN { exit !(r >= 30) }'; then
    if [ "$state" != native ]; then
      log "observe $pkg: ${rate}Hz"
      state=native
    fi
    if awk -v r="$rate" -v t="$TOP" 'BEGIN { exit !(r >= t * 0.9) }' \
       && [ $((now - last_measure)) -ge 10 ]; then
      last_measure=$now
      m=$(measure_fps "$pkg" 2)
      old=$(kv_get "$LEARN" "$pkg")
      if [ "$m" -gt "${old:-0}" ]; then
        kv_set "$LEARN" "$pkg" "$m"
        log "learn $pkg: ${m}fps at ${rate}Hz (was ${old:-none})"
      fi
    else
      sleep 2
    fi
    started=$(date +%s)
    continue
  fi

  # Locked low (<30Hz) or no rate: wait 5s to skip loading transitions.
  if [ $((now - started)) -lt 5 ]; then
    sleep 1
    continue
  fi

  if [ -n "$fixed" ]; then
    target=$(tier_for "$((fixed * 10 / 9))")
    why="conf $fixed"
  else
    m=$(kv_get "$LEARN" "$pkg")
    if [ -z "$m" ]; then
      # Never seen uncapped: probe at the top tier.
      m=$(probe "$pkg")
      kv_set "$LEARN" "$pkg" "$m"
      why="probed ${m}fps"
    else
      why="learned ${m}fps"
    fi
    target=$(tier_for "$m")
  fi

  if set_tier "$pkg" "$target"; then
    cap=$target
    last_probe=$(date +%s)
    log "apply $pkg ${target}Hz ($why; was ${rate:-none}Hz)"
    state=boosted
  fi
  sleep 5
done
