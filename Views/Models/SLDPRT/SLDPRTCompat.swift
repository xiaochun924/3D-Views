//
//  SLDPRTCompat.swift
//  Views
//
//  SLDPRT（SolidWorks 零件）→ STEP 转换器的最底层支撑：字节读取、UTF-16 解码、
//  zlib / 裸 DEFLATE 解压封装。
//
//  ── 来源与许可（Apache License 2.0）────────────────────────────────────────
//  本文件是 “sldprt2step” 的 Swift 移植版的一部分。
//    上游项目：sldprt2step — https://github.com/BlinkingSun/sldprt2step
//    上游作者：BlinkingSun
//    上游许可：Apache License 2.0
//    对应源文件：sldprt2step_lib/jscompat.py
//
//  sldprt2step 本身是 “open-sld-to-step” 0.1.0 的忠实 Python 移植：
//    更上游项目：open-sld-to-step（Node.js/TypeScript，Apache License 2.0）
//    洁净室声明：该实现仅依据公开规范与公开资料写成 ——
//      · [MS-CFB] Compound File Binary File Format（Microsoft 公开规范）
//      · ISO 10303（STEP）系列标准
//      · 公开的 Parasolid B-rep 拓扑文献（body → region → shell → face → loop → edge → vertex）
//      · 公开的、无分发限制的 CAD 样例文件的可观测字节结构
//        （NIST MBE PMI Validation and Conformance Testing 数据集，美国政府作品，
//          依 17 U.S.C. 105 属公有领域）
//    声明：未使用、未参考、未逆向 Dassault Systèmes、Siemens 或任何其他厂商的
//          专有源码、头文件、SDK 或 API 文档。
//
//  SolidWorks® 是 Dassault Systèmes SolidWorks Corporation 的注册商标；
//  Parasolid® 是 Siemens Industry Software Inc. 的注册商标。此处仅作标识之用。
//
//  本文件按 Apache License 2.0 分发，保留原始署名与 NOTICE。
//  ─────────────────────────────────────────────────────────────────────────
//

import Compression
import Foundation

/// 转换器内部统一的字节序列类型。对应 Python 的 `bytes`。
typealias SLBytes = [UInt8]

/// 越界读取。对应 jscompat 的 `RangeError`。
enum SLDPRTRangeError: Error {
    case outOfRange(offset: Int, size: Int, count: Int)
}

/// 解压失败或输出超出安全上限。对应 Python 的 `zlib.error`。
enum SLDPRTInflateError: Error {
    case corrupt
    case tooLarge
}

// MARK: - 小端读取（对应 jscompat.read_u32le / read_i32le / read_u16le）

@inline(__always)
func slRequire(_ buf: SLBytes, _ offset: Int, _ size: Int) throws {
    if offset < 0 || size < 0 || offset + size > buf.count {
        throw SLDPRTRangeError.outOfRange(offset: offset, size: size, count: buf.count)
    }
}

@inline(__always)
func slReadU32LE(_ buf: SLBytes, _ offset: Int) throws -> UInt32 {
    try slRequire(buf, offset, 4)
    return UInt32(buf[offset])
        | (UInt32(buf[offset + 1]) << 8)
        | (UInt32(buf[offset + 2]) << 16)
        | (UInt32(buf[offset + 3]) << 24)
}

@inline(__always)
func slReadI32LE(_ buf: SLBytes, _ offset: Int) throws -> Int32 {
    Int32(bitPattern: try slReadU32LE(buf, offset))
}

@inline(__always)
func slReadU16LE(_ buf: SLBytes, _ offset: Int) throws -> UInt16 {
    try slRequire(buf, offset, 2)
    return UInt16(buf[offset]) | (UInt16(buf[offset + 1]) << 8)
}

// MARK: - 大端读取（对应 reader.py 里的 struct.unpack_from(">…")）

@inline(__always)
func slReadI16BE(_ buf: SLBytes, _ offset: Int) throws -> Int16 {
    try slRequire(buf, offset, 2)
    return Int16(bitPattern: (UInt16(buf[offset]) << 8) | UInt16(buf[offset + 1]))
}

@inline(__always)
func slReadU16BE(_ buf: SLBytes, _ offset: Int) throws -> UInt16 {
    try slRequire(buf, offset, 2)
    return (UInt16(buf[offset]) << 8) | UInt16(buf[offset + 1])
}

@inline(__always)
func slReadI32BE(_ buf: SLBytes, _ offset: Int) throws -> Int32 {
    try slRequire(buf, offset, 4)
    let raw = (UInt32(buf[offset]) << 24)
        | (UInt32(buf[offset + 1]) << 16)
        | (UInt32(buf[offset + 2]) << 8)
        | UInt32(buf[offset + 3])
    return Int32(bitPattern: raw)
}

@inline(__always)
func slReadF64BE(_ buf: SLBytes, _ offset: Int) throws -> Double {
    try slRequire(buf, offset, 8)
    var bits: UInt64 = 0
    for i in 0..<8 {
        bits = (bits << 8) | UInt64(buf[offset + i])
    }
    return Double(bitPattern: bits)
}

// MARK: - UTF-16 小端解码（对应 jscompat.buf_to_utf16le）

/// 把 `buf[start..<end]` 按 UTF-16LE 解码成字符串；奇数长度时末字节补 0，
/// 与 Python 的 `data + b"\x00"` 行为一致。
func slUTF16LE(_ buf: SLBytes, _ start: Int, _ end: Int) -> String {
    let lo = max(0, min(buf.count, start))
    let hi = max(lo, min(buf.count, end))
    guard hi > lo else { return "" }
    var units: [UInt16] = []
    units.reserveCapacity((hi - lo + 1) / 2)
    var i = lo
    while i < hi {
        let low = UInt16(buf[i])
        let high: UInt16 = (i + 1 < hi) ? UInt16(buf[i + 1]) : 0
        units.append(low | (high << 8))
        i += 2
    }
    return String(decoding: units, as: UTF16.self)
}

// MARK: - JS 整数语义（对应 jscompat.to_int32 / to_uint32 / js_shl）

enum SLJS {
    @inline(__always)
    static func toInt32(_ v: Double) -> Int32 {
        if !v.isFinite || v == 0 { return 0 }
        let t = v.rounded(.towardZero)
        var w = t.truncatingRemainder(dividingBy: 4_294_967_296.0)
        if w < 0 { w += 4_294_967_296.0 }
        return Int32(bitPattern: UInt32(w))
    }

    @inline(__always)
    static func toUInt32(_ v: Double) -> UInt32 {
        if !v.isFinite || v == 0 { return 0 }
        let t = v.rounded(.towardZero)
        var w = t.truncatingRemainder(dividingBy: 4_294_967_296.0)
        if w < 0 { w += 4_294_967_296.0 }
        return UInt32(w)
    }

    /// 对应 jscompat.js_shl：先归一到 int32，左移，再按 32 位回绕。
    @inline(__always)
    static func shl(_ a: Int, _ b: Int) -> Int {
        let shift = Int(UInt32(truncatingIfNeeded: b) & 0x1F)
        let base = Int64(toInt32(Double(a)))
        return Int(Int32(truncatingIfNeeded: base << Int64(shift)))
    }
}

// MARK: - 解压封装
//
// Python 侧用的是标准库 zlib：
//   zlib.decompress(data, -15)  →  裸 DEFLATE（RFC 1951）
//   zlib.decompress(data)       →  zlib 包装（RFC 1950：2 字节头 + DEFLATE + 4 字节 Adler-32）
// Swift 侧用系统 Compression 框架的 COMPRESSION_ZLIB —— 它按 Apple 文档就是
// **裸 DEFLATE**，正好等于 wbits=-15；zlib 包装的情形由我们自己剥头去尾。
//
// 由于 DEFLATE 的输出长度事先未知，这里采取“按提示容量解码，不够就放大重试”的策略：
//   · zlib 包装：用尾部 Adler-32 校验输出，校验不过就放大重试 —— 避免把截断结果当成功；
//   · 裸 DEFLATE：取不到校验和，只能靠容量提示 + “返回值恰好填满缓冲区即视为可能截断”。
// 容量上限做了硬约束，避免损坏输入把内存吃光。

enum SLInflate {
    private static let adlerMod: UInt32 = 65521
    private static let initialCap = 65_536
    private static let maxInitialCap = 1 << 25          // 32 MiB
    private static let maxCeilingHinted = 1 << 27       // 128 MiB
    private static let maxCeilingBlind = 1 << 24        // 16 MiB

    /// Adler-32 校验和（RFC 1950）。
    static func adler32(_ data: SLBytes) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var i = 0
        while i < data.count {
            let end = min(i + 4096, data.count)
            while i < end {
                a &+= UInt32(data[i])
                b &+= a
                i += 1
            }
            a %= adlerMod
            b %= adlerMod
        }
        return (b << 16) | a
    }

    /// 裸 DEFLATE（RFC 1951）。对应 `zlib.decompress(data, -15)`。
    static func raw(_ src: SLBytes, hint: Int = 0) throws -> SLBytes {
        try decode(src, hint: hint, expectedAdler: nil)
    }

    /// zlib 包装（RFC 1950）。对应 `zlib.decompress(data)`。
    static func zlib(_ src: SLBytes, hint: Int = 0) throws -> SLBytes {
        guard src.count > 6 else { throw SLDPRTInflateError.corrupt }
        let cmf = src[0]
        let flg = src[1]
        guard (cmf & 0x0F) == 8 else { throw SLDPRTInflateError.corrupt }
        guard (((UInt16(cmf) << 8) | UInt16(flg)) % 31) == 0 else {
            throw SLDPRTInflateError.corrupt
        }
        var start = 2
        if (flg & 0x20) != 0 { start += 4 }             // FDICT：多 4 字节字典 id
        guard src.count >= start + 5 else { throw SLDPRTInflateError.corrupt }
        let body = Array(src[start ..< (src.count - 4)])
        let stored = (UInt32(src[src.count - 4]) << 24)
            | (UInt32(src[src.count - 3]) << 16)
            | (UInt32(src[src.count - 2]) << 8)
            | UInt32(src[src.count - 1])
        return try decode(body, hint: hint, expectedAdler: stored)
    }

    private static func decode(
        _ src: SLBytes,
        hint: Int,
        expectedAdler: UInt32?
    ) throws -> SLBytes {
        guard !src.isEmpty else { return [] }
        var cap = hint > 0
            ? min(max(hint + 1024, initialCap), maxInitialCap)
            : initialCap
        let ceiling: Int
        if hint > 0 {
            ceiling = min(max(hint * 8 + 1_048_576, cap), maxCeilingHinted)
        } else {
            ceiling = maxCeilingBlind
        }
        while true {
            if let out = try attempt(src, cap: cap) {
                if let want = expectedAdler {
                    if adler32(out) == want { return out }
                } else {
                    return out
                }
            }
            if cap >= ceiling { throw SLDPRTInflateError.corrupt }
            cap = min(cap * 4, ceiling)
        }
    }

    /// 返回 nil 表示「缓冲区不够或校验不过，需要放大重试」。
    private static func attempt(_ src: SLBytes, cap: Int) throws -> SLBytes? {
        var dst = [UInt8](repeating: 0, count: cap)
        let n = src.withUnsafeBufferPointer { sp -> Int in
            guard let sb = sp.baseAddress else { return 0 }
            return dst.withUnsafeMutableBufferPointer { dp -> Int in
                guard let db = dp.baseAddress else { return 0 }
                return compression_decode_buffer(db, cap, sb, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        if n <= 0 { return nil }
        if n >= cap { return nil }                      // 可能正好填满 → 可能是被截断
        return Array(dst[0 ..< n])
    }
}
