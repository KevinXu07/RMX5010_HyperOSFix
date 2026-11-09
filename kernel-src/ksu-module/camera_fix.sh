#!/system/bin/sh
# OplusCamera systemless port for RMX5010 HyperOS.
#
# The OplusCamera APK is baked into the product image at its canonical
# /product/priv-app/OplusCamera path.  This module only injects the app's
# private native libraries so the image APK always supplies the dex code.
# Permission XMLs are merged into /product/etc/permissions and friends, and
# the product seapp_contexts gets the one missing com.oplus.camera mapping.
# The current /system/lib64/libnativewindow.so is replaced by the P010-patched
# copy.  No partition is modified.
CAM_DIR="$MODDIR/camera"
CAM_POLICY="$CAM_DIR/sepolicy.rules"
CAM_TMP=/data/local/tmp/rmx_camera

camera_mount_file() {
  src=$1
  target=$2
  context=$3
  label=$4
  [ -f "$src" ] || return 1
  chmod 0644 "$src"
  if [ -x /system/bin/chcon ]; then
    /system/bin/chcon "$context" "$src" 2>/dev/null
  fi
  if /system/bin/nsenter -t 1 -m -- mount --bind "$src" "$target" 2>/dev/null; then
    log "camera: mounted $label"
    return 0
  fi
  if mount --bind "$src" "$target" 2>/dev/null; then
    log "camera: mounted $label (local ns)"
    return 0
  fi
  log "camera: mount failed $label"
  return 1
}

camera_mount_dir() {
  src=$1
  target=$2
  context=$3
  label=$4
  [ -d "$src" ] || return 1
  if [ -x /system/bin/chcon ]; then
    /system/bin/chcon -R "$context" "$src" 2>/dev/null
  fi
  if /system/bin/nsenter -t 1 -m -- mount --bind "$src" "$target" 2>/dev/null; then
    log "camera: mounted $label"
    return 0
  fi
  log "camera: mount failed $label"
  return 1
}

camera_mount_bin() {
  src=$1
  target=$2
  stage="$CAM_TMP/cambin"
  [ -f "$src" ] || return 1
  # /data is mounted nosuid, so a bind mount straight from it onto
  # /system/bin makes init's exec hit the nosuid_transition check.  SukiSU
  # 4.3.0-r2 cannot grant that permission: `ksud sepolicy patch/apply` accepts
  # the allow rule but every later check on the permission fails silently
  # (no avc message, exec still EACCES).  Stage the binary on a tmpfs instead:
  # the bind then carries no MS_NOSUID, exactly like the stock file on
  # /system, so the stock init -> cameraserver rules apply unchanged.
  if ! grep -q " $stage " /proc/1/mountinfo; then
    mkdir -p "$stage"
    if ! nsenter -t 1 -m -- mount -t tmpfs -o mode=0755,size=16M tmpfs "$stage" 2>/dev/null; then
      log "camera: cameraserver staging tmpfs failed"
      return 1
    fi
  fi
  if ! nsenter -t 1 -m -- cp -f "$src" "$stage/cameraserver" 2>/dev/null; then
    log "camera: cameraserver stage copy failed"
    return 1
  fi
  nsenter -t 1 -m -- chmod 0755 "$stage/cameraserver" 2>/dev/null
  if [ -x /system/bin/chcon ]; then
    nsenter -t 1 -m -- chcon u:object_r:cameraserver_exec:s0 \
      "$stage/cameraserver" 2>/dev/null
  fi
  if nsenter -t 1 -m -- mount --bind "$stage/cameraserver" "$target" 2>/dev/null; then
    log "camera: mounted patched cameraserver (tmpfs stage)"
    return 0
  fi
  log "camera: patched cameraserver mount failed"
  return 1
}

camera_merge_dir() {
  orig=$1
  add=$2
  target=$3
  context=$4
  label=$5
  tmp="$CAM_TMP/$label"
  [ -d "$orig" ] || return 1
  rm -rf "$tmp"
  mkdir -p "$tmp" || return 1
  cp -a "$orig"/. "$tmp"/ 2>/dev/null
  if [ -d "$add" ]; then
    cp -a "$add"/. "$tmp"/ 2>/dev/null
  fi
  chown -R 0:0 "$tmp" 2>/dev/null
  chmod -R u+rwX,go+rX "$tmp" 2>/dev/null
  if [ -x /system/bin/chcon ]; then
    /system/bin/chcon -R "$context" "$tmp" 2>/dev/null
  fi
  if /system/bin/nsenter -t 1 -m -- mount --bind "$tmp" "$target" 2>/dev/null; then
    log "camera: merged $label"
    return 0
  fi
  log "camera: merge mount failed $label"
  return 1
}

camera_overlay_privapp() {
  rw="$CAM_TMP/privapp_rw"
  # Use the complete 6.070.45 build bundled in this module.  The 6.020
  # preview APK baked into the product image is missing the pantanal
  # FileShareProvider dex and crashes com.oplus.camera on launch.
  apk_src="$CAM_DIR/priv-app/MiuiCamera/OplusCamera.apk"
  [ -f "$apk_src" ] || apk_src=/product/priv-app/OplusCamera/OplusCamera.apk
  lib_src="$CAM_DIR/priv-app/MiuiCamera/lib/arm64"
  stub_src="$CAM_DIR/priv-app/MiuiCamera/MiuiCameraProviderStub.apk"
  gallery_src="$CAM_DIR/priv-app/ColorOSGalleryStub/ColorOSGalleryStub.apk"
  [ -f "$apk_src" ] || return 1

  if nsenter -t 1 -m -- sh -c "mount | grep -q ' on /product/priv-app .*overlay'" 2>/dev/null; then
    log "camera: product priv-app overlay already active"
    return 0
  fi

  nsenter -t 1 -m -- umount "$rw" 2>/dev/null
  rm -rf "$rw"
  mkdir -p "$rw" || return 1
  if ! nsenter -t 1 -m -- mount -t tmpfs -o mode=0755,size=768M tmpfs "$rw"; then
    log "camera: product priv-app tmpfs mount failed"
    return 1
  fi
  nsenter -t 1 -m -- mkdir -p "$rw/upper/OplusCamera/lib/arm64" \
    "$rw/upper/MiuiCameraProviderStub" "$rw/upper/ColorOSGalleryStub" "$rw/work" || return 1
  nsenter -t 1 -m -- cp -f "$apk_src" "$rw/upper/OplusCamera/OplusCamera.apk" || return 1
  nsenter -t 1 -m -- touch -d @0 "$rw/upper/OplusCamera/OplusCamera.apk" 2>/dev/null || true
  # Hide any prebuilt oat/vdex for the APK: the overlay carries a patched
  # classes12.dex, so ART must compile from the APK dex instead of reusing
  # code compiled from the old one.
  nsenter -t 1 -m -- mkdir -p "$rw/upper/OplusCamera/oat/arm64" 2>/dev/null
  nsenter -t 1 -m -- sh -c 'for f in OplusCamera.odex OplusCamera.vdex; do mknod "$0/.wh.$f" c 0 0 2>/dev/null; done' "$rw/upper/OplusCamera/oat/arm64" 2>/dev/null || true
  nsenter -t 1 -m -- chmod 0644 "$rw/upper/OplusCamera/OplusCamera.apk" 2>/dev/null
  if [ -d "$lib_src" ]; then
    nsenter -t 1 -m -- cp -a "$lib_src/." "$rw/upper/OplusCamera/lib/arm64/" || return 1
    # lib_src must hold only the APK's own libraries plus the few extras the
    # app needs; never add the unit SDK jar's system_ext JNI libraries here.
    # The jar loads JNI from the app lib dir first (clns-11), and a copy found
    # there cannot reach the ODM libraries (libOplusSecurity, libalog) the
    # system_ext copy reaches through the default namespace:
    # oplus_camera_config then fails to decrypt, APS drops to version 2 with
    # no capture decision, and preview/zoom/capture break.
    nsenter -t 1 -m -- chmod 0644 "$rw/upper/OplusCamera/lib/arm64/"*.so 2>/dev/null
  fi
  nsenter -t 1 -m -- cp -f "$stub_src" \
    "$rw/upper/MiuiCameraProviderStub/MiuiCameraProviderStub.apk" || return 1
  [ -f "$gallery_src" ] && nsenter -t 1 -m -- cp -f "$gallery_src" \
    "$rw/upper/ColorOSGalleryStub/ColorOSGalleryStub.apk" 2>/dev/null
  if [ -x /system/bin/chcon ]; then
    nsenter -t 1 -m -- chcon -R u:object_r:system_file:s0 "$rw/upper" 2>/dev/null
  fi

  if ! nsenter -t 1 -m -- mount -t overlay overlay \
       -o "lowerdir=/product/priv-app,upperdir=$rw/upper,workdir=$rw/work" \
       /product/priv-app; then
    log "camera: product priv-app overlay mount failed"
    nsenter -t 1 -m -- umount "$rw" 2>/dev/null
    rm -rf "$rw"
    return 1
  fi
  log "camera: product priv-app overlay active"
  return 0
}

camera_overlay_systemext_privapp() {
  rw="$CAM_TMP/systemext_privapp_rw"
  apk_src="$CAM_DIR/priv-app/MiuiCamera/OplusCamera.apk"
  lib_src="$CAM_DIR/priv-app/MiuiCamera/lib/arm64"
  [ -f "$apk_src" ] || return 1
  if nsenter -t 1 -m -- sh -c "mount | grep -q ' on /system_ext/priv-app .*overlay'" 2>/dev/null; then
    log "camera: system_ext priv-app overlay already active"
    return 0
  fi
  nsenter -t 1 -m -- umount "$rw" 2>/dev/null
  rm -rf "$rw"
  mkdir -p "$rw" || return 1
  if ! nsenter -t 1 -m -- mount -t tmpfs -o mode=0755,size=768M tmpfs "$rw"; then
    log "camera: system_ext priv-app tmpfs mount failed"
    return 1
  fi
  nsenter -t 1 -m -- mkdir -p "$rw/upper/OplusCamera/lib/arm64" "$rw/work" || return 1
  if [ -x /system/bin/chcon ]; then
    nsenter -t 1 -m -- chcon -R u:object_r:system_file:s0 "$rw/upper" 2>/dev/null
  fi
  if ! nsenter -t 1 -m -- mount -t overlay overlay \
       -o "lowerdir=/system_ext/priv-app,upperdir=$rw/upper,workdir=$rw/work" \
       /system_ext/priv-app; then
    log "camera: system_ext priv-app overlay mount failed"
    nsenter -t 1 -m -- umount "$rw" 2>/dev/null
    rm -rf "$rw"
    return 1
  fi
  if ! nsenter -t 1 -m -- test -f /system_ext/priv-app/OplusCamera/OplusCamera.apk; then
    log "camera: system_ext priv-app overlay verification failed"
    nsenter -t 1 -m -- umount /system_ext/priv-app 2>/dev/null
    nsenter -t 1 -m -- umount "$rw" 2>/dev/null
    return 1
  fi
  log "camera: system_ext priv-app overlay active"
  return 0
}

camera_apply_policy() {
  # SukiSU 4.3.0-r2 cannot add usable process types: after
  # `ksud sepolicy patch "type ..."` the type resolves for runcon (the ksu
  # domain is permissive, so the avc check is skipped) but zygote still fails
  # selinux_android_setcontext() with EINVAL for it - and the module-side
  # sepolicy.rule boot injection behaves the same.  Stock types are fine, so
  # the camera is labelled with traceur_app (only com.android.traceur uses it)
  # and that existing type is switched to permissive.  Changing the state of a
  # stock type does still work through the runtime patcher.
  # Opening an offline camera session (APS quick jpeg) goes through
  # vendor.qti.hardware.camera.offlinecamera.IOfflineCameraService, which runs
  # in vendor.qti.camera.provider-service_64 (hal_camera_default).  The service
  # calls back into the app to read the callback binder's AIDL descriptor.
  # Without an `allow hal_camera_default traceur_app:binder call` rule that
  # check is denied (permissive=0 - the source domain is the HAL, not the
  # permissive app), the descriptor reads back as empty, openOfflineSession()
  # fails with ILLEGAL_ARGUMENT and configureOfflineStreams() then dereferences
  # the null session: SIGSEGV in RefFrameProcess on every shutter press and on
  # switching to the front camera.  SukiSU cannot add the allow rule, so make
  # the stock HAL type permissive as well.
  ksud=/data/adb/ksu/bin/ksud
  [ -x "$ksud" ] || ksud=/data/adb/ksud
  [ -x "$ksud" ] || return 1
  rc=0
  if "$ksud" sepolicy patch "permissive traceur_app;" >/dev/null 2>&1; then
    log "camera: traceur_app permissive"
  else
    log "camera: traceur_app permissive patch failed"
    rc=1
  fi
  if "$ksud" sepolicy patch "permissive hal_camera_default;" >/dev/null 2>&1; then
    log "camera: hal_camera_default permissive"
  else
    log "camera: hal_camera_default permissive patch failed"
    rc=1
  fi
  return $rc
}

camera_patch_seapp_contexts() {
  src=/product/etc/selinux/product_seapp_contexts
  [ -f "$src" ] || return 1
  cp -f "$src" "$CAM_TMP/product_seapp_contexts" 2>/dev/null || return 1
  # A KSU-created domain cannot be entered by zygote on the current SukiSU
  # build (setcontext EINVAL), so borrow a stock app domain.  traceur_app is
  # only used by com.android.traceur and is made permissive by
  # camera_apply_policy().
  sed -i '/name=com.oplus.camera/d' "$CAM_TMP/product_seapp_contexts"
  sed -i '1i user=_app isPrivApp=true name=com.oplus.camera domain=traceur_app type=privapp_data_file levelFrom=user' \
    "$CAM_TMP/product_seapp_contexts"
  camera_mount_file "$CAM_TMP/product_seapp_contexts" "$src" \
    u:object_r:seapp_contexts_file:s0 seapp_contexts
}

camera_patch_systemext_seapp() {
  src=/system_ext/etc/selinux/system_ext_seapp_contexts
  [ -f "$src" ] || return 0
  cp -f "$src" "$CAM_TMP/system_ext_seapp_contexts" 2>/dev/null || return 1
  sed -i '/name=com.oplus.camera/d' "$CAM_TMP/system_ext_seapp_contexts"
  sed -i '1i user=_app isPrivApp=true name=com.oplus.camera domain=traceur_app type=privapp_data_file levelFrom=user'     "$CAM_TMP/system_ext_seapp_contexts"
  camera_mount_file "$CAM_TMP/system_ext_seapp_contexts" "$src"     u:object_r:seapp_contexts_file:s0 system_ext_seapp_contexts
}

camera_overlay_system_libs() {
  src="$MODDIR/system"
  [ -d "$src/system_ext/lib64" ] || return 0
  rw="$CAM_TMP/system_rw"
  if nsenter -t 1 -m -- sh -c "mount | grep -q ' on /system_ext/lib64 .*overlay'" 2>/dev/null; then
    log "camera: system overlays already active"
    return 0
  fi
  nsenter -t 1 -m -- umount "$rw" 2>/dev/null
  rm -rf "$rw"
  mkdir -p "$rw"
  if ! nsenter -t 1 -m -- mount -t tmpfs -o mode=0755,size=512M tmpfs "$rw"; then
    log "camera: system overlay tmpfs failed"
    return 1
  fi
  nsenter -t 1 -m -- mkdir -p "$rw/ext_upper" "$rw/ext_work" \
    "$rw/sys_upper" "$rw/sys_work" "$rw/fw_upper" "$rw/fw_work" \
    "$rw/perm_upper" "$rw/perm_work" "$rw/odm_upper" "$rw/odm_work" || return 1
  nsenter -t 1 -m -- cp -a "$src/system_ext/lib64/." "$rw/ext_upper/" || return 1
  [ -d "$src/lib64" ] && nsenter -t 1 -m -- cp -a "$src/lib64/." "$rw/sys_upper/"
  [ -d "$src/system_ext/framework" ] && nsenter -t 1 -m -- cp -a \
    "$src/system_ext/framework/." "$rw/fw_upper/"
  [ -d "$src/system_ext/etc/permissions" ] && nsenter -t 1 -m -- cp -a \
    "$src/system_ext/etc/permissions/." "$rw/perm_upper/"
  odm_src="$CAM_DIR/odm/lib64"
  [ -d "$odm_src" ] && nsenter -t 1 -m -- cp -a "$odm_src/." "$rw/odm_upper/"

  if [ -x /system/bin/chcon ]; then
    nsenter -t 1 -m -- chcon -R u:object_r:system_lib_file:s0 \
      "$rw/ext_upper" "$rw/sys_upper" 2>/dev/null
    nsenter -t 1 -m -- chcon -R u:object_r:same_process_hal_file:s0 \
      "$rw/odm_upper" 2>/dev/null
    nsenter -t 1 -m -- chcon -R u:object_r:system_file:s0 \
      "$rw/fw_upper" "$rw/perm_upper" 2>/dev/null
  fi

  nsenter -t 1 -m -- mount -t overlay overlay \
    -o "lowerdir=/system_ext/lib64,upperdir=$rw/ext_upper,workdir=$rw/ext_work" \
    /system_ext/lib64 || { log "camera: ext lib overlay failed"; return 1; }
  nsenter -t 1 -m -- mount -t overlay overlay \
    -o "lowerdir=/system/lib64,upperdir=$rw/sys_upper,workdir=$rw/sys_work" \
    /system/lib64 || { log "camera: system lib overlay failed"; return 1; }
  if [ -d "$odm_src" ]; then
    nsenter -t 1 -m -- mount -t overlay overlay \
      -o "lowerdir=/odm/lib64,upperdir=$rw/odm_upper,workdir=$rw/odm_work" \
      /odm/lib64 || log "camera: odm lib overlay failed"
  fi
  if [ -d "$src/system_ext/framework" ]; then
    nsenter -t 1 -m -- mount -t overlay overlay \
      -o "lowerdir=/system_ext/framework,upperdir=$rw/fw_upper,workdir=$rw/fw_work" \
      /system_ext/framework || log "camera: framework overlay failed"
  fi
  if [ -d "$src/system_ext/etc/permissions" ]; then
    nsenter -t 1 -m -- mount -t overlay overlay \
      -o "lowerdir=/system_ext/etc/permissions,upperdir=$rw/perm_upper,workdir=$rw/perm_work" \
      /system_ext/etc/permissions || log "camera: permissions overlay failed"
  fi
  if nsenter -t 1 -m -- test -f /system_ext/lib64/libCombineLutJni.so; then
    log "camera: system camera libs overlay active"
    return 0
  fi
  log "camera: system camera libs overlay verification failed"
  return 1
}

ensure_camera_port() {
  mkdir -p "$CAM_TMP"

  # Oplus private camera libraries/JARs are not in the OS4 base.  Add them
  # through directory overlays before cameraserver/PMS start; magic mount of
  # this module's system/ tree is not active on this device.
  camera_overlay_system_libs

  # OS4 cameraserver needs the Oplus SAT/XPAN/RAW/timestamp patches and the
  # libcamera_client -> libsatbridge dependency.  Mount it before cameraserver
  # starts; it is staged through a tmpfs so init's exec does not need the
  # nosuid_transition permission (see camera_mount_bin).
  camera_mount_bin "$CAM_DIR/cameraserver" /system/bin/cameraserver

  # RMX P010 vendor format branch for the Oplus camera HAL.
  camera_mount_file "$CAM_DIR/libnativewindow.so" /system/lib64/libnativewindow.so \
    u:object_r:system_lib_file:s0 libnativewindow-p010

  # The Oplus README calls out swapping libAlgoInterface as a regression;
  # keep the RMX ODM algorithm pair untouched.

  if [ -x /data/adb/ksud ]; then
    /data/adb/ksud resetprop ro.oplus.camera.defercap.support 1 2>/dev/null
    /data/adb/ksud resetprop ro.oplus.camera.defercap.all.quick.visible.support 1 2>/dev/null
  fi
  log "camera: defercap props $(getprop ro.oplus.camera.defercap.support)/$(getprop ro.oplus.camera.defercap.all.quick.visible.support)"

  # The RMX sensor 3 (rear wide) does not expose RAW16 at 4096x3072 on the
  # Xiaomi HAL.  Drop the conflicting raw streams from the SAT photo use case
  # (the vendor camera provider caches this file at boot, so it must be in
  # place before the provider starts).
  camera_mount_file "$CAM_DIR/etc/camera_unit_config" \
    /odm/etc/camera/config/camera_unit_config \
    u:object_r:vendor_configs_file:s0 camera_unit_config

  # The OplusCamera APK is baked into the product image at the canonical path.
  # Only inject its private native libraries into the existing app directory.
  camera_overlay_privapp

  # Permission/sysconfig XMLs live in read-only product.  Merge the originals
  # with the OplusCamera additions and bind-mount the result.
  camera_merge_dir /product/etc/permissions "$CAM_DIR/etc/permissions" \
    /product/etc/permissions u:object_r:system_file:s0 permissions
  camera_merge_dir /product/etc/default-permissions "$CAM_DIR/etc/default-permissions" \
    /product/etc/default-permissions u:object_r:system_file:s0 default-permissions
  camera_merge_dir /product/etc/sysconfig "$CAM_DIR/etc/sysconfig" \
    /product/etc/sysconfig u:object_r:system_file:s0 sysconfig

  camera_apply_policy
  camera_patch_seapp_contexts
  return 0
}

camera_fix_data_app_libs() {
  # The 6.070 update is installed under /data/app.  PackageManager extracts
  # only the APK's own libraries there, so the Oplus shim, the ODM 2DSlender
  # library and the XDoc/SuperText chain must be copied into the current
  # randomized lib dir.  The unit.sdk.jar classloader namespace only searches
  # the app's nativeLibraryDir, not /system_ext/lib64, and XDoc's JNI_OnLoad
  # dlopens libSuperTextWrapper.so by name.
  apk=$(pm path com.oplus.camera 2>/dev/null | sed -n 's/^package://p' | head -1)
  [ -n "$apk" ] || return 1
  libdir=$(dirname "$apk")/lib/arm64
  [ -d "$libdir" ] || return 0
  for lib in libvndksupport.so lib2DSlender.so \
             libXDocProcessSDK-jni.so libXDocProcessSDK.so \
             libSuperTextWrapper.so libYTCommon.so; do
    [ -f "$CAM_DIR/$lib" ] || continue
    for try in 1 2 3; do
      cp -f "$CAM_DIR/$lib" "$libdir/$lib" 2>/dev/null && break
      sleep 1
    done
    chmod 0755 "$libdir/$lib" 2>/dev/null
    chown 0:0 "$libdir/$lib" 2>/dev/null
  done
  log "camera: data app libs synced to $libdir"
  return 0
}

camera_post_boot() {
  i=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != 1 ] && [ $i -lt 120 ]; do
    sleep 1
    i=$((i+1))
  done
  sleep 2
  # Older module versions installed this stub as a data app.  A data app
  # shadows the /product copy, so an old stub (1.1/versionCode 2, which still
  # declared a MAIN/LAUNCHER activity) keeps its blank "Gallery" icon after
  # the module is updated even though the bundled stub has no activity.
  # Upgrade whenever the installed copy is older than 1.2/versionCode 3.
  cur=$(dumpsys package com.coloros.gallery3d 2>/dev/null \
        | sed -n 's/^ *versionCode=\([0-9][0-9]*\).*/\1/p' | head -1)
  if [ "${cur:-0}" -lt 3 ] 2>/dev/null; then
    out=$(pm install -r "$CAM_DIR/priv-app/ColorOSGalleryStub/ColorOSGalleryStub.apk" 2>&1)
    log "camera: gallery stub install (was ${cur:-missing}) ${out:-ok}"
  fi
  if ! pm path com.xiaomi.camera.parallelservice.stub >/dev/null 2>&1; then
    out=$(pm install -r "$CAM_DIR/priv-app/MiuiCamera/MiuiCameraProviderStub.apk" 2>&1)
    log "camera: provider stub install ${out:-ok}"
  fi
  if ! pm path com.oplus.camera >/dev/null 2>&1; then
    log "camera: com.oplus.camera not installed"
    return 1
  fi
  camera_fix_data_app_libs
  for p in android.permission.CAMERA android.permission.RECORD_AUDIO \
           android.permission.ACCESS_FINE_LOCATION android.permission.ACCESS_COARSE_LOCATION \
           android.permission.READ_MEDIA_IMAGES android.permission.READ_MEDIA_VIDEO; do
    pm grant com.oplus.camera "$p" >/dev/null 2>&1
  done
  # HyperOS does not define android.app.role.SYSTEM_CAMERA; add-role-holder
  # then fails with RuntimeException("Failed") and logs an error on every
  # boot.  The default camera still resolves through the intent filter
  # (OplusCamera is the only camera installed), so skip when absent.
  if dumpsys role 2>/dev/null | grep -q 'name=android.app.role.SYSTEM_CAMERA'; then
    cmd role remove-role-holder android.app.role.SYSTEM_CAMERA com.android.camera 0 >/dev/null 2>&1
    out=$(cmd role add-role-holder android.app.role.SYSTEM_CAMERA com.oplus.camera 0 2>&1)
    log "camera: role ${out:-ok}"
  else
    log "camera: role skipped (SYSTEM_CAMERA not defined on this ROM)"
  fi
}
