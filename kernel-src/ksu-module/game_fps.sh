#!/system/bin/sh
# Adaptive game frame-rate policy.
#
# Why this exists (see docs/游戏24fps诊断_ACE与帧率策略.md):
#   On this port HyperOS' SurfaceFlinger drops the whole display render rate to
#   24Hz while some games sit in a menu/lobby, although the game layer carries
#   no explicit frame-rate request (renderFrameRate=24, frameRateOverrides=[]).
#   The game's Choreographer then only gets 24 vsyncs/s and renders 23.8fps;
#   a heavier game that misses those slots falls to the teens.  Touch boosts
#   it back to 120Hz for the touch timer, then it falls again.
#
# Policy:
#   * watch the foreground package and ask GameManager whether it is a game;
#   * if its current mode is already custom, leave the user's/game's choice;
#   * otherwise sample SurfaceFlinger's per-UID rate for the game:
#       - >= 30Hz: observe only (touch boost also shows up as 120 here, so it
#         says nothing about what the game itself supports);
#       - <30Hz or no rate for 5s: apply the floor (60 by default) through
#         GameManager custom mode, which SurfaceFlinger honours over the 24Hz.
#   * floors above 60 cannot go through GameManager: SF treats an override
#     equal to the panel rate as "no override" and stays at 24.  For a
#     configured floor >60 the SF backdoor (transaction 1039, uid override)
#     is used instead and cleared when the game leaves the foreground.
#   * newly installed games are handled when first foreground; no package list.
#
# Optional overrides in /data/adb/rmx5010_game_fps.conf:
#   package:fps    per-game floor, e.g. com.example.game:120
#   default:fps    floor for 24/no-request games, default 60
MODDIR=${0%/*}
LOG="$MODDIR/game_fps.log"
CONF=/data/adb/rmx5010_game_fps.conf
DEFAULT_FPS=60
NON_GAME_LIST=""

log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

fps_for() {
  fps=$DEFAULT_FPS
  if [ -f "$CONF" ]; then
    for rule in $(cat "$CONF"); do
      case "$rule" in
        "$1":*) fps=${rule##*:}; break ;;
        default:*) fps=${rule##*:} ;;
      esac
    done
  fi
  echo "$fps"
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

requested_rate_for() {
  [ -n "$1" ] || return
  dumpsys SurfaceFlinger 2>/dev/null \
    | grep -oE "\(uid, frameRate\)=\{$1, [0-9.]+" \
    | head -n 1 | sed 's/.*, //'
}

i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ] && [ $i -lt 180 ]; do
  sleep 1
  i=$((i+1))
done
sleep 2
log "adaptive game fps watch (floor=$DEFAULT_FPS, continuous sampling)"

last_pkg=
state=
started=0
uid=
boost_uid=

# SF backdoor: per-UID frame-rate override; rate 0 removes it.
sf_backdoor() {
  service call SurfaceFlinger 1039 i32 "$1" f "$2" 2>&1
}

clear_boost() {
  if [ -n "$boost_uid" ]; then
    sf_backdoor "$boost_uid" 0 >/dev/null
    log "clear SF override for uid $boost_uid"
    boost_uid=
  fi
}

while true; do
  pkg=$(dumpsys window 2>/dev/null \
    | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' \
    | head -n 1)

  if [ "$pkg" != "$last_pkg" ]; then
    clear_boost
    last_pkg=$pkg
    state=pending
    started=$(date +%s)
    uid=
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

  if [ "$mode" = custom ]; then
    if [ "$state" != managed ]; then
      log "leave $pkg: already custom"
      state=managed
    fi
    sleep 5
    continue
  fi

  if [ "$state" = boosted ]; then
    sleep 5
    continue
  fi

  if [ "$state" = managed ]; then
    # The pipe was cleared (boot, user reset, or system policy change).
    state=pending
    started=$(date +%s)
    uid=
  fi

  if [ -z "$uid" ]; then
    uid=$(uid_for "$pkg")
  fi
  rate=$(requested_rate_for "$uid")

  # >=30Hz: leave it.  Keep observing instead of marking the package "done":
  # the same game drops to 24Hz again once the touch boost expires.
  if [ -n "$rate" ] \
     && awk -v r="$rate" 'BEGIN { exit !(r >= 30) }'; then
    if [ "$state" != native ]; then
      log "observe $pkg: ${rate}Hz"
      state=native
    fi
    sleep 2
    continue
  fi

  now=$(date +%s)
  if [ $((now - started)) -lt 5 ]; then
    sleep 1
    continue
  fi

  fps=$(fps_for "$pkg")
  # SurfaceFlinger prints rates as "120.00"; GameManager only accepts an
  # integer and rejects "120.00" with "Invalid frame rate".
  fps=$(awk -v f="$fps" 'BEGIN { f += 0.5; if (f > 120) f = 120; printf "%d", f }')

  if [ "$fps" -gt 60 ]; then
    out=$(sf_backdoor "$uid" "$fps")
    case "$out" in
      *"Parcel(00000000"*)
        boost_uid=$uid
        log "apply $pkg fps=$fps via SF override uid $uid (was ${rate:-none}Hz)"
        state=boosted
        sleep 5
        continue
        ;;
    esac
    log "SF override for $pkg failed: $out; fall back to $DEFAULT_FPS"
    fps=$DEFAULT_FPS
  fi

  out=$(cmd game set --fps "$fps" "$pkg" 2>&1)
  log "apply $pkg fps=$fps (was ${rate:-none}Hz): $out"
  state=managed
  sleep 5
done
