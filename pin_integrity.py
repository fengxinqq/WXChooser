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


def locate(data: bytes) -> int:
    idx = data.find(MAGIC)
    if idx < 0:
        raise SystemExit("未找到 WXPIN1 锚点，源码里 kWXIntegrityPin 丢了？")
    start = idx + len(MAGIC)
    slot = data[start:start + PIN_LEN]
    if len(slot) != PIN_LEN:
        raise SystemExit("锚点长度不足")
    return start


def compute(data: bytes, start: int) -> str:
    buf = bytearray(data)
    buf[start:start + PIN_LEN] = b"0" * PIN_LEN
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
