#!/usr/bin/env bash
# mount_erofs.sh — mount an EROFS image (raw or Android sparse) read-only via erofsfuse.
#
#   mount_erofs.sh <image.img> <mountpoint>
#
# Notes
#  - EROFS kernel support is not required (uses FUSE).
#  - Reading security.selinux xattrs through this mount is the *only* reliable way to
#    enumerate inode labels: fsck.erofs --extract drops every xattr.
set -euo pipefail

IMG=${1:?usage: mount_erofs.sh <image.img> <mountpoint>}
MNT=${2:?usage: mount_erofs.sh <image.img> <mountpoint>}

command -v erofsfuse >/dev/null || { echo "erofsfuse not found (install erofs-utils / erofsfuse)" >&2; exit 1; }

mkdir -p "$MNT"
if mountpoint -q "$MNT"; then
  echo "[mount] $MNT already mounted"
  exit 0
fi

magic=$(head -c 4 "$IMG" | xxd -p)
RAW="$IMG"
if [ "$magic" = "3aff26ed" ]; then
  RAW="${IMG%.img}.raw.img"
  if [ ! -f "$RAW" ] || [ "$(stat -c%s "$RAW")" -lt "$(stat -c%s "$IMG")" ]; then
    echo "[mount] sparse image detected -> simg2img $RAW"
    simg2img "$IMG" "$RAW"
  fi
fi

erofsfuse "$RAW" "$MNT" >/dev/null 2>&1
sleep 1
if mountpoint -q "$MNT"; then
  echo "[mount] OK: $MNT ($(ls -A "$MNT" | head -3 | tr '\n' ' '))"
else
  echo "[mount] FAILED: $IMG" >&2
  exit 1
fi
