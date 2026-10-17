import os, sys

base_ctx = "/home/ubuntu/rom/os4/wm/odm_mkfs_contexts"
stage = "/home/ubuntu/rom/os4/work_camera_odm/stage"
out_ctx = "/home/ubuntu/rom/os4/work_camera_odm/clean_odm_contexts"

keep, missing = [], []
for line in open(base_ctx, encoding="utf-8"):
    parts = line.strip().split()
    if not parts:
        continue
    pattern = parts[0]
    # Remove regex escape backslashes
    clean_path = pattern.replace(r"\.", ".").replace(r"\-", "-").replace(r"\_", "_").replace(r"\+", "+")
    rel = clean_path[len("/odm"):].lstrip("/")
    local_path = os.path.join(stage, rel) if rel else stage
    if os.path.exists(local_path) or os.path.islink(local_path):
        keep.append(line)
    else:
        missing.append((clean_path, pattern))

print(f"Total entries: {len(keep) + len(missing)}")
print(f"Retained: {len(keep)}")
print(f"Missing: {len(missing)}")
for m in missing:
    print("Missing:", m)

open(out_ctx, "w", encoding="utf-8").write("".join(keep))
print("Wrote clean contexts to:", out_ctx)
