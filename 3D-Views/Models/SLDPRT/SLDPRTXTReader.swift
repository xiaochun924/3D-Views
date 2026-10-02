//
//  SLDPRTXTReader.swift
//  3D-Views
//
//  Parasolid XT 中性二进制（"PS\0\0"）transmit 流的读取器。
//  实现 XT Format Reference 第 2–3 章的物理布局：
//
//    · 文件头："PS\0\0"、短前缀 modeller 字符串、int 前缀 schema 字符串
//      （SCH_<modeller>_<schema>[_<base>]）、[指名 base schema 时的 short: 最大节点类型数]、
//      int: user field 大小；
//    · 节点：2 字节类型；某类型**首次**出现时紧跟内嵌 schema 信息
//      （0xff = 与 base 完全相同；否则是针对 base 布局的编辑脚本 C/D/I/A…Z，
//        或对 base 未知类型的完整定义）；随后对变长类型是 4 字节元素个数；
//      然后是节点索引；最后按布局顺序读字段；
//    · 终止符：类型 1 后跟索引 0；
//    · 指针索引 / 正整数：小值时 2 字节 = 索引+1，否则为负余数后跟商（规范 3.3.3）；
//    · 空标记：int -32764，double -3.14158e13。
//
//  本文件不解释模型语义；拓扑遍历见 model.py 的对应移植。
//
//  ── 来源与许可（Apache License 2.0）────────────────────────────────────────
//  本文件是 “sldprt2step” 的 Swift 移植版的一部分。
//    上游项目：sldprt2step — https://github.com/BlinkingSun/sldprt2step
//    上游作者：BlinkingSun
//    上游许可：Apache License 2.0
//    对应源文件：sldprt2step_lib/xt/reader.py
//
//  sldprt2step 本身是 “open-sld-to-step” 0.1.0 的忠实 Python 移植：
//    更上游项目：open-sld-to-step（Node.js/TypeScript，Apache License 2.0）
//    洁净室声明：该实现仅依据公开规范与公开资料写成 ——
//      · XT Format Reference 第 2–3 章（公开的 Parasolid 传输格式描述）
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

// MARK: - 错误

/// 读取 XT 流时的结构性 / schema 失败。对应 Python 的 `XtError`。
struct SLXtError: Error, Sendable {
    let message: String
}

// MARK: - 字段值

/// 字段值。对应 Python 里 `Node.f` 的 `Dict[str, Any]`。
enum XTValue: Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case ints([Int])
    case doubles([Double])
    case bools([Bool])
    case vec([Double])            // 3 个 double（kind 'v' 与 'h' 的标量分支）
    case vecs([[Double]])         // 多个 3 元组
    case interval([Double])       // 2 个 double（kind 'i' 标量）
    case intervals([[Double]])
    case box([Double])            // 6 个 double（kind 'b' 标量）
    case boxes([[Double]])        // 多个 6 元组（kind 'b' 的数组分支）
    case bytes(SLBytes)
}

extension XTValue {
    /// 仅 .int → 值；.bool → 1/0；其余 nil。
    var intValue: Int? {
        switch self {
        case .int(let v):
            return v
        case .bool(let v):
            return v ? 1 : 0
        default:
            return nil
        }
    }

    /// 仅 .double。
    var doubleValue: Double? {
        if case .double(let v) = self { return v }
        return nil
    }

    /// 仅 .bool。
    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// 仅 .string。
    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// 仅 .ints。
    var intsValue: [Int]? {
        if case .ints(let v) = self { return v }
        return nil
    }

    /// 仅 .doubles。
    var doublesValue: [Double]? {
        if case .doubles(let v) = self { return v }
        return nil
    }

    /// 仅 .vec。
    var vecValue: [Double]? {
        if case .vec(let v) = self { return v }
        return nil
    }

    /// 仅 .vecs。
    var vecsValue: [[Double]]? {
        if case .vecs(let v) = self { return v }
        return nil
    }

    /// 仅 .bytes。
    var bytesValue: SLBytes? {
        if case .bytes(let v) = self { return v }
        return nil
    }
}

// MARK: - 节点

/// 对应 Python 的 `Node`。
final class XTNode: @unchecked Sendable {
    let index: Int
    let type: Int
    let f: [String: XTValue]

    init(index: Int, type: Int, f: [String: XTValue]) {
        self.index = index
        self.type = type
        self.f = f
    }

    /// 对应 `schema.NODE_NAMES.get(self.type, "TYPE_%d" % self.type)`。
    var name: String {
        XTSchema.nodeNames[type] ?? "TYPE_\(type)"
    }
}

// MARK: - 文件

/// 对应 Python 的 `XtFile`。
final class XTFile: @unchecked Sendable {
    var modellerVersion: Int
    var schemaID: String
    var baseSchema: Int
    var partition: Bool
    var nodes: [Int: XTNode]
    var rootIndex: Int
    var layouts: [Int: [XTField]]
    var schemaLog: [String]
    var trailingBytes: Int

    init() {
        self.modellerVersion = 0
        self.schemaID = ""
        self.baseSchema = 0
        self.partition = false
        self.nodes = [:]
        self.rootIndex = 0
        self.layouts = [:]
        self.schemaLog = []
        self.trailingBytes = 0
    }

    /// 对应 Python 的 `get`：索引 0 视为「无」。
    func get(_ index: Int) -> XTNode? {
        if index == 0 {
            return nil
        }
        return nodes[index]
    }

    /// 对应 Python 的 `deref`：`self.get(node.f.get(field, 0) or 0)`。
    /// 取 `.int(v)` 用 v，其余（含缺失）按 `or 0` 的落点取 0。
    func deref(_ node: XTNode?, _ field: String) -> XTNode? {
        if node == nil {
            return nil
        }
        var target = 0
        if let v = node!.f[field] {
            if case .int(let i) = v {
                target = i
            }
        }
        return get(target)
    }

    /// 对应 Python 的 `chain`。
    func chain(_ head: XTNode?, _ nextField: String, limit: Int = 10_000_000) -> [XTNode] {
        var out: [XTNode] = []
        var seen = Set<Int>()
        var cur = head
        while cur != nil && !seen.contains(cur!.index) && out.count < limit {
            seen.insert(cur!.index)
            out.append(cur!)
            cur = deref(cur, nextField)
        }
        return out
    }

    /// 对应 Python 的 `census`。
    func census() -> [String: Int] {
        var out: [String: Int] = [:]
        for n in nodes.values {
            out[n.name, default: 0] += 1
        }
        return out
    }
}

// MARK: - 编辑脚本字符集

/// 对应 `_EDIT_CHARS = frozenset(b"CDIAZ")`。
private let xtEditChars: Set<Int> = [67, 68, 73, 65, 90]

/// `bytes.decode("latin-1")`。U+0000…U+00FF 与字节一一对应。
private func xtLatin1(_ bytes: SLBytes) -> String {
    String(bytes.map { Character(UnicodeScalar($0)) })
}

/// Python `"%02x"` 的等价物（避免格式化说明符的整数宽度歧义）。
private func xtHex2(_ value: Int) -> String {
    let digits = Array("0123456789abcdef")
    let u = value & 0xFF
    return String([digits[(u >> 4) & 0xF], digits[u & 0xF]])
}

// MARK: - 字节读取器

/// 对应 Python 的 `_Reader`。全部 `struct.unpack_from` 都是**大端**（">…"）。
final class XTReader: @unchecked Sendable {
    let buf: SLBytes
    var pos: Int
    let n: Int

    init(_ buf: SLBytes) {
        self.buf = buf
        self.pos = 0
        self.n = buf.count
    }

    func need(_ k: Int) throws {
        if pos + k > n {
            throw SLXtError("truncated stream at offset \(pos) (need \(k) bytes)")
        }
    }

    func u8() throws -> Int {
        try need(1)
        let v = Int(buf[pos])
        pos += 1
        return v
    }

    /// `struct.unpack_from(">h")` —— 大端 int16。
    func i16() throws -> Int {
        try need(2)
        let v = Int(try slReadI16BE(buf, pos))
        pos += 2
        return v
    }

    /// `struct.unpack_from(">H")` —— 大端 uint16。
    func u16() throws -> Int {
        try need(2)
        let v = Int(try slReadU16BE(buf, pos))
        pos += 2
        return v
    }

    /// `struct.unpack_from(">i")` —— 大端 int32。
    func i32() throws -> Int {
        try need(4)
        let v = Int(try slReadI32BE(buf, pos))
        pos += 4
        return v
    }

    /// `struct.unpack_from(">d")` —— 大端 double。
    func f64() throws -> Double {
        try need(8)
        let v = try slReadF64BE(buf, pos)
        pos += 8
        return v
    }

    /// `struct.unpack_from(">%dd" % k)` —— 大端 double 数组；先整体 need(8*k)，最后一次性推进。
    func f64s(_ k: Int) throws -> [Double] {
        try need(8 * k)
        var out: [Double] = []
        out.reserveCapacity(max(0, k))
        var i = 0
        while i < k {
            out.append(try slReadF64BE(buf, pos + i * 8))
            i += 1
        }
        pos += 8 * k
        return out
    }

    /// `self.buf[self.pos:self.pos + k]`。切片边界做钳制，避免 Swift 区间越界崩溃；
    /// `pos += k` 与 Python 完全一致。
    func raw(_ k: Int) throws -> SLBytes {
        try need(k)
        let start = pos
        let end = pos + k
        let lo = max(0, min(n, start))
        let hi = max(lo, min(n, end))
        pos += k
        return Array(buf[lo..<hi])
    }

    /// 对应 Python 的 `index()`（本移植中改名为 `posint`）。
    /// 小值：2 字节 = 索引+1；否则为负余数后跟商（规范 3.3.3）。
    func posint() throws -> Int {
        var r = try i16()
        var q = 0
        if r < 0 {
            q = try i16()
            r = -r
        }
        return q * 32767 + r - 1
    }

    /// 对应 Python 的 `short_string()`：1 字节长度 + latin-1 内容。
    func shortString() throws -> String {
        let k = try u8()
        return xtLatin1(try raw(k))
    }

    /// 对应 Python 的 `r.pos >= r.n`。
    func atEnd() -> Bool {
        pos >= n
    }
}

// MARK: - 字段定义

/// 对应 Python 的 `_read_field_def`。
private func xtReadFieldDef(_ r: XTReader) throws -> XTField {
    let name = try r.shortString()
    let ptrClass = try r.u16()
    let nElts = try r.posint()
    let kind: Character
    if ptrClass == 0 {
        let tstr = try r.shortString()
        // `tstr[-1] if tstr else "d"`
        kind = tstr.last ?? "d"
    } else {
        kind = "p"
    }
    let n: Int
    if nElts == 1 {
        _ = try r.u8()          // xmt_code，仅变长字段存在
        n = XTSchema.VAR
    } else if nElts == 0 {
        n = 1
    } else {
        n = nElts
    }
    return XTField(name, kind, n, ptrClass)
}

// MARK: - 内嵌 schema 信息

/// 对应 Python 的 `_read_schema_info`。
private func xtReadSchemaInfo(_ r: XTReader, _ ntype: Int, _ xt: XTFile) throws -> [XTField] {
    let first = try r.u8()
    let tname = XTSchema.nodeNames[ntype] ?? "TYPE_\(ntype)"
    let base = XTSchema.base[ntype]
    if first == 0xFF {
        guard let base = base else {
            throw SLXtError("node type \(ntype) (\(tname)) flagged identical to base schema but unknown")
        }
        xt.schemaLog.append("\(tname): base")
        return base
    }
    let nfields = first
    // 用紧随其后的那个字节区分「编辑脚本」与「完整定义」。
    // 注意：这里只**窥视**，不消费 —— 该字节仍留在流里，随后被当作第一个
    // 编辑操作码（或完整定义里 short_string 的长度字节）读走。
    try r.need(1)
    let nxt = Int(r.buf[r.pos])
    if let base = base, xtEditChars.contains(nxt) {
        var out: [XTField] = []
        var bi = 0
        var ops: [String] = []
        while true {
            let op = try r.u8()
            if op == 0x5A {                     // 'Z'
                break
            }
            if op == 0x43 {                     // 'C'
                if bi >= base.count {
                    throw SLXtError("\(tname): edit script copies past end of base layout")
                }
                out.append(base[bi])
                bi += 1
                ops.append("C")
            } else if op == 0x44 {              // 'D'
                if bi >= base.count {
                    throw SLXtError("\(tname): edit script deletes past end of base layout")
                }
                ops.append("D(\(base[bi].name))")
                bi += 1
            } else if op == 0x49 || op == 0x41 { // 'I' 或 'A'
                let fld = try xtReadFieldDef(r)
                out.append(fld)
                let dim = fld.n == XTSchema.VAR ? "var" : String(fld.n)
                let suffix = fld.n == 1 ? "" : "[" + dim + "]"
                let opChar = Character(UnicodeScalar(UInt8(op)))
                ops.append("\(opChar)(\(fld.name):\(fld.kind)\(suffix))")
            } else {
                throw SLXtError("\(tname): bad edit op 0x\(xtHex2(op)) at offset \(r.pos - 1)")
            }
        }
        if bi < base.count {
            ops.append("implicit-drop(\(base[bi...].map { $0.name }.joined(separator: ",")))")
        }
        if out.count != nfields {
            throw SLXtError("\(tname): edit script yields \(out.count) fields, header says \(nfields) (\(ops.joined(separator: " ")))")
        }
        xt.schemaLog.append("\(tname): \(ops.joined(separator: " ")) -> \(out.map { $0.name })")
        return out
    }
    // 完整定义（该类型不在 base schema 中）。
    let name = try r.shortString()
    let desc = try r.shortString()
    var out: [XTField] = []
    for _ in 0..<max(0, nfields) {
        out.append(try xtReadFieldDef(r))
    }
    xt.schemaLog.append("\(tname): full def name='\(name)' desc='\(desc)' fields=\(out.map { $0.name })")
    return out
}

// MARK: - 字段值读取

/// 对应 Python 的 `_read_value`。
private func xtReadValue(_ r: XTReader, _ fld: XTField, _ count: Int) throws -> XTValue {
    let k = fld.kind
    let scalar = fld.n == 1
    if k == "p" {
        if scalar {
            return .int(try r.posint())
        }
        var out: [Int] = []
        for _ in 0..<max(0, count) {
            out.append(try r.posint())
        }
        return .ints(out)
    }
    if k == "d" || k == "t" {
        if scalar {
            return .int(try r.i32())
        }
        var out: [Int] = []
        for _ in 0..<max(0, count) {
            out.append(try r.i32())
        }
        return .ints(out)
    }
    if k == "f" {
        if scalar {
            return .double(try r.f64())
        }
        return .doubles(try r.f64s(count))
    }
    if k == "v" || k == "h" {
        if scalar {
            return .vec(try r.f64s(3))
        }
        var out: [[Double]] = []
        for _ in 0..<max(0, count) {
            out.append(try r.f64s(3))
        }
        return .vecs(out)
    }
    if k == "i" {
        if scalar {
            return .interval(try r.f64s(2))
        }
        var out: [[Double]] = []
        for _ in 0..<max(0, count) {
            out.append(try r.f64s(2))
        }
        return .intervals(out)
    }
    if k == "b" {
        if scalar {
            return .box(try r.f64s(6))
        }
        var out: [[Double]] = []
        for _ in 0..<max(0, count) {
            out.append(try r.f64s(6))
        }
        return .boxes(out)
    }
    if k == "u" {
        if scalar {
            return .int(try r.u8())
        }
        return .ints(try r.raw(count).map { Int($0) })
    }
    if k == "l" {
        if scalar {
            return .bool(try r.u8() != 0)
        }
        return .bools(try r.raw(count).map { $0 != 0 })
    }
    if k == "c" {
        if scalar {
            return .string(String(Character(UnicodeScalar(UInt8(try r.u8())))))
        }
        return .string(xtLatin1(try r.raw(count)))
    }
    if k == "n" {
        if scalar {
            return .int(try r.i16())
        }
        var out: [Int] = []
        for _ in 0..<max(0, count) {
            out.append(try r.i16())
        }
        return .ints(out)
    }
    if k == "w" {
        if scalar {
            return .int(try r.u16())
        }
        var out: [Int] = []
        for _ in 0..<max(0, count) {
            out.append(try r.u16())
        }
        return .ints(out)
    }
    throw SLXtError("unknown field kind '\(k)' for field \(fld.name)")
}

// MARK: - 顶层入口

/// 对应 Python 的 `read_xt`：解析一个中性二进制 XT transmit 流（part 或 partition）。
func readXT(_ buf: SLBytes) throws -> XTFile {
    let r = XTReader(buf)
    let magic = try r.raw(2)
    if magic != [0x50, 0x53] {              // b"PS"
        throw SLXtError("not a binary XT stream (no PS flag)")
    }
    let flag = try r.raw(2)
    if flag != [0x00, 0x00] {               // b"\x00\x00"
        throw SLXtError("unsupported XT binary flavour (flag \(flag)); only neutral binary is supported")
    }
    let xt = XTFile()
    let mlen = try r.i16()
    let modeller = xtLatin1(try r.raw(mlen))
    xt.partition = modeller.contains("partition")
    var digits = ""
    let tail: String
    if let sp = modeller.lastIndex(of: " ") {   // modeller.rsplit(" ", 1)[-1]
        tail = String(modeller[modeller.index(after: sp)...])
    } else {
        tail = modeller
    }
    for ch in tail {
        if ch.isNumber {
            digits.append(ch)
        }
    }
    xt.modellerVersion = Int(digits) ?? 0
    let slen = try r.i32()
    xt.schemaID = xtLatin1(try r.raw(slen))
    let parts = xt.schemaID.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
    if parts.count >= 4 && parts[0] == "SCH" {
        xt.baseSchema = Int(parts[3]) ?? 0
        _ = try r.u16()                     // 最大节点类型数
        if xt.baseSchema != 13006 {
            throw SLXtError("unsupported base schema \(xt.baseSchema) (only SCH_13006 embedding is supported)")
        }
    } else {
        throw SLXtError("XT stream without embedded schema (\(xt.schemaID)) is not supported")
    }
    let usfld = try r.i32()
    if usfld != 0 {
        throw SLXtError("XT user fields (USFLD_SIZE=\(usfld)) are not supported")
    }

    var first = true
    while true {
        let ntype = try r.u16()
        if ntype == 1 {
            let term = try r.u16()
            if term != 1 {
                throw SLXtError("bad terminator at offset \(r.pos - 4)")
            }
            break
        }
        let layout: [XTField]
        if let existing = xt.layouts[ntype] {
            layout = existing
        } else {
            layout = try xtReadSchemaInfo(r, ntype, xt)
            xt.layouts[ntype] = layout
        }
        var count = 0
        if XTSchema.isVariable(layout) {
            count = try r.i32()
            if count < 0 {
                throw SLXtError("negative variable length at offset \(r.pos - 4)")
            }
        }
        let idx = try r.posint()
        var fields: [String: XTValue] = [:]
        do {
            for fld in layout {
                fields[fld.name] = try xtReadValue(r, fld, fld.n == XTSchema.VAR ? count : fld.n)
            }
        } catch let exc as SLXtError {
            throw SLXtError("while reading \(XTSchema.nodeNames[ntype] ?? String(ntype)) #\(idx): \(exc.message)")
        } catch {
            throw error
        }
        if xt.nodes[idx] != nil {
            throw SLXtError("duplicate node index \(idx)")
        }
        xt.nodes[idx] = XTNode(index: idx, type: ntype, f: fields)
        if first {
            xt.rootIndex = idx
            first = false
        }
    }
    xt.trailingBytes = r.n - r.pos
    return xt
}
