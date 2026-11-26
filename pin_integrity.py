#!/usr/bin/env python3
"""把 dylib 里的 WXPIN1 锚点填成「将该 64 字节归零后整文件的 SHA-256」。

用法：
  python3 tools/pin_integrity.py <dylib 路径> [--verify]

--verify 只校验不写入；不一致时退出码 1。
"""
import hashlib
import sys

MAGIC = b"WXPIN1"
PIN_LEN = 64


HEX = set(b"0123456789abcdefABCDEF")


def locate(data: bytes) -> int:
    """找锚点：后面跟 64 个十六进制字符、再跟一个 0 字节。
    代码里可能还有一处 "WXPIN1" 字面量，靠这个条件排除掉。"""
    candidates = []
    i = data.find(MAGIC)
    while i >= 0:
        start = i + len(MAGIC)
        slot = data[start:start + PIN_LEN]
        term = data[start + PIN_LEN:start + PIN_LEN + 1]
        if len(slot) == PIN_LEN and term == b"\x00" and all(c in HEX for c in slot):
            candidates.append(start)
        i = data.find(MAGIC, i + 1)
    if not candidates:
        raise SystemExit("未找到有效锚点（WXPIN1 + 64 位十六进制），源码里 kWXIntegrityPin 丢了？")
    if len(candidates) > 1:
        raise SystemExit(f"锚点候选不止一处：{candidates}")
    return candidates[0]


LC_CODE_SIGNATURE = 0x1d


def code_limit(data: bytes) -> int:
    """哈希范围到 __LINKEDIT 的 fileoff 为止。这段是编译产物本身，
    签名重写只动 __LINKEDIT 之后的部分，不会影响它。"""
    try:
        import struct
        ncmds = struct.unpack("<I", data[16:20])[0]
        off = 32
        sig = None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
            if cmd == 0x19:  # LC_SEGMENT_64
                name = data[off + 8:off + 24]
                fileoff = struct.unpack("<Q", data[off + 40:off + 48])[0]
                if name == b"__LINKEDIT" and fileoff > 0:
                    return int(fileoff)
            elif cmd == LC_CODE_SIGNATURE:
                sig = struct.unpack("<I", data[off + 8:off + 12])[0]
            off += cmdsize
        if sig:
            return int(sig)
    except Exception:
        pass
    return len(data)


def header_end(data: bytes) -> int:
    """跳过 Mach-O 头与加载命令：重签名会改这里的段大小字段。"""
    try:
        import struct
        sizeofcmds = struct.unpack("<I", data[20:24])[0]
        return 32 + sizeofcmds
    except Exception:
        return 0


def compute(data: bytes, start: int) -> str:
    limit = code_limit(data)
    hdr = header_end(data)
    if hdr >= limit or start < hdr:
        raise SystemExit("锚点落在头/签名区，检查代码位置")
    buf = bytearray(data[hdr:limit])
    buf[start - hdr:start - hdr + PIN_LEN] = b"0" * PIN_LEN
    return hashlib.sha256(bytes(buf)).hexdigest()


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    verify = "--verify" in sys.argv[2:]
    data = open(path, "rb").read()
    start = locate(data)
    pinned = data[start:start + PIN_LEN].decode("ascii", "replace")
    actual = compute(data, start)

    if verify:
        if pinned.lower() != actual:
            print(f"[FAIL] {path}: 锚点 {pinned} 与实算 {actual} 不一致")
            raise SystemExit(1)
        print(f"[OK]   {path}: {actual}")
        return

    if pinned.lower() == actual:
        print(f"[SKIP] {path}: 锚点已经是正确的 {actual}")
        return

    new = bytearray(data)
    new[start:start + PIN_LEN] = actual.encode("ascii")
    open(path, "wb").write(bytes(new))
    check = compute(bytes(new), start)
    if check != actual:
        raise SystemExit(f"[FAIL] 写入后自检不一致 {check} != {actual}")
    print(f"[PIN]  {path}: {actual}")


if __name__ == "__main__":
    main()
