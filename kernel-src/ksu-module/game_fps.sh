#!/system/bin/sh
# Adaptive game frame-rate policy.
#
# Android/GameManager only exposes per-package overrides; there is no global
# minimum-fps switch.  A game may request 120Hz during loading and then fall
# back to 24Hz when it goes idle.  The policy below keeps sampling while the
# game remains in the foreground, so that idle transition is caught too.
#
# Policy:
#   * watch the foreground package and ask GameManager whether it is a game;
#   * if its current mode is already custom, leave the user's/game's choice;
#   * otherwise sample SurfaceFlinger's requested rate for its UID;
#       - >= 30Hz (30/60/90/120): observe and keep the game's own request;
#       - <30Hz or no request for 5s: apply a floor.  The floor is the
#         configured fallback (60 by default), raised to the highest rate the
#         game requested this foreground session (capped at 120), so a
#         120Hz-capable game is not silently capped to 60.
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
peak_rate=0

while true; do
  pkg=$(dumpsys window 2>/dev/null \
    | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' \
    | head -n 1)

  if [ "$pkg" != "$last_pkg" ]; then
    last_pkg=$pkg
    state=pending
    started=$(date +%s)
    uid=
    peak_rate=0
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

  if [ "$state" = managed ]; then
    # The pipe was cleared (boot, user reset, or system policy change).
    state=pending
    started=$(date +%s)
    uid=
    peak_rate=0
  fi

  if [ -z "$uid" ]; then
    uid=$(uid_for "$pkg")
  fi
  rate=$(requested_rate_for "$uid")
  if [ -n "$rate" ]; then
    peak_rate=$(awk -v a="$peak_rate" -v b="$rate" \
      'BEGIN { print (b > a) ? b : a }')
  fi

  # A live >=30Hz request is the game's own valid choice (30/60/90/120).
  # Keep observing instead of marking the package "done": the same game can
  # drop to 24Hz later in the same foreground session.
  if [ -n "$rate" ] \
     && awk -v r="$rate" 'BEGIN { exit !(r >= 30) }'; then
    if [ "$state" != native ]; then
      log "observe $pkg: requested ${rate}Hz (peak ${peak_rate}Hz)"
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
  # Preserve a proven high-refresh game, but never let an idle 24Hz request
  # win over the floor.
  if awk -v p="$peak_rate" -v f="$fps" 'BEGIN { exit !(p > f) }'; then
    fps=$peak_rate
  fi
  if awk -v f="$fps" 'BEGIN { exit !(f > 120) }'; then
    fps=120
  fi

  out=$(cmd game set --fps "$fps" "$pkg" 2>&1)
  log "apply $pkg fps=$fps (requested ${rate:-none}Hz, peak ${peak_rate}Hz): $out"
  state=managed
  sleep 5
done
