#!/usr/bin/env python3
"""Extract verified full-OTA partitions directly from a raw payload.bin (no zip wrapper)."""
import argparse, bz2, hashlib, json, lzma, mmap, pathlib, struct

def varint(buf, pos):
    value = shift = 0
    while True:
        byte = buf[pos]; pos += 1
        value |= (byte & 127) << shift
        if byte < 128: return value, pos
        shift += 7
        if shift > 70: raise ValueError('invalid protobuf varint')

def fields(buf):
    out = {}; pos = 0
    while pos < len(buf):
        tag, pos = varint(buf, pos); number, wire = tag >> 3, tag & 7
        if wire == 0: value, pos = varint(buf, pos)
        elif wire == 2:
            size, pos = varint(buf, pos); value = buf[pos:pos+size]; pos += size
        elif wire == 1: value = buf[pos:pos+8]; pos += 8
        elif wire == 5: value = buf[pos:pos+4]; pos += 4
        else: raise ValueError(f'unsupported protobuf wire {wire}')
        out.setdefault(number, []).append(value)
    return out

def one(f, n, default=None): return f.get(n, [default])[0]

def run():
    ap = argparse.ArgumentParser()
    ap.add_argument('payload'); ap.add_argument('output'); ap.add_argument('--only', nargs='*')
    ap.add_argument('--list', action='store_true'); args = ap.parse_args()
    dest = pathlib.Path(args.output); dest.mkdir(parents=True, exist_ok=True)
    with open(args.payload, 'rb') as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
        magic, version, manifest_size = struct.unpack_from('>4sQQ', data, 0)
        if magic != b'CrAU' or version != 2: raise ValueError('not v2 payload')
        sig_size = struct.unpack_from('>I', data, 20)[0]
        manifest = fields(data[24:24+manifest_size]); block = one(manifest, 3, 4096)
        payload_data = 24 + manifest_size + sig_size
        records = []
        for pbuf in manifest.get(13, []):
            p = fields(pbuf); name = one(p, 1).decode(); info = fields(one(p, 7, b''))
            operations = [fields(op) for op in p.get(8, [])]
            types = sorted(set(one(op, 1) for op in operations))
            records.append({'name': name, 'size': one(info, 1), 'sha256': one(info, 2, b'').hex(), 'operations': len(operations), 'operation_types': types})
        report = {'input': args.payload, 'block_size': block, 'manifest_size': manifest_size, 'partitions': records}
        (dest/'payload_manifest.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print(json.dumps(records, indent=2), flush=True)
        if args.list: return
        for pbuf, record in zip(manifest.get(13, []), records):
            name = record['name']
            if args.only is not None and name not in args.only: continue
            image = dest/(name+'.img')
            if image.exists() and image.stat().st_size == record['size']:
                with image.open('rb') as f: digest = hashlib.file_digest(f, 'sha256').hexdigest()
                if digest == record['sha256']: print(f'SKIP_VERIFIED {name}', flush=True); continue
            p = fields(pbuf)
            with image.open('wb') as out:
                out.truncate(record['size'])
                for opbuf in p.get(8, []):
                    op = fields(opbuf); typ = one(op, 1)
                    length = one(op, 3, 0); offset = one(op, 2, 0)
                    blob = data[payload_data+offset:payload_data+offset+length]
                    expected = one(op, 8)
                    if expected is not None and hashlib.sha256(blob).digest() != expected: raise ValueError(f'data hash mismatch {name}')
                    extents = [fields(x) for x in op.get(6, [])]
                    if typ == 0: decoded = blob
                    elif typ == 1: decoded = bz2.decompress(blob)
                    elif typ == 8: decoded = lzma.decompress(blob)
                    elif typ in (6, 7): decoded = None
                    else: raise ValueError(f'unsupported non-full-OTA operation {typ} in {name}')
                    cursor = 0
                    for extent in extents:
                        start = one(extent, 1)*block; count = one(extent, 2)*block
                        out.seek(start)
                        if decoded is None:
                            out.write(bytes(count))
                        else:
                            chunk = decoded[cursor:cursor+count]
                            if len(chunk) != count: raise ValueError(f'extent size mismatch {name}')
                            out.write(chunk); cursor += count
            with image.open('rb') as f: digest = hashlib.file_digest(f, 'sha256').hexdigest()
            if digest != record['sha256']: raise ValueError(f'partition hash mismatch {name}: {digest}')
            print(f'EXTRACT_VERIFIED {name} {record["size"]} {digest}', flush=True)

if __name__ == '__main__': run()
