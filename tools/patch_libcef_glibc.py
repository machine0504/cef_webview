#!/usr/bin/env python3
"""把 ELF 库对 libm 的 GLIBC_2.29 版本化引用降级为 GLIBC_2.17。

背景：CEF99 官方 linuxarm64 的 libcef.so 引用 exp/exp2/log/log2/pow@GLIBC_2.29，
在 glibc <= 2.28（统信 UOS V20 / 麒麟）上 dlopen 直接报
  "version `GLIBC_2.29' not found"
——这是 ELF verneed 检查，发生在符号解析之前，引擎里的数学垫片无法补救。

这些函数在 GLIBC_2.17（aarch64 基线版本）中同名存在（旧实现精度略低，
对 CEF 无影响），且 "GLIBC_2.29" 与 "GLIBC_2.17" 等长，可安全原地替换：
  1. .dynstr  中 "GLIBC_2.29" -> "GLIBC_2.17"
  2. .gnu.version_r 中对应 Vernaux 的 vna_hash 更新为新字符串的 ELF hash

用法: patch_libcef_glibc.py <libcef.so 路径>   （原地修改，先自行备份）
"""
import struct
import sys

OLD, NEW = b"GLIBC_2.29", b"GLIBC_2.17"


def elf_hash(name: bytes) -> int:
    h = 0
    for c in name:
        h = (h << 4) + c
        g = h & 0xF0000000
        if g:
            h ^= g >> 24
        h &= ~g & 0xFFFFFFFF
    return h


def main(path: str) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    if data[:4] != b"\x7fELF" or data[4] != 2:
        print("不是 ELF64 文件", file=sys.stderr)
        return 1

    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    def sh(i):
        base = e_shoff + i * e_shentsize
        name_off, sh_type = struct.unpack_from("<II", data, base)
        sh_offset = struct.unpack_from("<Q", data, base + 0x18)[0]
        sh_size = struct.unpack_from("<Q", data, base + 0x20)[0]
        return name_off, sh_type, sh_offset, sh_size

    shstr_off = sh(e_shstrndx)[2]

    def sec_name(name_off):
        end = data.index(b"\x00", shstr_off + name_off)
        return data[shstr_off + name_off:end].decode()

    dynstr = verneed = None
    for i in range(e_shnum):
        name_off, _, off, size = sh(i)
        n = sec_name(name_off)
        if n == ".dynstr":
            dynstr = (off, size)
        elif n == ".gnu.version_r":
            verneed = (off, size)
    if not dynstr or not verneed:
        print("缺少 .dynstr 或 .gnu.version_r 节", file=sys.stderr)
        return 1

    # 1) .dynstr 内替换版本名（等长）
    ds_off, ds_size = dynstr
    region = data[ds_off:ds_off + ds_size]
    n_str = region.count(OLD)
    data[ds_off:ds_off + ds_size] = region.replace(OLD, NEW)

    # 2) .gnu.version_r 内更新 vna_hash
    h_old, h_new = elf_hash(OLD), elf_hash(NEW)
    vr_off, vr_size = verneed
    n_hash = 0
    pos = vr_off
    while True:
        vn_cnt = struct.unpack_from("<H", data, pos + 2)[0]
        vn_aux = struct.unpack_from("<I", data, pos + 8)[0]
        vn_next = struct.unpack_from("<I", data, pos + 12)[0]
        aux = pos + vn_aux
        for _ in range(vn_cnt):
            vna_hash = struct.unpack_from("<I", data, aux)[0]
            vna_next = struct.unpack_from("<I", data, aux + 12)[0]
            if vna_hash == h_old:
                struct.pack_into("<I", data, aux, h_new)
                n_hash += 1
            if vna_next == 0:
                break
            aux += vna_next
        if vn_next == 0:
            break
        pos += vn_next

    if n_str == 0 and n_hash == 0:
        print("未发现 GLIBC_2.29 引用（可能已打过补丁），未修改")
        return 0

    with open(path, "wb") as f:
        f.write(data)
    print(f"OK: 替换字符串 {n_str} 处, 更新 vna_hash {n_hash} 处 -> {path}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    sys.exit(main(sys.argv[1]))
