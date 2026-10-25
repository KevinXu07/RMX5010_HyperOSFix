#!/usr/bin/env bash
set -euo pipefail
P=/root/haotian/stage_h19
HX="$P/product/etc/device_features/haotian.xml"
BP="$P/product/etc/build.prop"
CV="$P/product/etc/displayconfig/display_id_4630947008615494291.xml"

echo '=== [1] haotian.xml 门禁迁移(按仓库 nezha 时代已验证清单) ==='
sed -i \
  -e 's|<item>1440</item>|<item>1264</item>|' \
  -e 's|<integer name="defaultFps">60</integer>|<integer name="defaultFps">120</integer>|' \
  -e 's|<bool name="support_screen_paper_mode">true</bool>|<bool name="support_screen_paper_mode">false</bool>|' \
  -e 's|<bool name="support_paper_eyecare">true</bool>|<bool name="support_paper_eyecare">false</bool>|' \
  -e 's|<bool name="is_rhythmic_mode_v2_supported">true</bool>|<bool name="is_rhythmic_mode_v2_supported">false</bool>|' \
  -e 's|<bool name="support_simplified_colormode">true</bool>|<bool name="support_simplified_colormode">false</bool>|' \
  -e 's|<bool name="is_compatible_paper_and_screen_effect">true</bool>|<bool name="is_compatible_paper_and_screen_effect">false</bool>|' \
  -e 's|<float name="paper_eyecare_default_value">[0-9.]*</float>|<float name="paper_eyecare_default_value">0.0</float>|' \
  "$HX"
echo "  defaultFps: $(grep -oE '<integer name="defaultFps">[0-9]+</integer>' "$HX")"
echo "  分辨率数组: $(grep -A2 screen_resolution_supported "$HX" | grep item | tr -d ' \n')"
echo "  paper_mode: $(grep -oE '<bool name="support_screen_paper_mode">[a-z]+</bool>' "$HX")"
echo "  paper_eyecare: $(grep -oE '<bool name="support_paper_eyecare">[a-z]+</bool>' "$HX")"

echo '=== [2] product build.prop 动态帧率 prop ==='
grep -q "ro.vendor.display.dynamic_refresh_rate" "$BP" || cat >> "$BP" <<'EOF'

# 2026-10-25 refresh rate: h19 底刷新率/分辨率迁移(nezha 时代已验证方案)
ro.vendor.display.dynamic_refresh_rate=120,60:100,60,5
persist.sys.miui_resolution=1264,2780,500
EOF
grep -E "dynamic_refresh_rate|miui_resolution" "$BP" | sed 's/^/  /'

echo '=== [3] 曲线:删 2 处 idleScreenRefreshRateTimeout 块 ==='
python3 - "$CV" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
n = len(re.findall(r'<idleScreenRefreshRateTimeout', s))
s2 = re.sub(r'\s*<idleScreenRefreshRateTimeout\b[^>]*(/>|>.*?</idleScreenRefreshRateTimeout>)', '', s, flags=re.S)
open(sys.argv[1], 'w', encoding='utf-8').write(s2)
print(f"  删除块数: {n}  残留: {len(re.findall(r'idleScreenRefreshRateTimeout', s2))}")
PY
python3 -c "import xml.etree.ElementTree as ET; ET.parse('$CV'); print('  曲线 XML 语法 OK')"

echo '=== [4] 重建 product.img ==='
CTXF="$P/all_file_contexts"
cat "$P/system/system/etc/selinux/plat_file_contexts" \
    "$P/system_ext/etc/selinux/system_ext_file_contexts" \
    "$P/product/etc/selinux/product_file_contexts" > "$CTXF"
mkfs.erofs --quiet -zlz4hc -b4096 -T0 --mount-point=/product \
  --file-contexts="$CTXF" /root/haotian/product_refresh.raw.img "$P/product" >/dev/null 2>&1
fsck.erofs /root/haotian/product_refresh.raw.img >/dev/null && echo "  product fsck OK"
img2simg /root/haotian/product_refresh.raw.img /mnt/e/code/modify/haotian_work/product_refresh.img 4096
ls -la /mnt/e/code/modify/haotian_work/product_refresh.img | awk '{print "  copied:", $5}'
echo REFRESH_BUILD_DONE
