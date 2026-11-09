#!/usr/bin/env python3
"""Zip a KSU module tree, reusing entry order and permissions from a base zip.

usage: pack_ksu_module.py <module-dir> <base.zip> <out.zip>

Entries present in the base zip keep its order and external attributes (so
scripts stay executable); new files are appended sorted, mode 0644.
"""
import os
import sys
import zipfile


def main(root, base, out):
    with zipfile.ZipFile(base) as zin:
        infos = zin.infolist()
    attrs = {i.filename: i.external_attr for i in infos}
    files = []
    for d, _, names in os.walk(root):
        for name in names:
            files.append(os.path.relpath(os.path.join(d, name), root).replace(os.sep, "/"))
    present = set(files)
    order = [i.filename for i in infos
             if i.filename in present
             or (i.filename.endswith("/") and any(f.startswith(i.filename) for f in files))]
    order += sorted(f for f in files if f not in attrs)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
        for name in order:
            if name.endswith("/"):
                info = zipfile.ZipInfo(name)
                info.external_attr = attrs[name]
                zout.writestr(info, b"")
                continue
            path = os.path.join(root, name)
            info = zipfile.ZipInfo.from_file(path, name)
            info.external_attr = attrs.get(name, 0o100644 << 16)
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as fh:
                zout.writestr(info, fh.read(), compresslevel=6)
    print("%d files -> %s" % (len(files), out))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
