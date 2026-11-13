#!/usr/bin/env python3
"""Rebuild the displayconfig brightness tables from the panel's stock calibration.

    python scripts/gen_brightness_map.py <apollo.xml> <display_brightness_config_common.xml> \
        <base display_id_*.xml> <out.xml> [lux_table_id=44]

apollo.xml: /my_product/vendor/etc/display_apollo_list_AB849_P_1_A0022_dsc_cmd_mode_panel.xml
    (stock ColorOS; rows are level, src DBV, real DBV, 6 color coeffs, nits).
common.xml: /system_ext/etc/display_brightness_config_common.xml (lux_table id 44 = lux,nits).

HyperOS writes DBV = brightness * 4093 + 1 (linear, no Apollo remap), so:
  - screenBrightnessMap gets the real DBV->nits curve (the stock vendor copy reported
    roughly double the nits this panel emits);
  - luxToBrightnessMapping gets, for each lux point, the brightness whose real nits equal
    the ColorOS lux_table target.
"""
import bisect
import re
import sys


def load_dbv_nits(path):
    s = open(path, encoding='utf-8').read()
    rows = [[x.strip() for x in l.split(',')]
            for l in re.findall(r'<Level>(.*?)</Level>', s, flags=re.S)]
    pts = sorted({(int(r[2]), float(r[-1])) for r in rows})
    d_list, n_list = [], []
    for d, n in pts:
        if d > 0 and (not n_list or (d > d_list[-1] and n > n_list[-1])):
            d_list.append(d)
            n_list.append(n)
    return d_list, n_list


def interp(xs, ys, x):
    i = bisect.bisect_left(xs, x)
    i = max(1, min(i, len(xs) - 1))
    return ys[i - 1] + (ys[i] - ys[i - 1]) * (x - xs[i - 1]) / (xs[i] - xs[i - 1])


def main():
    apollo, common, base, out = sys.argv[1:5]
    table_id = sys.argv[5] if len(sys.argv) > 5 else '44'
    dbv, nits = load_dbv_nits(apollo)

    def nits_for(d):
        if d <= dbv[0]:
            return nits[0] * d / dbv[0]
        return interp(dbv, nits, d)

    # screenBrightnessMap: dense below DBV 256, every 32 above.
    samples = [1, 4, 8] + list(range(16, 256, 16)) + list(range(256, 4094, 32)) + [4094]
    bmap, last = [], -1.0
    for d in samples:
        n = 0.2289 if d == 1 else nits_for(d)
        if n > last:
            bmap.append(((d - 1) / 4093, n))
            last = n

    c = open(common, encoding='utf-8').read()
    t = re.search(r'<lux_table id="%s">(.*?)</lux_table>' % table_id, c, re.S).group(1)
    lux_nits = {float(a): float(b) for a, b in
                (x.split(',') for x in re.findall(r'<lux>(.*?)</lux>', t))}

    x = open(base, encoding='utf-8').read()
    m = re.search(r'(<screenBrightnessMap[^>]*>)(.*?)(\s*</screenBrightnessMap>)', x, re.S)
    ind = '\n    '
    body = ''.join(f'{ind}<point>{ind}  <value>{v:.6f}</value>{ind}  <nits>{n:.4f}</nits>{ind}</point>'
                   for v, n in bmap)
    x = x[:m.start()] + m.group(1) + body + m.group(3) + x[m.end():]

    def rep(mm):
        lux = float(mm.group(2))
        v = (interp(nits, dbv, lux_nits[lux]) - 1) / 4093
        return f'{mm.group(1)}{mm.group(2)}{mm.group(3)}{v:.8f}{mm.group(5)}'

    blk = re.search(r'<luxToBrightnessMapping>.*?</luxToBrightnessMapping>', x, re.S)
    nb = re.sub(r'(<first>\s*)([\d.]+)(\s*</first>\s*<second>\s*)([\d.]+)(\s*</second>)', rep, blk.group(0))
    x = x[:blk.start()] + nb + x[blk.end():]
    open(out, 'w', encoding='utf-8', newline='').write(x)
    print(f'{out}: {len(bmap)} map points, {len(lux_nits)} lux points')


if __name__ == '__main__':
    main()
