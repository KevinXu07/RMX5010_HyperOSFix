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

2. Preview face-beauty NULL dereference (beauty on -> SIGSEGV / black preview)
   VideoBeautyEditionOne::process -> adjustParam (virtual 0xedd2c)
   reads the optional per-face custom-params array at op_param_data_t+0x78
   unconditionally, five ints per face with stride 0x94:

       edd4c  ldr  w8, [x1, #4]        ; caller's count
       edd60  csel w8, w8, #4, lt      ; count = max(count, 4)  -> always >= 4
       ee06c  ldr  x15, [x21, #0x78]   ; custom array (NULL here)
       ee070  ldr  w15, [x15, x8]      ; SIGSEGV, fault addr 0

   (virtual addresses; .text is mapped 0x10000 above its file offset, so
   0xee06c is file offset 0xde06c.)

   The OplusCamera 6.070.45 preview JNI (APSPreviewProcess::process in
   libApsFaceBeautyPreviewJni.so) builds that struct on the stack and never
   sets +0x78 (the field is inside the zeroed block at sp+0x1e8..0x207 and
   is never written), so the beauty preview path faults on PreviewGLThread
   as soon as beauty is enabled, with or without a face in view.

   Simply rejecting the call is not an option: the JNI drops the frame when
   Slender2D_process returns non-zero, which turns the preview black in
   every mode.  Instead the five +0x78 loads are redirected to the main
   per-face parameter array at +0x28:

       ee06c  ldr  x15, [x21, #0x28]
       ...    (same at 0xee084 / 0xee0a0 / 0xee0bc / 0xee0dc)

   +0x28 is validated non-NULL by VideoBeautyEditionOne::process before
   adjustParam is reached, it holds the same kind of 0..100 beauty values,
   and every value read here is clamped (csel/bic) before use, so the
   per-face overrides simply fall back to the user's global beauty
   settings instead of crashing.  Callers that do provide a +0x78 array
   lose their per-face overrides, but no caller in this app provides one.

usage: patch_lib2dslender.py <in.so> <out.so>
"""
import hashlib
import struct
import sys

SRC_MD5 = "ec189586050cfab7fe29b2148c03a266"
MOV_W8_0X14 = 0x52800288
MOV_W8_0 = 0x52800008
LDR_X15_X21_0X78 = 0xF9403EAF  # ldr x15, [x21, #0x78]
LDR_X15_X21_0X28 = 0xF94016AF  # ldr x15, [x21, #0x28]
CUSTOM_PARAM_LOADS = (0xDE06C, 0xDE084, 0xDE0A0, 0xDE0BC, 0xDE0DC)


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
    for off in CUSTOM_PARAM_LOADS:
        if struct.unpack_from("<I", data, off)[0] != LDR_X15_X21_0X78:
            sys.exit("custom param load mismatch at 0x%x" % off)
        struct.pack_into("<I", data, off, LDR_X15_X21_0X28)
    open(dst, "wb").write(data)
    print("patched", dst, hashlib.md5(data).hexdigest())


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
