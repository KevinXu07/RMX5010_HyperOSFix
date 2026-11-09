#!/usr/bin/env python3
"""Patch the RMX5010 ODM lib2DSlender.so for the OplusCamera port.

lib2DSlender.so (face slimming / AI deblemish, md5 ec189586...) is loaded
into the camera app's classloader namespace through our libvndksupport stub.
Two independent problems are fixed here.

1. ODNN dlopen path (movie mode SIGSEGV)
   AiFaceOdnn builds the ODNN path as std::string("/odm/lib64") +
   "/libODNN.so" and dlopens it; /odm is not accessible from that
   namespace, the handle stays NULL and AiFaceOdnn::initModel dereferences
   it (SIGSEGV on PreviewGLThread, e.g. when entering movie mode).
     * the two inline SSO constructions of "/odm/lib64" (aiface::AiFaceOdnn::
       initModel and aiface::initThreadCallBack) get length 0 instead of 10:
       `mov w8, #0x14` -> `mov w8, #0x0` at file offsets 0xee138 / 0xee76c;
     * the appended suffix "/libODNN.so" (0x2f8e4) becomes "libODNN.so".
   The result is dlopen("libODNN.so"), which resolves to the copy the module
   places in /product/priv-app/OplusCamera/lib/arm64 (with libzlib.so).

2. Preview face-beauty NULL dereference (launch / front camera SIGSEGV)
   VideoBeautyEditionOne::process (file offset 0xf3fc8) validates its
   op_param_data_t argument at +8 / +0x10 / +0x20 / +0x28 and then calls
   adjustParam(), which reads the optional per-face custom-params array at
   op_param_data_t+0x78 unconditionally:
       f4020  ldr  x8, [x22, #0x28]      <- last validation
       ...
       ee06c  ldr  x15, [x21, #0x78]     <- optional array (NULL here)
       ee070  ldr  w15, [x15, x8]        <- SIGSEGV, fault addr 0
   The preview JNI (APSPreviewProcess::process in
   libApsFaceBeautyPreviewJni.so) builds that struct on the stack and never
   sets +0x78, so the beauty preview path always faults on PreviewGLThread
   as soon as it runs (front camera / portrait mode with a face in view).
   Since the loop count is clamped to at least 4 (csel at 0xedd60) the
   block is reached even with zero faces.

   Fix: make the last validation test the optional array instead:
       f4020  ldr  x8, [x22, #0x78]
   A caller that does not provide the custom-params array now takes the
   existing "invalid param" early return (-1) instead of entering
   adjustParam(); callers that do provide it are unaffected.  Callers that
   reach adjustParam() always set +0x28 (adjustParam dereferences it), so
   dropping that particular check cannot let a NULL +0x28 through.

usage: patch_lib2dslender.py <in.so> <out.so>
"""
import hashlib
import struct
import sys

SRC_MD5 = "ec189586050cfab7fe29b2148c03a266"
MOV_W8_0X14 = 0x52800288
MOV_W8_0 = 0x52800008
LDR_X8_X22_0X28 = 0xF94016C8  # ldr x8, [x22, #0x28]
LDR_X8_X22_0X78 = 0xF9403EC8  # ldr x8, [x22, #0x78]
PREVIEW_CHECK_OFF = 0xE4020


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
    if struct.unpack_from("<I", data, PREVIEW_CHECK_OFF)[0] != LDR_X8_X22_0X28:
        sys.exit("preview check mismatch at 0x%x" % PREVIEW_CHECK_OFF)
    struct.pack_into("<I", data, PREVIEW_CHECK_OFF, LDR_X8_X22_0X78)
    open(dst, "wb").write(data)
    print("patched", dst, hashlib.md5(data).hexdigest())


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
