//
//  SLDPRTContainer.swift
//  3D-Views
//
//  SLDPRT（SolidWorks 零件）容器层：在文件里找出所有 Parasolid transmit。
//
//  两种存储格式：
//    * OLE2 复合文件（SolidWorks <= 2014）：活模型是 `Config-N-Partition` 流
//      （GUID 包裹的 partition transmit，后面跟一个 deltas transmit）；
//      `Config-N` 等流里放特征/草图体。
//    * "sw3d" 扁平分节（SolidWorks 2015+）：由标记 14 00 06 00 08 00 引入的
//      zlib 分节；partition 分节与特征分节里是同样的 GUID 包裹 blob。
//
//  ── 来源与许可（Apache License 2.0）────────────────────────────────────────
//  本文件是 “sldprt2step” 的 Swift 移植版的一部分。
//    上游项目：sldprt2step — https://github.com/BlinkingSun/sldprt2step
//    上游作者：BlinkingSun
//    上游许可：Apache License 2.0
//    对应源文件：
//      sldprt2step_lib/container/blobs.py
//      sldprt2step_lib/container/sw3d.py
//      sldprt2step_lib/container/ole_cfb.py
//      sldprt2step_lib/container/container.py
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

import Foundation

// MARK: - 常量（对应 blobs.MARKER / sw3d.* / ole_cfb.* / container.*）

/// 对应 blobs.MARKER = bytes.fromhex("231dd571da8148a2a85898b21b89ef99")
let SL_BLOB_MARKER: SLBytes = [
    0x23, 0x1D, 0xD5, 0x71, 0xDA, 0x81, 0x48, 0xA2,
    0xA8, 0x58, 0x98, 0xB2, 0x1B, 0x89, 0xEF, 0x99,
]

/// 对应 sw3d.SW3D_SECTION_MARKER = bytes([0x14, 0x00, 0x06, 0x00, 0x08, 0x00])
let SL_SW3D_SECTION_MARKER: SLBytes = [0x14, 0x00, 0x06, 0x00, 0x08, 0x00]

/// 对应 sw3d.SW3D_HEADER_SIZE = 26
let SL_SW3D_HEADER_SIZE: Int = 26

/// 对应 sw3d.NESTED_ZLIB_OFFSET = 28
let SL_NESTED_ZLIB_OFFSET: Int = 28

/// 对应 sw3d.PARASOLID_MAGIC_SIGNATURES
let SL_PARASOLID_MAGIC_SIGNATURES: [SLBytes] = [
    SLBytes("P_S_".utf8),
    SLBytes("PARA".utf8),
    SLBytes("PS-P".utf8),
    SLBytes("PS-A".utf8),
    SLBytes("PS-S".utf8),
]

/// 对应 ole_cfb.OLE2_SIGNATURE
let SL_OLE2_SIGNATURE: SLBytes = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

/// 对应 ole_cfb.PARASOLID_STREAM_NAMES
let SL_PARASOLID_STREAM_NAMES: [String] = ["Contents", "PowerContents"]

/// 对应 container.CONTAINER_FORMAT_OLE2 = "ole2"
let SL_CONTAINER_FORMAT_OLE2: String = "ole2"

/// 对应 container.CONTAINER_FORMAT_SW3D = "sw3d"
let SL_CONTAINER_FORMAT_SW3D: String = "sw3d"

// MARK: - 字节子串搜索（替代 Python 的 bytes.find / bytes.__contains__ / re.finditer）
//
// 上游用 re.escape(MARKER) 做非重叠匹配；这里手写等价循环，不引入正则。

/// `data` 从 `start` 起首次出现 `needle` 的下标；找不到返回 nil（对应 Python 的 -1）。
/// 对应 Python `bytes.find(sub, start)`。
func slFindFirst(_ data: SLBytes, _ needle: SLBytes, from start: Int = 0) -> Int? {
    if needle.isEmpty { return nil }
    var i = max(0, start)
    let n = needle.count
    while i + n <= data.count {
        var ok = true
        var j = 0
        while j < n {
            if data[i + j] != needle[j] {
                ok = false
                break
            }
            j += 1
        }
        if ok { return i }
        i += 1
    }
    return nil
}

/// `data` 里所有 `needle` 的起始下标，**非重叠**（命中后前进 needle.count）。
/// 对应 Python `re.finditer(re.escape(MARKER), data)`。
func slFindAll(_ data: SLBytes, _ needle: SLBytes) -> [Int] {
    if needle.isEmpty { return [] }
    var out: [Int] = []
    var i = 0
    let n = needle.count
    while i + n <= data.count {
        var ok = true
        var j = 0
        while j < n {
            if data[i + j] != needle[j] {
                ok = false
                break
            }
            j += 1
        }
        if ok {
            out.append(i)
            i += n
        } else {
            i += 1
        }
    }
    return out
}

/// 对应 Python `needle in data`（`blobs.MARKER not in stream.data`）。
/// 注意空 needle 在 Python 里恒为 True。
func slContainsSubsequence(_ data: SLBytes, _ needle: SLBytes) -> Bool {
    if needle.isEmpty { return true }
    return slFindFirst(data, needle, from: 0) != nil
}

/// 对应 Python `buf[0:n] == prefix` / `bytes.startswith(prefix)`（显式循环比较）。
func slStartsWith(_ buf: SLBytes, _ prefix: SLBytes) -> Bool {
    if buf.count < prefix.count { return false }
    var i = 0
    while i < prefix.count {
        if buf[i] != prefix[i] { return false }
        i += 1
    }
    return true
}

/// 对应 jscompat.at(seq, index)：越界（含负下标）返回 nil（JS_UNDEFINED）。
func slAtInt32(_ arr: [Int32], _ index: Int) -> Int32? {
    if index < 0 || index >= arr.count { return nil }
    return arr[index]
}

/// UTF-16LE 严格解码，等价于 Python `raw.decode("utf-16-le")`：
/// 遇到落单代理项（lone surrogate）返回 nil，对应 Python 的 UnicodeDecodeError。
/// 输入长度保证为偶数（调用处 `s + 2 * n <= window.count`）。
func slDecodeUTF16LEStrict(_ raw: SLBytes) -> String? {
    var units: [UInt16] = []
    units.reserveCapacity(raw.count / 2)
    var i = 0
    while i + 1 < raw.count {
        units.append(UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8))
        i += 2
    }
    var j = 0
    while j < units.count {
        let u = units[j]
        if u >= 0xD800 && u <= 0xDBFF {
            if j + 1 >= units.count { return nil }
            let low = units[j + 1]
            if low < 0xDC00 || low > 0xDFFF { return nil }
            j += 2
        } else if u >= 0xDC00 && u <= 0xDFFF {
            return nil
        } else {
            j += 1
        }
    }
    return String(decoding: units, as: UTF16.self)
}

// MARK: - blobs.py

/// 对应 Python `blobs.Blob`。
struct SLBlob: Sendable {
    let offset: Int
    let name: String
    let data: SLBytes

    /// 'partition' | 'part' | 'deltas' | 'other'
    var kind: String {
        let head = Array(data.prefix(80))
        if !slStartsWith(head, SLBytes("PS".utf8)) { return "other" }
        if slContainsSubsequence(head, SLBytes("(partition)".utf8)) { return "partition" }
        if slContainsSubsequence(head, SLBytes("(deltas)".utf8)) { return "deltas" }
        if slContainsSubsequence(head, SLBytes("TRANSMIT FILE created".utf8)) { return "part" }
        return "other"
    }
}

/// 对应 blobs._inflate_chunks(data, pos, limit, first_dsz, first_csz)。
///
/// 上游在 `zlib.decompress` 失败时还会退一步用 `zlib.decompressobj().decompress()`
/// （宽松、容忍截断）。SLDPRTCompat 的 `SLInflate` 只提供严格解码接口，因此这里
/// 把「严格解码失败」直接当作两次尝试都失败 —— 即上游最内层的
/// `except zlib.error: break`。正常文件里 csz 就是精确的压缩长度，严格解码成立。
func slInflateChunks(
    _ data: SLBytes,
    _ pos0: Int,
    _ limit: Int,
    _ firstDsz: Int,
    _ firstCsz: Int
) -> SLBytes {
    var out: SLBytes = []
    var pos = pos0
    var dsz = firstDsz
    var csz = firstCsz
    while true {
        if csz <= 0 || pos + csz > data.count { break }
        let chunk = Array(data[pos ..< (pos + csz)])
        do {
            out.append(contentsOf: try SLInflate.zlib(chunk, hint: dsz))
        } catch {
            break
        }
        pos += csz
        if pos + 8 > limit || pos + 9 > data.count { break }
        // 对应 struct.unpack_from("<II", data, pos)：上面的 guard 已保证 pos + 8 <= count。
        do {
            dsz = Int(try slReadU32LE(data, pos))
            csz = Int(try slReadU32LE(data, pos + 4))
        } catch {
            break
        }
        if csz <= 0 || pos + 8 + csz > data.count || data[pos + 8] != 0x78 { break }
        pos += 8
    }
    return out
}

/// 对应 blobs.find_blobs(data)。
func slFindBlobs(_ data: SLBytes) -> [SLBlob] {
    var out: [SLBlob] = []
    for h in slFindAll(data, SL_BLOB_MARKER) {
        if h < 4 || h + 24 > data.count { continue }

        guard let blobSizeU = try? slReadU32LE(data, h - 4),
              let dszU = try? slReadU32LE(data, h + 16),
              let cszU = try? slReadU32LE(data, h + 20) else { continue }
        let blobSize = Int(blobSizeU)
        let dsz = Int(dszU)
        let csz = Int(cszU)

        let limit: Int
        if blobSize != 0 {
            limit = min(data.count, h - 4 + 4 + blobSize + 8)
        } else {
            limit = data.count
        }
        let payload = slInflateChunks(data, h + 24, limit, dsz, csz)
        if payload.isEmpty { continue }

        var name = ""
        let windowLo = max(0, h - 200)
        let window = Array(data[windowLo ..< h])

        // 对应 _NAME_RE = rb"\xff\xfe\xff(.)" 的 finditer，取**最后一次**命中。
        var lastStart: Int? = nil
        var p = 0
        while p + 4 <= window.count {
            if window[p] == 0xFF && window[p + 1] == 0xFE && window[p + 2] == 0xFF {
                lastStart = p
                p += 4                     // 非重叠：等价于 re.finditer 前进 match.end()
            } else {
                p += 1
            }
        }
        if let s0 = lastStart {
            let n = Int(window[s0 + 3])    // last.group(1)[0]
            let s = s0 + 4                 // last.end()
            if s + 2 * n <= window.count {
                let raw = Array(window[s ..< (s + 2 * n)])
                // Python: raw.decode("utf-16-le")，UnicodeDecodeError → name = ""
                name = slDecodeUTF16LEStrict(raw) ?? ""
            }
        }

        out.append(SLBlob(offset: h, name: name, data: payload))
    }
    return out
}

// MARK: - sw3d.py

/// 对应 Python `sw3d.Sw3DSection`（上游定义但未被导出路径使用；为忠实起见保留）。
struct SLSw3DSectionRecord: Sendable {
    let offset: Int
    let typeID: Int
    let compressedSize: Int
    let decompressedSize: Int
    let nameLength: Int
    let metadata: SLBytes
    let payload: SLBytes
}

/// 对应 Python `sw3d.Sw3DParasolidResult`（对外 API 里命名为 SLSw3DSection）。
struct SLSw3DSection: Sendable {
    let offset: Int
    let typeID: Int
    let data: SLBytes
}

/// 对应 sw3d._decompress_capped(data, wbits, max_output_length)。
///
/// Python 用 `decompressobj.decompress(data, max_length)` 把输出截到 max_length，
/// 若还有剩余输出则抛 zlib.error；这里先完整解码，再按同样的上限判定。
/// wbits == 0 → zlib 包装；wbits == -15 → 裸 DEFLATE。
func slDecompressCapped(_ data: SLBytes, wbits: Int, maxOutputLength: Int) throws -> SLBytes {
    let out: SLBytes
    if wbits == 0 {
        out = try SLInflate.zlib(data, hint: maxOutputLength)
    } else {
        out = try SLInflate.raw(data, hint: maxOutputLength)
    }
    if out.count > maxOutputLength { throw SLDPRTInflateError.tooLarge }
    return out
}

/// 对应 sw3d._inflate_sync(data, max_output_length=None)。
func slInflateSync(_ data: SLBytes, maxOutputLength: Int? = nil) throws -> SLBytes {
    if let maxOut = maxOutputLength {
        return try slDecompressCapped(data, wbits: 0, maxOutputLength: maxOut)
    }
    return try SLInflate.zlib(data)
}

/// 对应 sw3d._inflate_raw_sync(data, max_output_length=None)。
func slInflateRawSync(_ data: SLBytes, maxOutputLength: Int? = nil) throws -> SLBytes {
    if let maxOut = maxOutputLength {
        return try slDecompressCapped(data, wbits: -15, maxOutputLength: maxOut)
    }
    return try SLInflate.raw(data)
}

/// 对应 sw3d.is_parasolid_buffer(buf)。
func slIsParasolidBuffer(_ buf: SLBytes) -> Bool {
    if buf.count < 4 { return false }
    let head = Array(buf[0 ..< 4])
    for sig in SL_PARASOLID_MAGIC_SIGNATURES {
        if head == sig { return true }
    }
    if buf.count >= 20 && buf[0] == 0x50 && buf[1] == 0x53 {
        let sliceBytes = Array(buf[5 ..< 20])
        if sliceBytes.contains(0x54) {
            if let idx = slFindFirst(buf, SLBytes("TRANSMIT".utf8), from: 0), idx < 32 {
                return true
            }
        }
    }
    return false
}

/// 对应 sw3d._try_nested_decompress(outer, max_output=50_000_000)。
func slTryNestedDecompress(_ outer: SLBytes, maxOutput: Int = 50_000_000) -> SLBytes? {
    if outer.count <= SL_NESTED_ZLIB_OFFSET { return nil }
    let zlibByte = outer[SL_NESTED_ZLIB_OFFSET]
    if zlibByte != 0x78 { return nil }
    do {
        return try slInflateSync(Array(outer.dropFirst(SL_NESTED_ZLIB_OFFSET)), maxOutputLength: maxOutput)
    } catch {
        return nil
    }
}

/// 对应 Python `sw3d.Sw3DStorageParser`。
///
/// 上游 Python 把 `extract_parasolid_sections` / `extract_first_parasolid_section`
/// 写成 `@staticmethod`，接收 `buf`；本移植按对外 API 约定把缓冲区挂在实例上
/// （`init(_ buf:)`），方法变成实例方法。上游这个版本的 `Sw3DStorageParser`
/// 没有 `__init__`，因此没有别的实例属性需要保留；`data` 只是 `buf` 的同义别名，
/// 以兼容把缓冲区命名为 `data` 的调用方。
final class SLSw3DStorageParser: @unchecked Sendable {
    let buf: SLBytes
    let data: SLBytes

    init(_ buf: SLBytes) {
        self.buf = buf
        self.data = buf
    }

    /// 对应 sw3d.Sw3DStorageParser.extract_parasolid_sections(buf, opts)。
    /// opts["max_decompressed_size"] → maxDecompressedSize；
    /// opts["max_results"]（默认 float("inf")）→ maxResults。
    func extractParasolidSections(
        maxDecompressedSize: Int = 50_000_000,
        maxResults: Int = Int.max
    ) -> [SLSw3DSection] {
        let buf = self.buf
        var results: [SLSw3DSection] = []
        var idx = 0

        while true {
            guard let found = slFindFirst(buf, SL_SW3D_SECTION_MARKER, from: idx) else { break }
            idx = found
            if idx + SL_SW3D_HEADER_SIZE > buf.count { break }

            // idx + 26 <= count 已保证这 4 次读取不越界。
            guard let typeIDU = try? slReadU32LE(buf, idx + 6),
                  let cszU = try? slReadU32LE(buf, idx + 14),
                  let dszU = try? slReadU32LE(buf, idx + 18),
                  let nlU = try? slReadU32LE(buf, idx + 22) else { break }
            let typeID = Int(typeIDU)
            let compressedSize = Int(cszU)
            let decompressedSize = Int(dszU)
            let nameLength = Int(nlU)

            if nameLength > 0
                && nameLength < 1024
                && compressedSize > 4
                && compressedSize < buf.count
                && decompressedSize > 4
                && decompressedSize < maxDecompressedSize {
                let payloadOffset = idx + SL_SW3D_HEADER_SIZE + nameLength
                let payloadEnd = payloadOffset + compressedSize

                if payloadEnd <= buf.count {
                    let lo = max(0, min(buf.count, payloadOffset))
                    let hi = max(lo, min(buf.count, payloadEnd))
                    do {
                        let decompressed = try slInflateRawSync(
                            Array(buf[lo ..< hi]),
                            maxOutputLength: decompressedSize + 1024
                        )

                        if slIsParasolidBuffer(decompressed) {
                            results.append(SLSw3DSection(offset: idx, typeID: typeID, data: decompressed))
                        } else {
                            let nested = slTryNestedDecompress(decompressed, maxOutput: maxDecompressedSize)
                            if let nested = nested, slIsParasolidBuffer(nested) {
                                results.append(SLSw3DSection(offset: idx, typeID: typeID, data: nested))
                            }
                        }
                        if results.count >= maxResults { return results }
                    } catch {
                        // 上游：except zlib.error: pass
                    }
                }
            }

            idx += 1
        }

        return results
    }

    /// 对应 sw3d.Sw3DStorageParser.extract_first_parasolid_section(buf, opts)。
    /// 返回**最大**的那个分节（并列时取最先出现的）。
    func extractFirstParasolidSection(maxDecompressedSize: Int = 50_000_000) -> SLSw3DSection? {
        let allSections = extractParasolidSections(
            maxDecompressedSize: maxDecompressedSize,
            maxResults: Int.max
        )
        if allSections.isEmpty { return nil }
        var best = allSections[0]
        for current in allSections.dropFirst() {
            if current.data.count > best.data.count {
                best = current
            }
        }
        return best
    }
}

// MARK: - ole_cfb.py

/// 对应 ole_cfb 里的 `raise ValueError(...)`。
enum SLOleError: Error, Sendable {
    /// "Buffer too small to be a valid OLE2 file"
    case tooSmall
    /// "Not an OLE2 compound file (wrong magic bytes)"
    case badMagic
}

/// 对应 Python `ole_cfb.OleDirectoryEntry`。
struct SLOleDirectoryEntry: Sendable {
    let name: String
    let type: UInt8
    let startSector: Int32
    let size: UInt32
}

/// 对应 Python `ole_cfb.OleStreamResult`。
struct SLOleStream: Sendable {
    let streamName: String
    let data: SLBytes
    let offset: Int
}

/// 对应 sw3d/ole_cfb 共用的 `is_ole2(buf)`。
func slIsOle2(_ buf: SLBytes) -> Bool {
    buf.count >= 8 && slStartsWith(buf, SL_OLE2_SIGNATURE)
}

/// 对应 Python `ole_cfb.OleContainerParser`。
///
/// Python 的 `_build_fat` / `_read_directory` / `read_chain` 是实例方法；Swift 在
/// `init` 里必须在所有存储属性就绪前先算出 `fat` / `entries`，无法调用实例方法，
/// 因此这三者改为静态函数并显式接收 (buf, sectorSize, fat)。对外可见的
/// `readChain(_:)` 仍然保持实例方法签名。
final class SLOleContainerParser: @unchecked Sendable {
    let buf: SLBytes
    let sectorSize: Int
    let fat: [Int32]
    let entries: [SLOleDirectoryEntry]

    init(_ buf: SLBytes) throws {
        if buf.count < 512 {
            throw SLOleError.tooSmall
        }
        if !slStartsWith(buf, SL_OLE2_SIGNATURE) {
            throw SLOleError.badMagic
        }
        let ss = SLJS.shl(1, Int(try slReadU16LE(buf, 30)))
        let fat = try SLOleContainerParser.slBuildFat(buf, ss)
        let entries = try SLOleContainerParser.slReadDirectory(buf, ss, fat)
        self.buf = buf
        self.sectorSize = ss
        self.fat = fat
        self.entries = entries
    }

    /// 对应 ole_cfb.OleContainerParser._build_fat。
    private static func slBuildFat(_ buf: SLBytes, _ ss: Int) throws -> [Int32] {
        let difatStartSector = Int(try slReadI32LE(buf, 68))

        var difat: [Int32] = []
        for i in 0 ..< 109 {
            let sector = try slReadI32LE(buf, 76 + i * 4)
            if sector >= 0 {
                difat.append(sector)
            }
        }

        var difatSec = difatStartSector
        while difatSec >= 0 && difatSec < 0xFFFFFFFE {
            let off = (difatSec + 1) * ss
            // Python: entries_per_sec = ss // 4 - 1（ss >= 512 时非负；此处仍钳到 >= 0）
            let entriesPerSec = ss / 4 - 1
            for i in 0 ..< max(0, entriesPerSec) {
                let sector = try slReadI32LE(buf, off + i * 4)
                if sector >= 0 {
                    difat.append(sector)
                }
            }
            difatSec = Int(try slReadI32LE(buf, off + ss - 4))
        }

        var fat: [Int32] = []
        for sec in difat {
            let off = (Int(sec) + 1) * ss
            // Python: range(ss // 4)（ss 为负时 Python 的 range 为空，故钳到 >= 0）
            for i in 0 ..< max(0, ss / 4) {
                fat.append(try slReadI32LE(buf, off + i * 4))
            }
        }
        return fat
    }

    /// 对应 ole_cfb.OleContainerParser._read_directory。
    private static func slReadDirectory(
        _ buf: SLBytes,
        _ ss: Int,
        _ fat: [Int32]
    ) throws -> [SLOleDirectoryEntry] {
        // Python: dir_start_sector = jscompat.read_u32le(self.buf, 48) —— 无符号！
        let dirStartSector = Int(try slReadU32LE(buf, 48))
        let dirData = slReadChainRange(buf, ss, fat, dirStartSector)
        var entries: [SLOleDirectoryEntry] = []

        var i = 0
        while i + 128 <= dirData.count {
            let nameLen = Int(try slReadU16LE(dirData, i + 64))
            if nameLen == 0 {
                i += 128
                continue
            }
            let nameEnd = i + max(0, nameLen - 2)
            let name = slUTF16LE(dirData, i, nameEnd)
            let entryType = dirData[i + 66]
            let startSector = try slReadI32LE(dirData, i + 116)
            let size = try slReadU32LE(dirData, i + 120)
            entries.append(SLOleDirectoryEntry(
                name: name,
                type: entryType,
                startSector: startSector,
                size: size
            ))
            i += 128
        }
        return entries
    }

    /// 对应 ole_cfb.OleContainerParser.read_chain（整型版本，允许 start 超出 Int32）。
    private static func slReadChainRange(
        _ buf: SLBytes,
        _ sectorSize: Int,
        _ fat: [Int32],
        _ startSector: Int
    ) -> SLBytes {
        var chunks: [SLBytes] = []
        var sec = startSector
        var visited = Set<Int>()

        while sec >= 0 && sec < 0xFFFFFFFE {
            if visited.contains(sec) { break }
            visited.insert(sec)
            let off = (sec + 1) * sectorSize
            // 对应 Python 的 `if off + self.sector_size > len(self.buf): break`
            if off + sectorSize > buf.count { break }
            // 钳制后再切片（Python 切片会自动钳制，Swift 会崩）
            let lo = max(0, min(buf.count, off))
            let hi = max(lo, min(buf.count, off + sectorSize))
            chunks.append(Array(buf[lo ..< hi]))
            // Python: next_sec = jscompat.at(self.fat, sec)；JS_UNDEFINED → sec = -1
            if let next = slAtInt32(fat, sec) {
                sec = Int(next)
            } else {
                sec = -1
            }
        }

        var out: SLBytes = []
        for chunk in chunks {
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// 对应 ole_cfb.OleContainerParser.read_chain(self, start_sector)。
    func readChain(_ startSector: Int32) -> SLBytes {
        SLOleContainerParser.slReadChainRange(buf, sectorSize, fat, Int(startSector))
    }

    /// 对应 ole_cfb.OleContainerParser.extract_stream（完整版，保留 offset）。
    func extractStreamResult(_ streamName: String) -> SLOleStream? {
        var entry: SLOleDirectoryEntry? = nil
        for candidate in entries {
            if candidate.type == 2
                && candidate.name == streamName
                && candidate.startSector >= 0 {
                entry = candidate
                break
            }
        }
        guard let found = entry else { return nil }

        // Python: self.read_chain(entry.start_sector)[:entry.size]
        let chain = readChain(found.startSector)
        let size = Int(found.size)
        let hi = max(0, min(chain.count, size))
        let data = Array(chain[0 ..< hi])

        return SLOleStream(
            streamName: found.name,
            data: data,
            offset: (Int(found.startSector) + 1) * sectorSize
        )
    }

    /// 对应 ole_cfb.OleContainerParser.extract_stream —— 对外 API 只取 data。
    func extractStream(_ name: String) -> SLBytes? {
        extractStreamResult(name)?.data
    }

    /// 对应 ole_cfb.OleContainerParser.extract_parasolid_stream。
    func extractParasolidStream() -> SLOleStream? {
        for name in SL_PARASOLID_STREAM_NAMES {
            if let result = extractStreamResult(name) {
                return result
            }
        }
        return nil
    }

    /// 对应 ole_cfb.OleContainerParser.is_ole2（静态方法形式）。
    static func isOle2(_ buf: SLBytes) -> Bool {
        slIsOle2(buf)
    }
}

// MARK: - container.py

/// 对应 Python `container.Transmit`。
struct SLTransmit: Sendable {
    let format: String      // ole2 | sw3d
    let location: String    // 流名或 "section@<offset>"
    let kind: String        // partition | part | deltas | other
    let name: String        // 已知时的 SolidWorks 体名
    let data: SLBytes
}

/// 对应 Python `container.Extraction`。
struct SLExtraction: Sendable {
    let format: String
    let transmits: [SLTransmit]

    func partitions() -> [SLTransmit] {
        transmits.filter { $0.kind == "partition" }
    }

    func parts() -> [SLTransmit] {
        transmits.filter { $0.kind == "part" }
    }
}

/// 对应 Python `container.ParasolidExtractResult`（向后兼容的单流视图）。
struct SLParasolidExtract: Sendable {
    let format: String
    let streamName: String
    let data: SLBytes
}

/// 对应 container._sw3d_sections(buf) —— 生成器，这里物化成数组（调用方总是全量消费）。
/// 返回每个可解压分节的 (offset, 解压后字节)。
func slSW3DSections(_ buf: SLBytes) -> [(offset: Int, data: SLBytes)] {
    var out: [(offset: Int, data: SLBytes)] = []
    let marker = SL_SW3D_SECTION_MARKER
    var idx = 0
    let n = buf.count

    while true {
        guard let found = slFindFirst(buf, marker, from: idx) else { break }
        idx = found
        if idx + SL_SW3D_HEADER_SIZE > n { break }

        // idx + 26 <= n 已保证这 3 次读取不越界。
        guard let cszU = try? slReadU32LE(buf, idx + 14),
              let dszU = try? slReadU32LE(buf, idx + 18),
              let nlU = try? slReadU32LE(buf, idx + 22) else { break }
        let csz = Int(cszU)
        let dsz = Int(dszU)
        let nl = Int(nlU)

        if 0 < nl && nl < 1024 && 4 < csz && csz < n && 4 < dsz && dsz < 200_000_000 {
            let start = idx + SL_SW3D_HEADER_SIZE + nl
            let end = start + csz
            if end <= n {
                let lo = max(0, min(n, start))
                let hi = max(lo, min(n, end))
                // 已知解压后尺寸 dsz → 作为容量提示传给裸 DEFLATE 解码器
                if let section = try? SLInflate.raw(Array(buf[lo ..< hi]), hint: dsz) {
                    out.append((offset: idx, data: section))
                }
                // 上游：except zlib.error: pass
            }
        }

        idx += 1
    }

    return out
}

/// 对应 container.extract_transmits(buf)。
func slExtractTransmits(_ buf: SLBytes) -> SLExtraction? {
    if slIsOle2(buf) {
        let parser: SLOleContainerParser
        do {
            parser = try SLOleContainerParser(buf)
        } catch {
            // 上游：except Exception: return None
            return nil
        }

        var transmits: [SLTransmit] = []
        for entry in parser.entries {
            // Python: entry.type != 2 or entry.start_sector < 0 or entry.size <= 0
            // （size 是无符号，`<= 0` 等价于 `== 0`）
            if entry.type != 2 || entry.startSector < 0 || entry.size == 0 {
                continue
            }
            // 上游此处 `try: stream = parser.extract_stream(...) except Exception: continue`；
            // Swift 的 extractStream 不抛异常，语义等价。
            guard let stream = parser.extractStream(entry.name) else { continue }
            if !slContainsSubsequence(stream, SL_BLOB_MARKER) { continue }
            for b in slFindBlobs(stream) {
                transmits.append(SLTransmit(
                    format: SL_CONTAINER_FORMAT_OLE2,
                    location: entry.name,
                    kind: b.kind,
                    name: b.name,
                    data: b.data
                ))
            }
        }
        if transmits.isEmpty { return nil }
        return SLExtraction(format: SL_CONTAINER_FORMAT_OLE2, transmits: transmits)
    }

    var transmits: [SLTransmit] = []
    for section in slSW3DSections(buf) {
        if !slContainsSubsequence(section.data, SL_BLOB_MARKER) { continue }
        for b in slFindBlobs(section.data) {
            transmits.append(SLTransmit(
                format: SL_CONTAINER_FORMAT_SW3D,
                location: "section@\(section.offset)",
                kind: b.kind,
                name: b.name,
                data: b.data
            ))
        }
    }
    if transmits.isEmpty { return nil }
    return SLExtraction(format: SL_CONTAINER_FORMAT_SW3D, transmits: transmits)
}

/// 对应 container.extract_parasolid(buf)：最大的 partition transmit
/// （没有则取最大的 part transmit）。
func slExtractParasolid(_ buf: SLBytes) -> SLParasolidExtract? {
    guard let ext = slExtractTransmits(buf) else { return nil }

    // Python: cands = ext.partitions() or ext.parts()
    var cands = ext.partitions()
    if cands.isEmpty {
        cands = ext.parts()
    }
    if cands.isEmpty { return nil }

    // Python: max(cands, key=lambda t: len(t.data)) —— 并列时取最先出现的
    var best = cands[0]
    for t in cands.dropFirst() {
        if t.data.count > best.data.count {
            best = t
        }
    }

    return SLParasolidExtract(format: ext.format, streamName: best.location, data: best.data)
}
