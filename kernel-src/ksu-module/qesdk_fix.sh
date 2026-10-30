#!/system/bin/sh
# Qualcomm QESDK / QAPE seccomp policy fix.
#
# qesdk-secmanager, qsap_qapeservice and syshealthmon-service are launched with
# a libminijail allow-list that does not include lseek.  On this vendor base
# the binaries do call lseek, so every start dies with SIGSYS, init kills the
# whole service group, and QESDK/QAPE never reaches READY.  The crash loop also
# makes qseelogd rotate TrustZone logs continuously (one full core burned).
#
# Append lseek to the three allow-lists and bind-mount the patched copies into
# init's mount namespace.  The deadline is early enough in post-fs-data that
# the vendor services start with the fixed policy.
QESDK_POLICIES="qesdksec.policy qsap_qapeservice.policy syshealthmon.policy"
QESDK_SERVICES="vendor.qesdk-securitymgr vendor.qsap.qapeservice vendor.qti.syshealthmon-service"

qesdk_patch_policy() {
  src="/vendor/etc/seccomp_policy/$1"
  dst="/data/local/tmp/qesdk_$1"

  [ -f "$src" ] || return 1
  # Already patched (or mounted by an earlier run).
  grep -q '^lseek:' "$src" 2>/dev/null && return 0

  cp -f "$src" "$dst" || return 1
  printf '\nlseek: 1\n' >> "$dst"
  chmod 0644 "$dst"
  if [ -x /system/bin/chcon ]; then
    /system/bin/chcon u:object_r:vendor_configs_file:s0 "$dst" 2>/dev/null
  fi

  if /system/bin/nsenter -t 1 -m -- mount --bind "$dst" "$src" 2>/dev/null; then
    log "qesdk: $1 + lseek"
    return 0
  fi
  if mount --bind "$dst" "$src" 2>/dev/null; then
    log "qesdk: $1 + lseek (local ns)"
    return 0
  fi
  log "qesdk: mount failed $1"
  return 1
}

ensure_qesdk_policy() {
  rc=0
  for p in $QESDK_POLICIES; do
    qesdk_patch_policy "$p" || rc=1
  done
  return $rc
}

apply_qseelogd_fix() {
  # persist.sys.qseelogd=false is the vendor's own switch: init.qseelogd.rc
  # stops the daemon on this property.  It is a logging-only process.
  setprop persist.sys.qseelogd false
  stop qseelogd 2>/dev/null
  log "qseelogd disabled"
}
