#!/usr/bin/env python3
"""Make the RMX5010 ODM lib2DSlender.so load libODNN.so by name.

lib2DSlender.so (face slimming / AI deblemish, md5 ec189586...) is loaded
into the camera app's classloader namespace through our libvndksupport stub.
AiFaceOdnn builds the ODNN path as std::string("/odm/lib64") +
"/libODNN.so" and dlopens it; /odm is not accessible from that namespace,
the handle stays NULL and AiFaceOdnn::initModel dereferences it (SIGSEGV on
PreviewGLThread, e.g. when entering movie mode).

Patch:
  * the two inline SSO constructions of "/odm/lib64" (aiface::AiFaceOdnn::
    initModel and aiface::initThreadCallBack) get length 0 instead of 10:
    `mov w8, #0x14` -> `mov w8, #0x0` at file offsets 0xee138 / 0xee76c;
  * the appended suffix "/libODNN.so" (0x2f8e4) becomes "libODNN.so".

The result is dlopen("libODNN.so"), which resolves to the copy the module
places in /product/priv-app/OplusCamera/lib/arm64 (with libzlib.so).

usage: patch_lib2dslender_odnn.py <in.so> <out.so>
"""
import hashlib
import struct
import sys

SRC_MD5 = "ec189586050cfab7fe29b2148c03a266"
MOV_W8_0X14 = 0x52800288
MOV_W8_0 = 0x52800008


def main(src, dst):
    data = bytearray(open(src, "rb").read())
    digest = hashlib.md5(data).hexdigest()
    if digest != SRC_MD5:
        sys.exit("unexpected input md5 %s (want %s)" % (digest, SRC_MD5))
    for off in (0xEE138, 0xEE76C):
        if struct.unpack_from("<I", data, off)[0] != MOV_W8_0X14:
            sys.exit("instruction mismatch at 0x%x" % off)
        struct.pack_into("<I", data, off, MOV_W8_0)
    if data[0x2F8E4:0x2F8F0] != b"/libODNN.so\x00":
        sys.exit("suffix string mismatch")
    data[0x2F8E4:0x2F8F0] = b"libODNN.so\x00\x00"
    open(dst, "wb").write(data)
    print("patched", dst, hashlib.md5(data).hexdigest())


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
