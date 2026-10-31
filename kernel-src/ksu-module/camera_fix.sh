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
  [ -f "$src" ] || return 1
  chmod 0755 "$src"
  if [ -x /system/bin/chcon ]; then
    /system/bin/chcon u:object_r:cameraserver_exec:s0 "$src" 2>/dev/null
  fi
  if nsenter -t 1 -m -- mount --bind "$src" "$target" 2>/dev/null; then
    log "camera: mounted patched cameraserver"
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
  apk_src="$CAM_DIR/priv-app/MiuiCamera/OplusCamera.apk"
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
  nsenter -t 1 -m -- chmod 0644 "$rw/upper/OplusCamera/OplusCamera.apk" 2>/dev/null
  if [ -d "$lib_src" ]; then
    nsenter -t 1 -m -- cp -a "$lib_src/." "$rw/upper/OplusCamera/lib/arm64/" || return 1
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
  [ -f "$CAM_POLICY" ] || return 1
  ksud=/data/adb/ksu/bin/ksud
  [ -x "$ksud" ] || ksud=/data/adb/ksud
  [ -x "$ksud" ] || return 1
  rules=$(cat "$CAM_POLICY")
  if "$ksud" sepolicy check "$rules" >/dev/null 2>&1 \
     && "$ksud" sepolicy patch "$rules" >/dev/null 2>&1; then
    log "camera: sepolicy patched"
    return 0
  fi
  log "camera: sepolicy patch failed"
  return 1
}

camera_patch_seapp_contexts() {
  src=/product/etc/selinux/product_seapp_contexts
  [ -f "$src" ] || return 1
  cp -f "$src" "$CAM_TMP/product_seapp_contexts" 2>/dev/null || return 1
  # The vendor type exported by this OS4 merge is not a usable process type
  # (setcon returns EINVAL), so label the app with a KSU-created bridge domain
  # that joins the same versioned camera attribute set.
  sed -i '/name=com.oplus.camera/d' "$CAM_TMP/product_seapp_contexts"
  sed -i '1i user=_app isPrivApp=true name=com.oplus.camera domain=oplus_camera_app2 type=privapp_data_file levelFrom=user' \
    "$CAM_TMP/product_seapp_contexts"
  camera_mount_file "$CAM_TMP/product_seapp_contexts" "$src" \
    u:object_r:seapp_contexts_file:s0 seapp_contexts
}

camera_patch_systemext_seapp() {
  src=/system_ext/etc/selinux/system_ext_seapp_contexts
  [ -f "$src" ] || return 0
  cp -f "$src" "$CAM_TMP/system_ext_seapp_contexts" 2>/dev/null || return 1
  sed -i '/name=com.oplus.camera/d' "$CAM_TMP/system_ext_seapp_contexts"
  sed -i '1i user=_app isPrivApp=true name=com.oplus.camera domain=oplus_camera_app2 type=privapp_data_file levelFrom=user'     "$CAM_TMP/system_ext_seapp_contexts"
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
    "$rw/perm_upper" "$rw/perm_work" "$rw/odm_upper" "$rw/odm_work" \
    "$rw/odm_etc_upper" "$rw/odm_etc_work" || return 1
  nsenter -t 1 -m -- cp -a "$src/system_ext/lib64/." "$rw/ext_upper/" || return 1
  [ -d "$src/lib64" ] && nsenter -t 1 -m -- cp -a "$src/lib64/." "$rw/sys_upper/"
  [ -d "$src/system_ext/framework" ] && nsenter -t 1 -m -- cp -a \
    "$src/system_ext/framework/." "$rw/fw_upper/"
  [ -d "$src/system_ext/etc/permissions" ] && nsenter -t 1 -m -- cp -a \
    "$src/system_ext/etc/permissions/." "$rw/perm_upper/"
  odm_src="$CAM_DIR/odm/lib64"
  [ -d "$odm_src" ] && nsenter -t 1 -m -- cp -a "$odm_src/." "$rw/odm_upper/"
  odm_etc_src="$CAM_DIR/odm/vendor/etc"
  if [ -d "$odm_etc_src" ]; then
    nsenter -t 1 -m -- cp -a /odm/vendor/etc/. "$rw/odm_etc_upper/" 2>/dev/null
    nsenter -t 1 -m -- cp -a "$odm_etc_src/." "$rw/odm_etc_upper/" || return 1
  fi

  if [ -x /system/bin/chcon ]; then
    nsenter -t 1 -m -- chcon -R u:object_r:system_lib_file:s0 \
      "$rw/ext_upper" "$rw/sys_upper" 2>/dev/null
    nsenter -t 1 -m -- chcon -R u:object_r:same_process_hal_file:s0 \
      "$rw/odm_upper" 2>/dev/null
    nsenter -t 1 -m -- chcon -R u:object_r:vendor_configs_file:s0 \
      "$rw/odm_etc_upper" 2>/dev/null
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
  if [ -d "$odm_etc_src" ]; then
    nsenter -t 1 -m -- mount -t overlay overlay \
      -o "lowerdir=/odm/vendor/etc,upperdir=$rw/odm_etc_upper,workdir=$rw/odm_etc_work" \
      /odm/vendor/etc || log "camera: odm etc overlay failed"
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
  # starts; the source is on /data, so the policy also allows the nosuid init
  # transition for this one service.
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
  if ! pm path com.coloros.gallery3d >/dev/null 2>&1; then
    out=$(pm install -r "$CAM_DIR/priv-app/ColorOSGalleryStub/ColorOSGalleryStub.apk" 2>&1)
    log "camera: gallery stub install ${out:-ok}"
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
  cmd role remove-role-holder android.app.role.SYSTEM_CAMERA com.android.camera 0 >/dev/null 2>&1
  out=$(cmd role add-role-holder android.app.role.SYSTEM_CAMERA com.oplus.camera 0 2>&1)
  log "camera: role ${out:-ok}"
}
