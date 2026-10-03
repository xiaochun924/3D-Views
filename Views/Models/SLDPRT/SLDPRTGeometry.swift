//
//  SLDPRTGeometry.swift
//  Views
//
//  SLDPRT（SolidWorks 零件）→ STEP 转换器使用的「纯几何内核」：
//  向量、NURBS 曲线/曲面求值与导数、节点插入、解析曲面、有理圆弧、
//  三次插值样条、最近点投影。
//
//  ── 来源与许可（Apache License 2.0）────────────────────────────────────────
//  本文件是 “sldprt2step” 的 Swift 移植版的一部分。
//    上游项目：sldprt2step — https://github.com/BlinkingSun/sldprt2step
//    上游作者：BlinkingSun
//    上游许可：Apache License 2.0
//    对应源文件：sldprt2step_lib/xt/geom.py（985 行）
//
//  sldprt2step 本身是 “open-sld-to-step” 的忠实 Python 移植：
//    更上游项目：open-sld-to-step（Node.js/TypeScript，Apache License 2.0）
//    洁净室声明：该实现仅依据公开规范与公开资料写成 ——
//      · ISO 10303（STEP）系列标准，含 ISO 10303-42 几何与拓扑表示
//      · 公开的 Parasolid XT 格式说明（XT Format Reference 中的公开描述）
//      · 公开的 NURBS 文献（Piegl & Tiller, The NURBS Book：A2.3 基函数导数等）
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
//  【移植约定】
//   · 算法逐行忠实于 geom.py：所有容差、迭代次数、采样数、分支顺序一律照搬
//     （1e-12 / 1e-300 / 1e-15 / grid = 12 / g = 20 / n = 64 / iters = 60 / 40 次
//      Gauss-Newton / 12 次阻尼回退 / 1e-9 / 1e-13 / 1e-30 等均未改动）。
//   · 长度单位为 XT 单位（米）；STEP 写出时再换算到毫米。
//   · Python 的 `raise GeomError(...)` 一律改为 Swift 的 `throws GeomError`。
//   · `Surface` 是可被同模块子类覆写的 `class`（对应 mapper 侧
//     `_CurveSupport(geom.Surface)` / `_OffsetEval(geom.Surface)`），
//     `eval` / `normal` / `project` 均非 final；基类默认实现 fatalError。
//

import Foundation

// MARK: - 基础类型

/// 三维向量，约定 3 个元素。对应 Python 的 `Vec = Tuple[float, float, float]`。
/// 齐次控制点（3 个坐标 + 1 个权重）同样用 `[Double]` 表示。
typealias Vec = [Double]

/// 几何内核错误。对应 Python 的 `class GeomError(Exception)`。
struct GeomError: Error {
    let message: String
}

// MARK: - 向量运算

/// `a + b`
func add(_ a: Vec, _ b: Vec) -> Vec {
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

/// `a - b`
func sub(_ a: Vec, _ b: Vec) -> Vec {
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

/// `a * s`（标量乘）
func mul(_ a: Vec, _ s: Double) -> Vec {
    return [a[0] * s, a[1] * s, a[2] * s]
}

/// 点积
func dot(_ a: Vec, _ b: Vec) -> Double {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// 叉积
func cross(_ a: Vec, _ b: Vec) -> Vec {
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]
}

/// 模长。对应 `math.sqrt(dot(a, a))`。
func norm(_ a: Vec) -> Double {
    return sqrt(dot(a, a))
}

/// 单位化。零向量抛 `GeomError`（对应 `raise GeomError("cannot normalise a zero vector")`）。
func unit(_ a: Vec) throws -> Vec {
    let n = norm(a)
    if n < 1e-300 {
        throw GeomError(message: "cannot normalise a zero vector")
    }
    return [a[0] / n, a[1] / n, a[2] / n]
}

/// 两点距离
func dist(_ a: Vec, _ b: Vec) -> Double {
    return norm(sub(a, b))
}

/// 与 `a` 垂直的某个单位向量（`a` 不必是单位向量）。
func perp(_ a: Vec) throws -> Vec {
    let ax = abs(a[0]), ay = abs(a[1]), az = abs(a[2])
    var o: Vec
    if ax <= ay && ax <= az {
        o = [1.0, 0.0, 0.0]
    } else if ay <= az {
        o = [0.0, 1.0, 0.0]
    } else {
        o = [0.0, 0.0, 1.0]
    }
    return try unit(cross(a, o))
}

/// 线性插值
func lerp(_ a: Vec, _ b: Vec, _ t: Double) -> Vec {
    return [a[0] + (b[0] - a[0]) * t,
            a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t]
}

// MARK: - B 样条基础

/// 由「相异节点 + 重数」展开出完整节点向量。对应 `expand_knots`。
func expandKnots(_ distinct: [Double], _ mults: [Int]) -> [Double] {
    var out: [Double] = []
    for (k, m) in zip(distinct, mults) {
        let count = max(0, Int(m))
        if count > 0 {
            out.append(contentsOf: Array(repeating: Double(k), count: count))
        }
    }
    return out
}

/// 返回满足 `knots[i] <= t < knots[i+1]` 的下标 i（有效域内）。对应 `find_span`。
func findSpan(_ degree: Int, _ t: Double, _ knots: [Double], _ nCtrl: Int) -> Int {
    let lo = degree
    let hi = nCtrl  // 有效域为 [knots[degree], knots[n_ctrl]]
    if t >= knots[hi] {
        var i = hi - 1
        while i > lo && knots[i] == knots[hi] {
            i -= 1
        }
        return i
    }
    if t <= knots[lo] {
        return lo
    }
    var a = lo
    var b = hi
    while b - a > 1 {
        let m = (a + b) / 2
        if t < knots[m] {
            b = m
        } else {
            a = m
        }
    }
    return a
}

/// 非零基函数（Piegl & Tiller A2.2）。对应 `basis_funs`。
func basisFuns(_ span: Int, _ t: Double, _ degree: Int, _ knots: [Double]) -> [Double] {
    var N = [1.0] + [Double](repeating: 0.0, count: max(0, degree))
    var left = [Double](repeating: 0.0, count: degree + 1)
    var right = [Double](repeating: 0.0, count: degree + 1)
    if degree >= 1 {
        for j in 1...degree {
            left[j] = t - knots[span + 1 - j]
            right[j] = knots[span + j] - t
            var saved = 0.0
            for r in 0..<j {
                let den = right[r + 1] + left[j - r]
                let temp = den != 0.0 ? N[r] / den : 0.0
                N[r] = saved + right[r + 1] * temp
                saved = left[j - r] * temp
            }
            N[j] = saved
        }
    }
    return N
}

/// 基函数与其一阶导数（Piegl & Tiller A2.3, n = 1）。对应 `basis_funs_derivs`。
func basisFunsDerivs(_ span: Int, _ t: Double, _ degree: Int, _ knots: [Double]) -> ([Double], [Double]) {
    let p = degree
    var ndu = [[Double]](repeating: [Double](repeating: 0.0, count: p + 1), count: p + 1)
    ndu[0][0] = 1.0
    var left = [Double](repeating: 0.0, count: p + 1)
    var right = [Double](repeating: 0.0, count: p + 1)
    if p >= 1 {
        for j in 1...p {
            left[j] = t - knots[span + 1 - j]
            right[j] = knots[span + j] - t
            var saved = 0.0
            for r in 0..<j {
                ndu[j][r] = right[r + 1] + left[j - r]
                let temp = ndu[j][r] != 0.0 ? ndu[r][j - 1] / ndu[j][r] : 0.0
                ndu[r][j] = saved + right[r + 1] * temp
                saved = left[j - r] * temp
            }
            ndu[j][j] = saved
        }
    }
    var N = [Double](repeating: 0.0, count: p + 1)
    for j in 0...p {
        N[j] = ndu[j][p]
    }
    var D = [Double](repeating: 0.0, count: p + 1)
    for r in 0...p {
        var d = 0.0
        let rk = r - 1
        let pk = p - 1
        if r >= 1 {
            let v = ndu[pk + 1][rk]
            let a0 = v != 0.0 ? 1.0 / v : 0.0
            d += a0 * ndu[rk][pk]
        }
        if r <= pk {
            let v = ndu[pk + 1][r]
            let a1 = v != 0.0 ? -1.0 / v : 0.0
            d += a1 * ndu[r][pk]
        }
        D[r] = d * Double(p)
    }
    return (N, D)
}

// MARK: - NURBS 曲线

/// NURBS 曲线：`ctrl` 的每个元素是 dim 维（2 或 3）控制点，权重可选。
/// 对应 Python 的 `class NurbsCurve`。
final class NurbsCurve: @unchecked Sendable {
    let degree: Int
    let ctrl: [[Double]]
    let knots: [Double]
    let weights: [Double]?
    /// 控制点维数（`ctrl` 非空时取首元素维度，否则 3）。
    let dim: Int

    /// 是否有理（`weights` 非 nil 且非空）。对应 Python 的 `bool(self.weights)`。
    var isRational: Bool {
        return !(weights ?? []).isEmpty
    }

    /// 定义域下界。对应 `@property t0` / `knots[degree]`。
    var t0: Double {
        return knots[degree]
    }

    /// 定义域上界。对应 `@property t1` / `knots[len(ctrl)]`。
    var t1: Double {
        return knots[ctrl.count]
    }

    /// 对应 `NurbsCurve.__init__(degree, ctrl, knots, weights=None)`。
    init(degree: Int, ctrl: [[Double]], knots: [Double], weights: [Double]? = nil) throws {
        self.degree = degree
        self.ctrl = ctrl
        self.knots = knots
        self.weights = weights
        self.dim = ctrl.isEmpty ? 3 : ctrl[0].count
        if knots.count != ctrl.count + degree + 1 {
            throw GeomError(message: "B-curve: \(knots.count) knots for \(ctrl.count) poles of degree \(degree)")
        }
    }

    /// 求值。对应 `NurbsCurve.eval(t)`，返回 dim 维点。
    func eval(_ t: Double) -> [Double] {
        let p = degree
        let span = findSpan(p, t, knots, ctrl.count)
        let N = basisFuns(span, t, p, knots)
        var acc = [Double](repeating: 0.0, count: dim)
        var wsum = 0.0
        for k in 0..<(p + 1) {
            let idx = span - p + k
            var w = 1.0
            if let wts = weights, !wts.isEmpty {
                w = wts[idx]
            }
            let c = ctrl[idx]
            let f = N[k] * w
            for d in 0..<dim {
                acc[d] += f * c[d]
            }
            wsum += f
        }
        if isRational {
            var out = [Double](repeating: 0.0, count: dim)
            for d in 0..<dim {
                out[d] = acc[d] / wsum
            }
            return out
        }
        return acc
    }

    /// 求值与一阶导数。对应 `NurbsCurve.eval_deriv(t)`，返回 `(P, dP/dt)`。
    func evalDeriv(_ t: Double) -> ([Double], [Double]) {
        let p = degree
        let span = findSpan(p, t, knots, ctrl.count)
        let (N, D) = basisFunsDerivs(span, t, p, knots)
        var A = [Double](repeating: 0.0, count: dim)
        var Ad = [Double](repeating: 0.0, count: dim)
        var w = 0.0
        var wd = 0.0
        for k in 0..<(p + 1) {
            let idx = span - p + k
            var wk = 1.0
            if let wts = weights, !wts.isEmpty {
                wk = wts[idx]
            }
            let c = ctrl[idx]
            for d in 0..<dim {
                A[d] += N[k] * wk * c[d]
                Ad[d] += D[k] * wk * c[d]
            }
            w += N[k] * wk
            wd += D[k] * wk
        }
        if isRational {
            var P = [Double](repeating: 0.0, count: dim)
            for d in 0..<dim {
                P[d] = A[d] / w
            }
            var Pd = [Double](repeating: 0.0, count: dim)
            for d in 0..<dim {
                Pd[d] = (Ad[d] - wd * P[d]) / w
            }
            return (P, Pd)
        }
        return (A, Ad)
    }

    /// 返回节点向量被钳制到 `[t0, t1]` 的等价曲线。对应 `NurbsCurve.clamped()`。
    func clamped() throws -> NurbsCurve {
        return try clampCurve(self)
    }

    /// 在 `[a, b]`（默认整段定义域）上均匀采样 n 点。对应 `NurbsCurve.sample(n, a=None, b=None)`。
    func sample(_ n: Int, _ a: Double? = nil, _ b: Double? = nil) -> [[Double]] {
        let a0 = a ?? t0
        let b0 = b ?? t1
        var out: [[Double]] = []
        if n > 0 {
            out.reserveCapacity(n)
        }
        for i in 0..<n {
            out.append(eval(a0 + (b0 - a0) * Double(i) / Double(n - 1)))
        }
        return out
    }
}

/// Boehm 节点插入（作用在已折入权重的齐次控制点上）。
/// 对应 Python 的 `_insert_knot(degree, ctrl, knots, t, times)`。
func insertKnot(_ degree: Int,
                _ ctrl: [[Double]],
                _ knots: [Double],
                _ t: Double,
                _ times: Int) -> ([[Double]], [Double]) {
    let p = degree
    var ctrl = ctrl
    var knots = knots
    var iter = 0
    while iter < times {
        iter += 1
        let n = ctrl.count
        let k = findSpan(p, t, knots, n)
        // 当前 t 的重数
        var s = 0
        for kk in knots where kk == t {
            s += 1
        }
        if s >= p + 1 {
            break
        }
        let dimc = ctrl.isEmpty ? 3 : ctrl[0].count
        var newCtrl: [[Double]] = []
        newCtrl.reserveCapacity(n + 1)
        for i in 0..<(n + 1) {
            if i <= k - p {
                newCtrl.append(ctrl[i])
            } else if i <= k {
                let den = knots[i + p] - knots[i]
                let a = den != 0.0 ? (t - knots[i]) / den : 0.0
                var q = [Double](repeating: 0.0, count: dimc)
                for d in 0..<dimc {
                    q[d] = a * ctrl[i][d] + (1.0 - a) * ctrl[i - 1][d]
                }
                newCtrl.append(q)
            } else {
                newCtrl.append(ctrl[i - 1])
            }
        }
        knots = Array(knots[0...k]) + [t] + Array(knots[(k + 1)...])
        ctrl = newCtrl
    }
    return (ctrl, knots)
}

/// 控制点折入权重，得到齐次控制点（末尾追加 w）。
/// 对应 Python 的 `_homog(ctrl, weights)`。
func homog(_ ctrl: [[Double]], _ weights: [Double]?) -> [[Double]] {
    guard let wts = weights, !wts.isEmpty else {
        return ctrl.map { c in c + [1.0] }
    }
    let n = min(ctrl.count, wts.count)
    var out: [[Double]] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let w = wts[i]
        var c = ctrl[i]
        for d in 0..<c.count {
            c[d] *= w
        }
        c.append(w)
        out.append(c)
    }
    return out
}

/// 齐次控制点还原为普通控制点（并可选地取出权重）。
/// 对应 Python 的 `_dehomog(h, rational)`，返回 `(pts, ws?)`。
func dehomog(_ h: [[Double]], _ rational: Bool) -> ([[Double]], [Double]?) {
    var pts: [[Double]] = []
    var ws: [Double] = []
    pts.reserveCapacity(h.count)
    ws.reserveCapacity(h.count)
    for c in h {
        let w = c[c.count - 1]
        let m = c.count - 1
        var p = [Double](repeating: 0.0, count: m)
        for i in 0..<m {
            p[i] = c[i] / w
        }
        pts.append(p)
        ws.append(w)
    }
    return (pts, rational ? ws : nil)
}

/// 把曲线的节点向量钳制到 `[t0, t1]`。对应 Python 的 `_clamp_curve(c)`。
func clampCurve(_ c: NurbsCurve) throws -> NurbsCurve {
    let p = c.degree
    var knots = c.knots
    var h = homog(c.ctrl, c.weights)
    let t0 = c.t0
    let t1 = c.t1
    var m0 = 0
    for k in knots where k == t0 {
        m0 += 1
    }
    var m1 = 0
    for k in knots where k == t1 {
        m1 += 1
    }
    if m0 < p + 1 {
        let r = insertKnot(p, h, knots, t0, p + 1 - m0)
        h = r.0
        knots = r.1
    }
    if m1 < p + 1 {
        let r = insertKnot(p, h, knots, t1, p + 1 - m1)
        h = r.0
        knots = r.1
    }
    // 丢弃 [t0, t1] 之外的节点/极点
    guard let first = knots.firstIndex(of: t0) else {
        throw GeomError(message: "clamping produced inconsistent knot vector")
    }
    // last = len(knots) - 1 - knots[::-1].index(t1)
    var last = -1
    for i in stride(from: knots.count - 1, through: 0, by: -1) {
        if knots[i] == t1 {
            last = i
            break
        }
    }
    guard last >= first else {
        throw GeomError(message: "clamping produced inconsistent knot vector")
    }
    let knots2 = Array(knots[first...last])
    // 极点：下标 first .. last - p - 1，即 h[first:last - p]
    let hiPole = last - p
    guard hiPole >= first else {
        throw GeomError(message: "clamping produced inconsistent knot vector")
    }
    let h2 = Array(h[first..<hiPole])
    if knots2.count != h2.count + p + 1 {
        throw GeomError(message: "clamping produced inconsistent knot vector")
    }
    let (pts, ws) = dehomog(h2, c.isRational)
    return try NurbsCurve(degree: p, ctrl: pts, knots: knots2, weights: ws)
}

// MARK: - NURBS 曲面

/// 张量积 NURBS 曲面；`ctrl[i][j]`，i 沿 u（nU 个），j 沿 v（nV 个）。
/// 对应 Python 的 `class NurbsSurface`。
final class NurbsSurface: @unchecked Sendable {
    let p: Int
    let q: Int
    let ctrl: [[[Double]]]
    let uKnots: [Double]
    let vKnots: [Double]
    let weights: [[Double]]?
    let nU: Int
    let nV: Int

    /// 是否有理（`weights` 非 nil 且非空）。对应 Python 的 `bool(self.weights)`。
    var isRational: Bool {
        return !(weights ?? []).isEmpty
    }

    /// 对应 `@property u0` / `u_knots[p]`。
    var u0: Double {
        return uKnots[p]
    }

    /// 对应 `@property u1` / `u_knots[n_u]`。
    var u1: Double {
        return uKnots[nU]
    }

    /// 对应 `@property v0` / `v_knots[q]`。
    var v0: Double {
        return vKnots[q]
    }

    /// 对应 `@property v1` / `v_knots[n_v]`。
    var v1: Double {
        return vKnots[nV]
    }

    /// 对应 `NurbsSurface(u_degree, v_degree, ctrl, u_knots, v_knots, weights=None)`。
    init(uDegree: Int,
         vDegree: Int,
         ctrl: [[[Double]]],
         uKnots: [Double],
         vKnots: [Double],
         weights: [[Double]]? = nil) throws {
        self.p = uDegree
        self.q = vDegree
        self.ctrl = ctrl
        self.uKnots = uKnots
        self.vKnots = vKnots
        self.weights = weights
        self.nU = ctrl.count
        self.nV = ctrl.isEmpty ? 0 : ctrl[0].count
        if uKnots.count != self.nU + self.p + 1 || vKnots.count != self.nV + self.q + 1 {
            throw GeomError(message: "B-surface: inconsistent knot counts")
        }
    }

    /// 求值。对应 `NurbsSurface.eval(u, v)`（非 throws，Python 里求值不会失败）。
    func eval(u: Double, v: Double) -> Vec {
        return evalDerivs(u: u, v: v).0
    }

    /// 求值与一阶偏导。对应 `NurbsSurface.eval_derivs(u, v)`，返回 `(S, Su, Sv)`。
    func evalDerivs(u: Double, v: Double) -> (Vec, Vec, Vec) {
        let su = findSpan(p, u, uKnots, nU)
        let sv = findSpan(q, v, vKnots, nV)
        let (Nu, Du) = basisFunsDerivs(su, u, p, uKnots)
        let (Nv, Dv) = basisFunsDerivs(sv, v, q, vKnots)
        var A = [0.0, 0.0, 0.0]
        var Au = [0.0, 0.0, 0.0]
        var Av = [0.0, 0.0, 0.0]
        var w = 0.0
        var wu = 0.0
        var wv = 0.0
        for a in 0..<(p + 1) {
            let i = su - p + a
            let row = ctrl[i]
            var wrow: [Double]? = nil
            if let wts = weights, !wts.isEmpty {
                wrow = wts[i]
            }
            for b in 0..<(q + 1) {
                let j = sv - q + b
                let c = row[j]
                var wk = 1.0
                if let wr = wrow, !wr.isEmpty {
                    wk = wr[j]
                }
                let f = Nu[a] * Nv[b] * wk
                let fu = Du[a] * Nv[b] * wk
                let fv = Nu[a] * Dv[b] * wk
                A[0] += f * c[0]
                A[1] += f * c[1]
                A[2] += f * c[2]
                Au[0] += fu * c[0]
                Au[1] += fu * c[1]
                Au[2] += fu * c[2]
                Av[0] += fv * c[0]
                Av[1] += fv * c[1]
                Av[2] += fv * c[2]
                w += f
                wu += fu
                wv += fv
            }
        }
        if isRational {
            let P: Vec = [A[0] / w, A[1] / w, A[2] / w]
            let Pu: Vec = [(Au[0] - wu * P[0]) / w,
                           (Au[1] - wu * P[1]) / w,
                           (Au[2] - wu * P[2]) / w]
            let Pv: Vec = [(Av[0] - wv * P[0]) / w,
                           (Av[1] - wv * P[1]) / w,
                           (Av[2] - wv * P[2]) / w]
            return (P, Pu, Pv)
        }
        return (A, Au, Av)
    }

    /// 自然法向（单位）。对应 `NurbsSurface.normal(u, v)`；退化点会按 1e-4 域内偏移重取。
    func normal(u: Double, v: Double) throws -> Vec {
        let d0 = evalDerivs(u: u, v: v)
        var Su = d0.1
        var Sv = d0.2
        var n = cross(Su, Sv)
        if norm(n) < 1e-300 {
            // 退化点：在域内轻微偏移后重取
            let du = (u1 - u0) * 1e-4
            let dv = (v1 - v0) * 1e-4
            let uu = min(max(u + du, u0), u1)
            let vv = min(max(v + dv, v0), v1)
            let d1 = evalDerivs(u: uu, v: vv)
            Su = d1.1
            Sv = d1.2
            n = cross(Su, Sv)
        }
        return try unit(n)
    }

    /// 两个方向都钳制节点向量的等价曲面。对应 `NurbsSurface.clamped()`。
    func clamped() throws -> NurbsSurface {
        let rational = isRational
        // 沿 u 钳制：把每个 v 列当作一条 3D(+w) 点的曲线
        // 齐次坐标：(w*x, w*y, w*z, w)
        var rowsH: [[[Double]]] = []
        for i in 0..<nU {
            var row: [[Double]] = []
            for j in 0..<nV {
                var w = 1.0
                if rational, let wts = weights {
                    w = wts[i][j]
                }
                var x = ctrl[i][j]
                for d in 0..<x.count {
                    x[d] *= w
                }
                x.append(rational ? w : 1.0)
                row.append(x)
            }
            rowsH.append(row)
        }
        // u 方向
        var newRows: [[[Double]]] = []
        var ukOut: [Double] = []
        for j in 0..<nV {
            var col: [[Double]] = []
            for i in 0..<nU {
                col.append(rowsH[i][j])
            }
            let r = try clampHomogeneous(p, col, uKnots)
            if j == 0 {
                ukOut = r.1
            }
            newRows.append(r.0)
        }
        // newRows[j][i] -> 转置成 [i][j]
        let nU2 = newRows.isEmpty ? 0 : newRows[0].count
        var grid: [[[Double]]] = []
        for i in 0..<nU2 {
            var row: [[Double]] = []
            for j in 0..<nV {
                row.append(newRows[j][i])
            }
            grid.append(row)
        }
        // v 方向
        var vkOut: [Double] = []
        var grid2: [[[Double]]] = []
        for i in 0..<nU2 {
            let r = try clampHomogeneous(q, grid[i], vKnots)
            if i == 0 {
                vkOut = r.1
            }
            grid2.append(r.0)
        }
        var ctrlOut: [[[Double]]] = []
        for row in grid2 {
            var r: [[Double]] = []
            for c in row {
                let w = c[3]
                r.append([c[0] / w, c[1] / w, c[2] / w])
            }
            ctrlOut.append(r)
        }
        var weightsOut: [[Double]]? = nil
        if rational {
            var w2: [[Double]] = []
            for row in grid2 {
                var r: [Double] = []
                for c in row {
                    r.append(c[3])
                }
                w2.append(r)
            }
            weightsOut = w2
        }
        return try NurbsSurface(uDegree: p,
                                vDegree: q,
                                ctrl: ctrlOut,
                                uKnots: ukOut,
                                vKnots: vkOut,
                                weights: weightsOut)
    }
}

/// 把一列齐次控制点的节点向量钳制到 `[t0, t1]`。
/// 对应 Python 的 `_clamp_h(p, h, knots)`，返回 `(h2, knots2, first, last)`。
func clampHomogeneous(_ p: Int,
                      _ h: [[Double]],
                      _ knots: [Double]) throws -> ([[Double]], [Double], Int, Int) {
    let t0 = knots[p]
    let t1 = knots[h.count]
    var knots = knots
    var h = h
    var m0 = 0
    for k in knots where k == t0 {
        m0 += 1
    }
    var m1 = 0
    for k in knots where k == t1 {
        m1 += 1
    }
    if m0 < p + 1 {
        let r = insertKnot(p, h, knots, t0, p + 1 - m0)
        h = r.0
        knots = r.1
    }
    if m1 < p + 1 {
        let r = insertKnot(p, h, knots, t1, p + 1 - m1)
        h = r.0
        knots = r.1
    }
    guard let first = knots.firstIndex(of: t0) else {
        throw GeomError(message: "clamping produced inconsistent knot vector")
    }
    var last = -1
    for i in stride(from: knots.count - 1, through: 0, by: -1) {
        if knots[i] == t1 {
            last = i
            break
        }
    }
    guard last >= first else {
        throw GeomError(message: "clamping produced inconsistent knot vector")
    }
    let knots2 = Array(knots[first...last])
    let hiPole = last - p
    guard hiPole >= first else {
        throw GeomError(message: "clamping produced inconsistent knot vector")
    }
    let h2 = Array(h[first..<hiPole])
    if knots2.count != h2.count + p + 1 {
        throw GeomError(message: "clamping produced inconsistent knot vector")
    }
    return (h2, knots2, first, last)
}

// MARK: - 精确圆弧（有理二次 NURBS）

/// 从角度 a0 到 a1 的精确圆弧（弧度，a1 > a0，跨度 <= 2π）。
///
/// `nseg` 强制二次段数（每段跨度必须 < π）；0 表示按「每段 <= 90 度」取最小段数。
/// 对应 Python 的 `arc_nurbs(centre, x_axis, y_axis, radius, a0, a1, nseg=0)`。
func arcNurbs(centre: Vec,
              xAxis: Vec,
              yAxis: Vec,
              radius: Double,
              a0: Double,
              a1: Double,
              nseg: Int = 0) throws -> NurbsCurve {
    let span = a1 - a0
    if span <= 0 {
        throw GeomError(message: "arc with non-positive span")
    }
    var ns = nseg
    if ns <= 0 {
        ns = max(1, Int(ceil(span / (Double.pi / 2) - 1e-9)))
    }
    if span / Double(ns) >= Double.pi - 1e-9 {
        throw GeomError(message: "arc segment spans >= pi")
    }
    let seg = span / Double(ns)
    let w = cos(seg / 2.0)
    var ctrl: [[Double]] = []
    var weights: [Double] = []

    func pt(_ a: Double, _ r: Double) -> Vec {
        return add(centre, add(mul(xAxis, r * cos(a)), mul(yAxis, r * sin(a))))
    }

    for s in 0..<ns {
        let b0 = a0 + Double(s) * seg
        let b1 = b0 + seg
        let bm = 0.5 * (b0 + b1)
        if s == 0 {
            ctrl.append(pt(b0, radius))
            weights.append(1.0)
        }
        ctrl.append(pt(bm, radius / w))
        weights.append(w)
        ctrl.append(pt(b1, radius))
        weights.append(1.0)
    }
    var knots: [Double] = [0.0, 0.0, 0.0]
    if ns >= 2 {
        for s in 1..<ns {
            let k = Double(s) / Double(ns)
            knots.append(k)
            knots.append(k)
        }
    }
    knots.append(contentsOf: [1.0, 1.0, 1.0])
    return try NurbsCurve(degree: 2, ctrl: ctrl, knots: knots, weights: weights)
}

// MARK: - 三次插值

/// 过 `points` 的 C1 分段三次 Bezier 样条（表示为 3 次 B 样条）。
///
/// 切向默认取 Catmull-Rom（弦长）估计；参数化为累积弦长；
/// 内部节点重数为 3（Bezier 段），两端钳制。
/// 对应 Python 的 `interpolate_cubic(points, tangents=None, closed=False)`。
func interpolateCubic(_ points: [Vec],
                      _ tangents: [Vec]? = nil,
                      _ closed: Bool = false) throws -> NurbsCurve {
    var pts: [Vec] = []
    // 丢弃相邻重复点
    for p in points {
        if pts.isEmpty || dist(pts[pts.count - 1], p) > 1e-12 {
            pts.append(p)
        }
    }
    let n = pts.count
    if n < 2 {
        throw GeomError(message: "interpolation needs at least two distinct points")
    }
    var chords = [Double](repeating: 0.0, count: n - 1)
    for i in 0..<(n - 1) {
        chords[i] = dist(pts[i], pts[i + 1])
    }
    var tans: [Vec]
    if let given = tangents {
        tans = given
    } else {
        tans = []
        tans.reserveCapacity(n)
        for i in 0..<n {
            if closed && n > 2 {
                let prv = i > 0 ? pts[i - 1] : pts[n - 2]
                let nxt = i < n - 1 ? pts[i + 1] : pts[1]
                tans.append(try unit(sub(nxt, prv)))
            } else if i == 0 {
                var d: Vec
                if n > 2 {
                    // 单侧二阶估计
                    d = sub(mul(pts[1], 4.0), add(pts[2], mul(pts[0], 3.0)))
                } else {
                    d = sub(pts[1], pts[0])
                }
                if norm(d) > 1e-15 {
                    tans.append(try unit(d))
                } else {
                    tans.append(try unit(sub(pts[1], pts[0])))
                }
            } else if i == n - 1 {
                var d: Vec
                if n > 2 {
                    d = sub(add(mul(pts[n - 1], 3.0), pts[n - 3]), mul(pts[n - 2], 4.0))
                } else {
                    d = sub(pts[n - 1], pts[n - 2])
                }
                if norm(d) > 1e-15 {
                    tans.append(try unit(d))
                } else {
                    tans.append(try unit(sub(pts[n - 1], pts[n - 2])))
                }
            } else {
                let d = sub(pts[i + 1], pts[i - 1])
                if norm(d) > 1e-15 {
                    tans.append(try unit(d))
                } else {
                    tans.append(try unit(sub(pts[i + 1], pts[i])))
                }
            }
        }
    }
    var ctrl: [[Double]] = [pts[0]]
    var knots: [Double] = [0.0, 0.0, 0.0, 0.0]
    var s = 0.0
    for i in 0..<(n - 1) {
        let c = chords[i]
        ctrl.append(add(pts[i], mul(tans[i], c / 3.0)))
        ctrl.append(sub(pts[i + 1], mul(tans[i + 1], c / 3.0)))
        ctrl.append(pts[i + 1])
        s += c
        if i < n - 2 {
            knots.append(contentsOf: [s, s, s])
        }
    }
    knots.append(contentsOf: [s, s, s, s])
    return try NurbsCurve(degree: 3, ctrl: ctrl, knots: knots, weights: nil)
}

/// 把若干行（共享次数/节点/权重的曲线）放样成曲面，u 方向为三次。
///
/// 每行是一条 v 曲线；行间沿 u 用与 `interpolateCubic` 相同的
/// Catmull-Rom / Bezier 方案插值，作用在齐次控制点上，使有理行（圆弧）保持精确。
/// 对应 Python 的 `interpolate_cubic_surface_rows(rows, params)`。
func interpolateCubicSurfaceRows(_ rows: [NurbsCurve], _ params: [Double]) throws -> NurbsSurface {
    if rows.count < 2 {
        throw GeomError(message: "lofting needs at least two rows")
    }
    let q = rows[0].degree
    let vk = rows[0].knots
    let nV = rows[0].ctrl.count
    let rational = rows[0].isRational
    for r in rows {
        if r.degree != q || r.ctrl.count != nV || r.knots.count != vk.count {
            throw GeomError(message: "lofting rows must share degree and knot structure")
        }
    }
    // H[i][j]：4 元齐次控制点
    var H: [[[Double]]] = []
    H.reserveCapacity(rows.count)
    for r in rows {
        H.append(homog(r.ctrl, r.weights))
    }
    let n = rows.count
    // u 参数：使用给定 params（单调）；每列的切向按 Catmull-Rom 估计
    var ctrlRows: [[[Double]]] = []
    var uk: [Double] = [params[0], params[0], params[0], params[0]]
    for i in 0..<(n - 1) {
        let h = params[i + 1] - params[i]
        if h <= 0 {
            throw GeomError(message: "loft parameters must increase")
        }
        let P0 = H[i]
        let P1 = H[i + 1]
        let T0 = colTangent(H, params, i)
        let T1 = colTangent(H, params, i + 1)
        if i == 0 {
            ctrlRows.append(P0)
        }
        var row1: [[Double]] = []
        var row2: [[Double]] = []
        row1.reserveCapacity(nV)
        row2.reserveCapacity(nV)
        for j in 0..<nV {
            var c1 = [Double](repeating: 0.0, count: 4)
            var c2 = [Double](repeating: 0.0, count: 4)
            for d in 0..<4 {
                c1[d] = P0[j][d] + T0[j][d] * h / 3.0
                c2[d] = P1[j][d] - T1[j][d] * h / 3.0
            }
            row1.append(c1)
            row2.append(c2)
        }
        ctrlRows.append(row1)
        ctrlRows.append(row2)
        ctrlRows.append(P1)
        if i < n - 2 {
            let pu = params[i + 1]
            uk.append(contentsOf: [pu, pu, pu])
        }
    }
    let pl = params[params.count - 1]
    uk.append(contentsOf: [pl, pl, pl, pl])
    var ctrl: [[[Double]]] = []
    for row in ctrlRows {
        var r: [[Double]] = []
        for c in row {
            r.append([c[0] / c[3], c[1] / c[3], c[2] / c[3]])
        }
        ctrl.append(r)
    }
    var weights: [[Double]]? = nil
    if rational {
        var w2: [[Double]] = []
        for row in ctrlRows {
            var r: [Double] = []
            for c in row {
                r.append(c[3])
            }
            w2.append(r)
        }
        weights = w2
    }
    return try NurbsSurface(uDegree: 3,
                            vDegree: q,
                            ctrl: ctrl,
                            uKnots: uk,
                            vKnots: vk,
                            weights: weights)
}

/// 第 i 行每一列的 dH/du 估计（差分）。对应 Python 的 `_col_tangent(H, params, i)`。
func colTangent(_ H: [[[Double]]], _ params: [Double], _ i: Int) -> [[Double]] {
    let n = H.count
    var out: [[Double]] = []
    let nj = H.isEmpty ? 0 : H[0].count
    for j in 0..<nj {
        var c = [Double](repeating: 0.0, count: 4)
        if n == 2 {
            let a = H[0][j]
            let b = H[1][j]
            let ha = params[1] - params[0]
            for d in 0..<4 {
                c[d] = (b[d] - a[d]) / ha
            }
        } else if i == 0 {
            let a = H[0][j]
            let b = H[1][j]
            let ha = params[1] - params[0]
            let cc = H[2][j]
            let hb = params[2] - params[1]
            // 二阶单侧
            for d in 0..<4 {
                c[d] = (b[d] - a[d]) / ha * (2 * ha + hb) / (ha + hb)
                    - (cc[d] - b[d]) / hb * ha / (ha + hb)
            }
        } else if i == n - 1 {
            let a = H[n - 2][j]
            let b = H[n - 1][j]
            let hb = params[n - 1] - params[n - 2]
            let cc = H[n - 3][j]
            let ha = params[n - 2] - params[n - 3]
            for d in 0..<4 {
                c[d] = (b[d] - a[d]) / hb * (2 * hb + ha) / (ha + hb)
                    - (a[d] - cc[d]) / ha * hb / (ha + hb)
            }
        } else {
            let a = H[i - 1][j]
            let b = H[i][j]
            let cc = H[i + 1][j]
            let ha = params[i] - params[i - 1]
            let hb = params[i + 1] - params[i]
            // 非均匀加权中心差分
            for d in 0..<4 {
                c[d] = ((cc[d] - b[d]) / hb * ha + (b[d] - a[d]) / ha * hb) / (ha + hb)
            }
        }
        out.append(c)
    }
    return out
}

// MARK: - 解析曲面

/// 公共接口：`eval` / `normal`（自然法向，单位）/ `project`。
///
/// 对应 Python 的 `class Surface`：三个方法都是**抽象桩**（子类覆写）。
/// Swift 侧用 `fatalError` 表示抽象（Python 里是 `raise NotImplementedError`）。
/// 这三个方法都是 `throws`，以便子类把 `unit()` 的 `GeomError` 原样向上传递。
class Surface: @unchecked Sendable {
    init() {}

    /// 抽象：在 (u, v) 处求值。
    func eval(u: Double, v: Double) throws -> Vec {
        fatalError("abstract")
    }

    /// 抽象：在 (u, v) 处的自然单位法向。
    func normal(u: Double, v: Double) throws -> Vec {
        fatalError("abstract")
    }

    /// 抽象：最近点投影，返回 (u, v)。
    func project(_ p: Vec) throws -> (Double, Double) {
        fatalError("abstract")
    }
}

/// 平面。对应 Python 的 `class Plane`。
final class Plane: Surface, @unchecked Sendable {
    let p: Vec
    let n: Vec
    let x: Vec
    let y: Vec

    /// 对应 `Plane(pvec, normal, x_axis)`。
    init(pvec: Vec, normal: Vec, xAxis: Vec) throws {
        let n0 = try unit(normal)
        let x0 = try unit(xAxis)
        self.p = pvec
        self.n = n0
        self.x = x0
        self.y = cross(n0, x0)
        super.init()
    }

    override func eval(u: Double, v: Double) throws -> Vec {
        return add(p, add(mul(x, u), mul(y, v)))
    }

    override func normal(u: Double, v: Double) throws -> Vec {
        return n
    }

    override func project(_ p: Vec) throws -> (Double, Double) {
        let d = sub(p, self.p)
        return (dot(d, x), dot(d, y))
    }
}

/// 圆柱。对应 Python 的 `class Cylinder`（u = 角度，v = 沿轴位移）。
final class Cylinder: Surface, @unchecked Sendable {
    let p: Vec
    let a: Vec
    let r: Double
    let x: Vec
    let y: Vec

    /// 对应 `Cylinder(pvec, axis, radius, x_axis)`。
    init(pvec: Vec, axis: Vec, radius: Double, xAxis: Vec) throws {
        let a0 = try unit(axis)
        let x0 = try unit(xAxis)
        self.p = pvec
        self.a = a0
        self.r = radius
        self.x = x0
        self.y = cross(a0, x0)
        super.init()
    }

    override func eval(u: Double, v: Double) throws -> Vec {
        let e = add(mul(x, cos(u)), mul(y, sin(u)))
        return add(p, add(mul(e, r), mul(a, v)))
    }

    override func normal(u: Double, v: Double) throws -> Vec {
        return add(mul(x, cos(u)), mul(y, sin(u)))
    }

    override func project(_ p: Vec) throws -> (Double, Double) {
        let d = sub(p, self.p)
        let v = dot(d, a)
        let u = atan2(dot(d, y), dot(d, x))
        return (u, v)
    }
}

/// 圆锥（Parasolid 写法）：`R(u,v) = P + vA + (X cos u + Y sin u)(r + v tan a)`。
///
/// XT Format Reference 印的是 “- vA”；实际 SolidWorks 数据（以及与之等价的
/// ISO 10303-42 conical_surface）用 `+ vA`：顶点在 -A 侧，半径沿 +A 增大。
/// 自然法向朝外（径向朝外、向顶点方向倾斜）。
/// 对应 Python 的 `class Cone`。
final class Cone: Surface, @unchecked Sendable {
    let p: Vec
    let a: Vec
    let r: Double
    let sinA: Double
    let cosA: Double
    let tanA: Double
    let x: Vec
    let y: Vec

    /// 对应 `Cone(pvec, axis, radius, sin_a, cos_a, x_axis)`。
    init(pvec: Vec, axis: Vec, radius: Double, sinA: Double, cosA: Double, xAxis: Vec) throws {
        let a0 = try unit(axis)
        let x0 = try unit(xAxis)
        self.p = pvec
        self.a = a0
        self.r = radius
        self.sinA = sinA
        self.cosA = cosA
        self.tanA = sinA / cosA
        self.x = x0
        self.y = cross(a0, x0)
        super.init()
    }

    override func eval(u: Double, v: Double) throws -> Vec {
        let rho = r + v * tanA
        let e = add(mul(x, cos(u)), mul(y, sin(u)))
        return add(add(p, mul(a, v)), mul(e, rho))
    }

    override func normal(u: Double, v: Double) throws -> Vec {
        let eR = add(mul(x, cos(u)), mul(y, sin(u)))
        // N = rho (e_r - tan a * A) 归一化 = cos a * e_r - sin a * A（符号随 rho）
        let n = sub(mul(eR, cosA), mul(a, sinA))
        if r + v * tanA < 0 {
            return mul(n, -1.0)
        }
        return n
    }

    override func project(_ p: Vec) throws -> (Double, Double) {
        let d = sub(p, self.p)
        let h = dot(d, a)
        let radial = sub(d, mul(a, h))
        let rr = norm(radial)
        let u = rr > 1e-300 ? atan2(dot(d, y), dot(d, x)) : 0.0
        // (radial, axial) 坐标下过 (r, 0)、方向为 (sin a, cos a) 的母线，
        // 最近点参数 s
        let s = (rr - r) * sinA + h * cosA
        let v = s * cosA
        return (u, v)
    }
}

/// 球。对应 Python 的 `class Sphere`（u = 方位角，v = 极角）。
final class Sphere: Surface, @unchecked Sendable {
    let c: Vec
    let r: Double
    let a: Vec
    let x: Vec
    let y: Vec

    /// 对应 `Sphere(centre, radius, axis, x_axis)`。
    init(centre: Vec, radius: Double, axis: Vec, xAxis: Vec) throws {
        let a0 = try unit(axis)
        let x0 = try unit(xAxis)
        self.c = centre
        self.r = radius
        self.a = a0
        self.x = x0
        self.y = cross(a0, x0)
        super.init()
    }

    override func eval(u: Double, v: Double) throws -> Vec {
        let e = add(mul(x, cos(u)), mul(y, sin(u)))
        return add(c, mul(add(mul(e, cos(v)), mul(a, sin(v))), r))
    }

    override func normal(u: Double, v: Double) throws -> Vec {
        let e = add(mul(x, cos(u)), mul(y, sin(u)))
        return add(mul(e, cos(v)), mul(a, sin(v)))
    }

    override func project(_ p: Vec) throws -> (Double, Double) {
        let d = sub(p, c)
        let z = dot(d, a)
        let px = dot(d, x)
        let py = dot(d, y)
        let u = (abs(px) + abs(py)) > 1e-300 ? atan2(py, px) : 0.0
        let v = atan2(z, hypot(px, py))
        return (u, v)
    }
}

/// 圆环（甜甜圈 / 球果 / 柠檬形通吃）。对应 Python 的 `class Torus`。
final class Torus: Surface, @unchecked Sendable {
    let c: Vec
    let a: Vec
    let major: Double
    let minor: Double
    let x: Vec
    let y: Vec

    /// 对应 `Torus(centre, axis, major, minor, x_axis)`。
    init(centre: Vec, axis: Vec, major: Double, minor: Double, xAxis: Vec) throws {
        let a0 = try unit(axis)
        let x0 = try unit(xAxis)
        self.c = centre
        self.a = a0
        self.major = major
        self.minor = minor
        self.x = x0
        self.y = cross(a0, x0)
        super.init()
    }

    override func eval(u: Double, v: Double) throws -> Vec {
        let e = add(mul(x, cos(u)), mul(y, sin(u)))
        return add(c, add(mul(e, major + minor * cos(v)), mul(a, minor * sin(v))))
    }

    override func normal(u: Double, v: Double) throws -> Vec {
        let e = add(mul(x, cos(u)), mul(y, sin(u)))
        let n = add(mul(e, cos(v)), mul(a, sin(v)))
        // 自然法向 = dP/du x dP/dv；符号随 (R + r cos v)
        if major + minor * cos(v) < 0 {
            return mul(n, -1.0)
        }
        return n
    }

    override func project(_ p: Vec) throws -> (Double, Double) {
        let d = sub(p, c)
        let z = dot(d, a)
        let px = dot(d, x)
        let py = dot(d, y)
        let u = (abs(px) + abs(py)) > 1e-300 ? atan2(py, px) : 0.0
        let rho = hypot(px, py)
        // rho = R + r cos v, z = r sin v 对甜甜圈、球果、柠檬形一致成立
        let v = atan2(z, rho - major)
        return (u, v)
    }
}

/// 扫掠（拉伸）面：截面曲线沿 `sweep` 方向扫掠。
/// 对应 Python 的 `class SweptSurface(sec, t0, t1, sweep)`。
final class SweptSurface: Surface, @unchecked Sendable {
    /// t -> (point, tangent)
    let section: (Double) -> (Vec, Vec)
    let t0: Double
    let t1: Double
    let d: Vec

    /// 对应 `SweptSurface(section, t0, t1, sweep)`。
    init(section: @escaping (Double) -> (Vec, Vec), t0: Double, t1: Double, sweep: Vec) throws {
        let d0 = try unit(sweep)
        self.section = section
        self.t0 = t0
        self.t1 = t1
        self.d = d0
        super.init()
    }

    override func eval(u: Double, v: Double) throws -> Vec {
        return add(section(u).0, mul(d, v))
    }

    override func normal(u: Double, v: Double) throws -> Vec {
        return try unit(cross(section(u).1, d))
    }

    override func project(_ p: Vec) throws -> (Double, Double) {
        // 在 u 上最小化 p 到直线 C(u) + v D 的距离
        var best: (Double, Double, Double)? = nil
        let n = 64
        for i in 0..<(n + 1) {
            let t = t0 + (t1 - t0) * Double(i) / Double(n)
            let c = section(t).0
            let dd = sub(p, c)
            let v = dot(dd, d)
            let e = norm(sub(dd, mul(d, v)))
            if best == nil || e < best!.0 {
                best = (e, t, v)
            }
        }
        guard let bb = best else {
            fatalError("SweptSurface.project: empty sample set")
        }
        // 以 t 为中心做黄金分割细化
        let lo = max(t0, bb.1 - (t1 - t0) / Double(n))
        let hi = min(t1, bb.1 + (t1 - t0) / Double(n))

        func f(_ tt: Double) -> Double {
            let c = self.section(tt).0
            let dd = sub(p, c)
            return norm(sub(dd, mul(self.d, dot(dd, self.d))))
        }

        let t = golden(f, lo, hi)
        let c = section(t).0
        return (t, dot(sub(p, c), d))
    }
}

/// 旋转（车削）面：母线绕 `axis` 旋转。
/// 对应 Python 的 `class SpunSurface(profile, t0, t1, base, axis)`。
final class SpunSurface: Surface, @unchecked Sendable {
    /// t -> (point, tangent)
    let profile: (Double) -> (Vec, Vec)
    let t0: Double
    let t1: Double
    let base: Vec
    let a: Vec

    /// 对应 `SpunSurface(profile, t0, t1, base, axis)`。
    init(profile: @escaping (Double) -> (Vec, Vec), t0: Double, t1: Double, base: Vec, axis: Vec) throws {
        let a0 = try unit(axis)
        self.profile = profile
        self.t0 = t0
        self.t1 = t1
        self.base = base
        self.a = a0
        super.init()
    }

    override func eval(u: Double, v: Double) throws -> Vec {
        let c = profile(u).0
        let z = add(base, mul(a, dot(sub(c, base), a)))
        let r = sub(c, z)
        return add(z, add(mul(r, cos(v)), mul(cross(a, r), sin(v))))
    }

    override func normal(u: Double, v: Double) throws -> Vec {
        let pr = profile(u)
        let c = pr.0
        let tc = pr.1
        let z = add(base, mul(a, dot(sub(c, base), a)))
        let r = sub(c, z)
        // dP/du = rotate(tc), dP/dv = rotate(A x r)
        let Su = rotate(tc, a, v)
        let Sv = rotate(cross(a, r), a, v)
        return try unit(cross(Su, Sv))
    }

    override func project(_ p: Vec) throws -> (Double, Double) {
        let d = sub(p, base)
        let h = dot(d, a)
        let radial = sub(d, mul(a, h))
        let rr = norm(radial)
        // 在 (轴向, 径向) 半平面内找使距离最小的 u
        func f(_ t: Double) -> Double {
            let c = self.profile(t).0
            let dc = sub(c, self.base)
            let hc = dot(dc, self.a)
            let rc = norm(sub(dc, mul(self.a, hc)))
            return hypot(hc - h, rc - rr)
        }

        let n = 64
        var best = 0
        var bestVal = f(t0)
        if n >= 1 {
            for i in 1...(n) {
                let val = f(t0 + (t1 - t0) * Double(i) / Double(n))
                if val < bestVal {
                    bestVal = val
                    best = i
                }
            }
        }
        var t = t0 + (t1 - t0) * Double(best) / Double(n)
        t = golden(f, max(t0, t - (t1 - t0) / Double(n)), min(t1, t + (t1 - t0) / Double(n)))
        let c = profile(t).0
        let dc = sub(c, base)
        let rcv = sub(dc, mul(a, dot(dc, a)))
        if norm(rcv) < 1e-300 || rr < 1e-300 {
            return (t, 0.0)
        }
        let x = try unit(rcv)
        let y = cross(a, x)
        let v = atan2(dot(radial, y), dot(radial, x))
        return (t, v)
    }
}

/// 用带缓存采样网格的 `Surface` 接口包装一条 `NurbsSurface`。
///
/// `ext` 可选地放宽投影用的参数域（Parasolid B 曲面可能隐含地延伸到节点范围之外）。
/// 对应 Python 的 `class NurbsSurfaceAdapter(Surface)`；采样网格缓存原为 `_samples`，
/// 惰性构建方法原为 `_grid()`，最近一次投影结果原为 `_last`。
final class NurbsSurfaceAdapter: Surface, @unchecked Sendable {
    let s: NurbsSurface
    /// (u0, u1, v0, v1)
    let ext: (Double, Double, Double, Double)
    let grid: Int
    /// 缓存的采样网格：[(u, v, point)]，对应 Python 的 `_samples`。
    var samples: [(Double, Double, Vec)]?
    /// 最近一次投影得到的 (u, v)，对应 Python 的 `_last`。
    var last: (Double, Double)?

    /// 对应 `NurbsSurfaceAdapter(s, ext=None, grid=20)`。
    init(s: NurbsSurface,
         ext: (Double, Double, Double, Double)? = nil,
         grid: Int = 20) {
        self.s = s
        let du = s.u1 - s.u0
        let dv = s.v1 - s.v0
        if let e = ext {
            self.ext = e
        } else {
            self.ext = (s.u0 - 0.25 * du,
                        s.u1 + 0.25 * du,
                        s.v0 - 0.25 * dv,
                        s.v1 + 0.25 * dv)
        }
        self.grid = grid
        self.samples = nil
        self.last = nil
        super.init()
    }

    override func eval(u: Double, v: Double) throws -> Vec {
        return s.eval(u: u, v: v)
    }

    override func normal(u: Double, v: Double) throws -> Vec {
        return try s.normal(u: u, v: v)
    }

    /// 惰性构建的 (u, v, point) 采样网格。对应 Python 的 `_grid()`。
    func gridSamples() -> [(Double, Double, Vec)] {
        if let cached = samples {
            return cached
        }
        let ns = s
        let g = grid
        var out: [(Double, Double, Vec)] = []
        if g >= 0 {
            for i in 0..<(g + 1) {
                let u = ns.u0 + (ns.u1 - ns.u0) * Double(i) / Double(g)
                for j in 0..<(g + 1) {
                    let v = ns.v0 + (ns.v1 - ns.v0) * Double(j) / Double(g)
                    out.append((u, v, ns.eval(u: u, v: v)))
                }
            }
        }
        samples = out
        return out
    }

    override func project(_ p: Vec) throws -> (Double, Double) {
        var best: (Double, Double, Double)? = nil
        for (u, v, q) in gridSamples() {
            let d = pow(q[0] - p[0], 2.0) + pow(q[1] - p[1], 2.0) + pow(q[2] - p[2], 2.0)
            if best == nil || d < best!.0 {
                best = (d, u, v)
            }
        }
        guard let bb = best else {
            fatalError("NurbsSurfaceAdapter.project: empty grid")
        }
        var cands: [(Double, Double)] = [(bb.1, bb.2)]
        if let l = last {
            cands.append(l)
        }
        var res: (Double, Double, Double)? = nil
        for (u0, v0) in cands {
            let r = newtonProject(s, p, u0, v0, ext)
            if res == nil || r.2 < res!.2 {
                res = r
            }
        }
        guard let rr = res else {
            fatalError("NurbsSurfaceAdapter.project: no candidate")
        }
        last = (rr.0, rr.1)
        return (rr.0, rr.1)
    }
}

// MARK: - 最近点投影

/// 从 (u, v) 出发、在 dom 内的阻尼 Gauss-Newton 最近点迭代。
/// 对应 Python 的 `newton_project(s, p, u, v, dom)`，返回 `(u, v, d)`。
func newtonProject(_ s: NurbsSurface,
                   _ p: Vec,
                   _ u: Double,
                   _ v: Double,
                   _ dom: (Double, Double, Double, Double)) -> (Double, Double, Double) {
    let (u0, u1, v0, v1) = dom
    var u = u
    var v = v
    let d0 = s.evalDerivs(u: u, v: v)
    var S = d0.0
    var Su = d0.1
    var Sv = d0.2
    var d = dist(S, p)
    for _ in 0..<60 {
        let r = sub(S, p)
        let a11 = dot(Su, Su)
        let a12 = dot(Su, Sv)
        let a22 = dot(Sv, Sv)
        let b1 = -dot(r, Su)
        let b2 = -dot(r, Sv)
        let det = a11 * a22 - a12 * a12
        if abs(det) < 1e-300 {
            break
        }
        let du = (b1 * a22 - b2 * a12) / det
        let dv = (a11 * b2 - a12 * b1) / det
        var step = 1.0
        var improved = false
        for _ in 0..<12 {
            let un = min(max(u + step * du, u0), u1)
            let vn = min(max(v + step * dv, v0), v1)
            let dn0 = s.evalDerivs(u: un, v: vn)
            let dn = dist(dn0.0, p)
            if dn <= d {
                u = un
                v = vn
                S = dn0.0
                Su = dn0.1
                Sv = dn0.2
                d = dn
                improved = true
                break
            }
            step *= 0.5
        }
        if !improved || (abs(du) < 1e-13 && abs(dv) < 1e-13) {
            break
        }
    }
    return (u, v, d)
}

/// 绕 `axis` 旋转 `ang` 弧度（罗德里格斯公式）。对应 Python 的 `rotate(v, axis, ang)`。
func rotate(_ v: Vec, _ axis: Vec, _ ang: Double) -> Vec {
    let c = cos(ang)
    let s = sin(ang)
    return add(add(mul(v, c), mul(cross(axis, v), s)), mul(axis, dot(axis, v) * (1 - c)))
}

/// 黄金分割搜索（默认 60 次迭代）。对应 Python 的 `golden(f, a, b, iters=60)`。
func golden(_ f: (Double) -> Double, _ a: Double, _ b: Double, _ iters: Int = 60) -> Double {
    let g = (sqrt(5.0) - 1) / 2
    var a = a
    var b = b
    var c = b - g * (b - a)
    var d = a + g * (b - a)
    var fc = f(c)
    var fd = f(d)
    if iters >= 1 {
        for _ in 1...iters {
            if fc < fd {
                b = d
                d = c
                fd = fc
                c = b - g * (b - a)
                fc = f(c)
            } else {
                a = c
                c = d
                fc = fd
                d = a + g * (b - a)
                fd = f(d)
            }
        }
    }
    return 0.5 * (a + b)
}

/// NURBS 曲面最近点投影：粗网格 + Newton。对应 Python 的 `project_newton(s, p, grid=12)`。
func projectNewton(_ s: NurbsSurface, _ p: Vec, _ grid: Int = 12) -> (Double, Double) {
    var best: (Double, Double, Double)? = nil
    if grid >= 0 {
        for i in 0..<(grid + 1) {
            let u = s.u0 + (s.u1 - s.u0) * Double(i) / Double(grid)
            for j in 0..<(grid + 1) {
                let v = s.v0 + (s.v1 - s.v0) * Double(j) / Double(grid)
                let d = dist(s.eval(u: u, v: v), p)
                if best == nil || d < best!.0 {
                    best = (d, u, v)
                }
            }
        }
    }
    guard let bb = best else {
        fatalError("projectNewton: empty grid")
    }
    var u = bb.1
    var v = bb.2
    for _ in 0..<40 {
        let d0 = s.evalDerivs(u: u, v: v)
        let S = d0.0
        let Su = d0.1
        let Sv = d0.2
        let r = sub(S, p)
        // f(u,v) = |S - p|^2 / 2 上的 Gauss-Newton 步
        let a11 = dot(Su, Su)
        let a12 = dot(Su, Sv)
        let a22 = dot(Sv, Sv)
        let b1 = -dot(r, Su)
        let b2 = -dot(r, Sv)
        let det = a11 * a22 - a12 * a12
        if abs(det) < 1e-30 {
            break
        }
        let du = (b1 * a22 - b2 * a12) / det
        let dv = (a11 * b2 - a12 * b1) / det
        u = min(max(u + du, s.u0), s.u1)
        v = min(max(v + dv, s.v0), s.v1)
        if abs(du) < 1e-13 && abs(dv) < 1e-13 {
            break
        }
    }
    return (u, v)
}
