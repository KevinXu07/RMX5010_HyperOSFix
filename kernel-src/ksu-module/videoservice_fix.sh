#!/system/bin/sh
# Xiaomi vendor video service port (multi-view recording finalize).
#
# OplusCamera's native media stack calls
#   vendor.xiaomi.hardware.videoservice.IVideoService/default
# to reserve codec/VPP resources for the second (front) video track and to
# stop/release frame capture.  The RMX5010 ColorOS vendor does not ship that
# service, so multi-view leaves a .pending-*.mp4 with ftyp/mdat but no moov.
#
# The real implementation comes from the haotian OS4 vendor image.  It is
# registered as vendor.qti.hardware.embmssl.IEmbms/default, a VINTF-declared
# name that servicemanager accepts without a manifest change.  Sense registers
# a system_server forwarding proxy under the name OplusCamera expects.

VS_DIR="$MODDIR/camera/vendor"
VS_LOG="$MODDIR/videoservice.log"

vs_log() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$VS_LOG"
}

videoservice_early() {
  : >> "$VS_LOG"

  # Map the AIDL instance name used by the system_server proxy.  The proxy
  # runs in system_server; OplusCamera only needs find/call on the type.
  sc="$MODDIR/camera/etc/system_ext_service_contexts"
  if [ -f "$sc" ]; then
    chcon u:object_r:system_file:s0 "$sc" 2>/dev/null
    if nsenter -t 1 -m -- mount --bind "$sc" /system_ext/etc/selinux/system_ext_service_contexts; then
      vs_log "service_contexts mounted"
    else
      vs_log "service_contexts mount failed"
    fi
  else
    vs_log "service_contexts missing"
  fi
  return 0
}

videoservice_start() {
  bin="$VS_DIR/bin/hw/vendor.xiaomi.hardware.videoservice-service"
  [ -f "$bin" ] || { vs_log "service binary missing"; return 1; }
  chmod 0755 "$bin" 2>/dev/null
  mkdir -p /data/vendor/video
  chmod 0777 /data/vendor/video

  # The service can answer codec-resource requests before vppservice starts;
  # wait only briefly so the camera does not race the registration.
  i=0
  while [ $i -lt 10 ]; do
    pidof vppservice >/dev/null 2>&1 && break
    sleep 1
    i=$((i+1))
  done

  if pidof vendor.xiaomi.hardware.videoservice-service >/dev/null 2>&1; then
    vs_log "service already running"
    return 0
  fi

  LD_LIBRARY_PATH="$VS_DIR/lib64" "$bin" >> "$VS_LOG" 2>&1 &
  vs_log "service started pid=$!"

  # Standalone Java forwarding proxy.  It runs in the KSU domain, where
  # ServiceManager can reach the eMBMS-registered real service, and registers
  # the AIDL name OplusCamera expects.  system_server's ServiceManager cannot
  # see the vendor service on this base.
  proxy="$VS_DIR/videoproxy.dex"
  if [ -f "$proxy" ] && [ ! -f /dev/rmx_videoproxy_started ]; then
    CLASSPATH="$proxy" app_process /system/bin VideoServiceProxy >> "$VS_LOG" 2>&1 &
    touch /dev/rmx_videoproxy_started
    vs_log "proxy started pid=$!"
  fi
  return 0
}
