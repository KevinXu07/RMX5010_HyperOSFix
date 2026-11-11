#!/usr/bin/env python3
"""Patch the RMX5010 ODM libAF.so so the telephoto can focus at infinity.

Symptom (HyperOS port, OplusCamera 6.070.45): the 3x periscope focuses fine
up close (1 m) but every subject beyond ~1.5 m is soft, with AF and with
pro-mode manual focus at infinity alike.  The HAL reports the lens parked
at actuator DAC 466-473 / focus distance 0.66-0.69 dpt (~1.5 m) while the
factory af_code calibration puts infinity at DAC 297.

libAF.so (Oplus AF core, md5 b39b7173..., /odm/lib64) sets the AF search
limits in the routine at 0x3b6e0 ("Set Focus Limit,focusMode..."):

    3b790  ldr  x10, [x9, x8]       ; tuning block (state + 0x13afd0)
    3b794  ldr  w10, [x10, #0x7c]   ; near limit
    3b7a4  ldr  w10, [x10, #0x80]   ; far limit      -> state->0x94
    3b7b4  ldr  w8,  [x8,  #0x84]   ; default pos    -> state->0x98
    ...
    3b814  bl   0x41128             ; TemperatureOffset(defaultPos)
    3b820  str  w0, [x8, #0x98]
    3b82c  ldr  w1, [x8, #0x94]
    3b830  bl   0x41128             ; TemperatureOffset(farLimit)
    3b838  str  w0, [x8, #0x94]     ; <- patched to NOP

and the lens target is clamped against it right before it is sent to the
actuator (0x6a8c0: final = min(target + sagComp, farLimit)).

0x41128 shifts positions by a lens/sensor temperature model (interpolated
over -60..45 C).  On this port its temperature input is wrong (ColorOS feeds
it through its thermal stack, which HyperOS does not have; removing the
ColorOS thermal service reproduces the same telephoto symptom), and the
far limit is pulled ~170 logical steps towards macro.  Skipping only the
write-back of the offset far limit keeps the tuning's own far end (which
already includes the module calibration) and leaves near limit, default
position, sag compensation and PDAF untouched.

Verified on device: far subject (~5 m) at 3x/10x goes from DAC 466 /
0.66 dpt (blurry) to DAC 383-390 / 0.32-0.34 dpt (sharp).

(.text is mapped 0x10000 above its file offset: 0x3b838 is file 0x2b838.)

usage: patch_libaf_farlimit.py <in.so> <out.so>
"""
import hashlib
import struct
import sys

SRC_MD5 = "b39b717329767f76e4d656f395ccde53"
OUT_MD5 = "aeaa3fc80730bb8ec82d4e3eafb0eb33"
PATCH_VADDR = 0x3B838
TEXT_DELTA = 0x10000
ORIG = 0xB9009500   # str w0, [x8, #0x94]
NOP = 0xD503201F


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1])
        return 2
    data = bytearray(open(sys.argv[1], "rb").read())
    md5 = hashlib.md5(data).hexdigest()
    if md5 != SRC_MD5:
        print(f"unexpected input md5 {md5} (want {SRC_MD5})")
        return 1
    off = PATCH_VADDR - TEXT_DELTA
    cur = struct.unpack_from("<I", data, off)[0]
    if cur != ORIG:
        print(f"unexpected instruction {cur:#010x} at file {off:#x}")
        return 1
    struct.pack_into("<I", data, off, NOP)
    out = hashlib.md5(data).hexdigest()
    if out != OUT_MD5:
        print(f"unexpected output md5 {out} (want {OUT_MD5})")
        return 1
    open(sys.argv[2], "wb").write(data)
    print(f"patched {sys.argv[2]} md5 {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
