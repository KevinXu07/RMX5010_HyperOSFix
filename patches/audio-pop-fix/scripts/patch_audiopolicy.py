#!/usr/bin/env python3
"""
RMX5010_HyperOSFix: Audio Pop / Standby Loop Fix for Realme GT7 Pro
Target: /system_ext/lib64/libaudiopolicymanagerimpl.so

Root Cause:
  MIUI's AudioPolicyManagerImpl::setAppNameParameter pushes vendor parameter "appname=±包名"
  to the audio output stream on every AudioTrack create/destroy. Realme GT7 Pro's QTI Audio HAL
  (libaudiocorehal.qti.so) does not support this parameter, returning failure on
  StreamHalAidl::parseAndSetVendorParameters. AudioFlinger then forces the output stream into
  standby and reconstructs it, power-cycling the speaker amplifier and producing a loud "pop/beep"
  noise (11+ and 12- failed attempts per session).

Fix:
  Patch AudioPolicyManagerImpl::setAppNameParameter at offset 0x3d918:
    0x3d914: 5f 24 03 d5 (BTI c - preserved for ARMv8.5-A Branch Target Identification)
    0x3d918: 28 00 40 f9 (LDR X8, [X1]) -> replaced with c0 03 5f d6 (RET)
  The function returns immediately with zero side-effects.
"""

import sys
import os

EXPECTED_SHA_ORIG = "f3a9aed6141a04ec471842ecb952bda43f01b089c1d0be6ffbf16cb488661665"
PATCH_OFFSET = 0x3d918
EXPECTED_ORIG_BYTES = bytes.fromhex("280040f9")
REPLACEMENT_BYTES = bytes.fromhex("c0035fd6")

def patch_file(in_path: str, out_path: str):
    if not os.path.isfile(in_path):
        print(f"ERROR: Input file not found: {in_path}", file=sys.stderr)
        sys.exit(1)

    with open(in_path, "rb") as f:
        data = bytearray(f.read())

    # Check bounds
    if len(data) < PATCH_OFFSET + 4:
        print(f"ERROR: File size {len(data)} too small for offset {PATCH_OFFSET:#x}", file=sys.stderr)
        sys.exit(1)

    # Verify BTI c before patch
    bti_bytes = bytes(data[PATCH_OFFSET-4:PATCH_OFFSET])
    if bti_bytes != bytes.fromhex("5f2403d5"):
        print(f"WARNING: Instruction preceding patch ({bti_bytes.hex()}) is not BTI c (5f2403d5)", file=sys.stderr)

    # Verify original instruction
    actual_bytes = bytes(data[PATCH_OFFSET:PATCH_OFFSET+4])
    if actual_bytes != EXPECTED_ORIG_BYTES:
        if actual_bytes == REPLACEMENT_BYTES:
            print(f"NOTICE: File at {in_path} is ALREADY patched at {PATCH_OFFSET:#x} (RET)")
            return
        print(f"ERROR: Unexpected bytes at {PATCH_OFFSET:#x}: {actual_bytes.hex()} (expected {EXPECTED_ORIG_BYTES.hex()})", file=sys.stderr)
        sys.exit(1)

    # Apply patch
    data[PATCH_OFFSET:PATCH_OFFSET+4] = REPLACEMENT_BYTES

    with open(out_path, "wb") as f:
        f.write(data)

    print(f"Successfully patched {in_path} -> {out_path}")
    print(f"  Offset: {PATCH_OFFSET:#x}")
    print(f"  Old bytes: {actual_bytes.hex()} (LDR X8, [X1])")
    print(f"  New bytes: {REPLACEMENT_BYTES.hex()} (RET)")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: patch_audiopolicy.py <input_libaudiopolicymanagerimpl.so> [output_path]")
        sys.exit(1)
    in_p = sys.argv[1]
    out_p = sys.argv[2] if len(sys.argv) > 2 else in_p
    patch_file(in_p, out_p)
