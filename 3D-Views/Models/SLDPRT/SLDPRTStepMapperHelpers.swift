import Foundation

internal func hermiteMid(_ pa: Vec, _ ta: Vec, _ pb: Vec, _ tb: Vec) -> Vec {
    let c = dist(pa, pb)
    let ua = norm(ta) > 1e-300 ? (try? unit(ta)) ?? ta : ta
    let ub = norm(tb) > 1e-300 ? (try? unit(tb)) ?? tb : tb
    return add(mul(add(pa, pb), 0.5), mul(sub(ua, ub), c / 8.0))
}

internal func tangentsFromSurfaces(_ pts: [Vec], _ evs: [(Surface, Bool)]) -> [Vec]? {
    var out: [Vec] = []
    for i in pts.indices {
        var ns: [Vec] = []
        do {
            for (ev, positive) in evs {
                let uv = try ev.project(pts[i])
                let n = try ev.normal(u: uv.0, v: uv.1)
                ns.append(positive ? n : mul(n, -1.0))
            }
        } catch { return nil }
        guard ns.count >= 2 else { return nil }
        var t = cross(ns[0], ns[1])
        let ref = pts.count > 1 ? sub(pts[min(i + 1, pts.count - 1)], pts[max(i - 1, 0)]) : [0, 0, 0]
        if norm(t) < 1e-6 {
            guard norm(ref) >= 1e-300, let u = try? unit(ref) else { return nil }
            out.append(u)
        } else {
            guard let u = try? unit(t) else { return nil }
            t = u
            out.append(norm(ref) > 1e-300 && dot(t, ref) < 0 ? mul(t, -1.0) : t)
        }
    }
    return out
}

internal func insideDomain(_ ev: Surface) -> Bool {
    if let n = ev as? NurbsSurfaceAdapter, let uv = n.last {
        let s = n.s, du = (s.u1 - s.u0) * 0.01, dv = (s.v1 - s.v0) * 0.01
        return s.u0 - du <= uv.0 && uv.0 <= s.u1 + du && s.v0 - dv <= uv.1 && uv.1 <= s.v1 + dv
    }
    if let o = ev as? OffsetEval { return insideDomain(o.base) }
    return true
}

internal func projectBoth(_ p: Vec, _ evs: [(Surface, Bool)]) -> Vec? {
    var q = p, moved = 1.0
    for _ in 0..<80 {
        moved = 0
        do {
            for (ev, _) in evs {
                let uv = try ev.project(q), r = try ev.eval(u: uv.0, v: uv.1)
                moved = max(moved, dist(q, r)); q = r
            }
        } catch { return nil }
        if moved < 1e-12 { break }
    }
    guard moved <= 1e-10 && evs.allSatisfy({ insideDomain($0.0) }) else { return nil }
    return q
}

internal func refineOnSurfaces(_ pts: [Vec], _ tans: [Vec], _ evs: [(Surface, Bool)], tol: Double = 1e-7, minSegments: Int = 0) -> ([Vec], [Vec]) {
    guard pts.count > 1, tans.count == pts.count else { return (pts, tans) }
    let total = zip(pts.dropLast(), pts.dropFirst()).reduce(0.0) { $0 + dist($1.0, $1.1) }
    let maxLen = minSegments > 0 && total > 0 ? total / Double(minSegments) : .infinity
    var outP = [pts[0]], outT = [tans[0]], budget = 600
    func tangent(_ q: Vec, _ ref: Vec) -> Vec? {
        guard let ts = tangentsFromSurfaces([q], evs), let t = ts.first else { return nil }
        return dot(t, ref) >= 0 ? t : mul(t, -1.0)
    }
    func rec(_ pa: Vec, _ ta: Vec, _ pb: Vec, _ tb: Vec, _ depth: Int) {
        let chord = dist(pa, pb), need = chord > maxLen
        if depth < 8 && budget > 0 && chord > 1e-6 {
            let m = hermiteMid(pa, ta, pb, tb)
            if let q = projectBoth(m, evs), dist(q, m) < 0.05 * chord + 1e-9,
               dist(q, m) > max(tol, 1e-6 * chord) || need,
               let tq = tangent(q, sub(pb, pa)) {
                budget -= 1; rec(pa, ta, q, tq, depth + 1); rec(q, tq, pb, tb, depth + 1); return
            }
        }
        outP.append(pb); outT.append(tb)
    }
    for i in 0..<(pts.count - 1) { rec(pts[i], tans[i], pts[i + 1], tans[i + 1], 0) }
    return (outP, outT)
}

internal func sectionAngle(_ cpt: Vec, _ f0: Vec, _ f1: Vec) -> Double {
    let r = 0.5 * (dist(f0, cpt) + dist(f1, cpt))
    guard r >= 1e-300, dist(f0, cpt) >= 1e-300, dist(f1, cpt) >= 1e-300 else { return 0 }
    guard let x = try? unit(sub(f0, cpt)) else { return 0 }
    let d = sub(f1, cpt), y0 = sub(d, mul(x, dot(d, x)))
    guard norm(y0) >= 1e-7 * r, let y = try? unit(y0) else { return 0 }
    return atan2(dot(d, y), dot(d, x))
}

internal func curvePointDistance(_ nc: NurbsCurve, _ p: Vec) -> Double {
    let n = 256, h = (nc.t1 - nc.t0) / Double(n)
    func f(_ t: Double) -> Double { dist(Array(nc.eval(t).prefix(3)), p) }
    let best = (0...n).min { f(nc.t0 + (nc.t1 - nc.t0) * Double($0) / Double(n)) < f(nc.t0 + (nc.t1 - nc.t0) * Double($1) / Double(n)) } ?? 0
    let t = nc.t0 + (nc.t1 - nc.t0) * Double(best) / Double(n)
    return f(golden(f, max(nc.t0, t - h), min(nc.t1, t + h)))
}

internal final class CurveSupport: Surface {
    let curve: NurbsCurve
    private var lastPoint: Vec?
    private var samples: [(Double, Vec)]?
    init(curve: NurbsCurve) { self.curve = curve; super.init() }
    private func grid() -> [(Double, Vec)] {
        if let s = samples { return s }
        let n = 512
        let s = (0...n).map { let t = curve.t0 + (curve.t1 - curve.t0) * Double($0) / Double(n); return (t, Array(curve.eval(t).prefix(3))) }
        samples = s; return s
    }
    override func eval(u: Double, v: Double) throws -> Vec { Array(curve.eval(min(max(u, curve.t0), curve.t1)).prefix(3)) }
    override func normal(u: Double, v: Double) throws -> Vec {
        let foot = try eval(u: u, v: v)
        if let lp = lastPoint, norm(sub(lp, foot)) >= 1e-300 { return try unit(sub(lp, foot)) }
        return try perp(try unit(Array(curve.evalDeriv(u).1.prefix(3))))
    }
    override func project(_ p: Vec) throws -> (Double, Double) {
        lastPoint = p; let g = grid(), index = g.indices.min { dist(g[$0].1, p) < dist(g[$1].1, p) } ?? 0
        let h = (curve.t1 - curve.t0) / 512.0, t0 = g[index].0
        func f(_ t: Double) -> Double { dist(Array(curve.eval(t).prefix(3)), p) }
        return (golden(f, max(curve.t0, t0 - h), min(curve.t1, t0 + h)), 0)
    }
}

internal func degenerateArc(_ pt: Vec, _ nseg: Int) throws -> NurbsCurve {
    let w = cos(Double.pi / 4), ctrl = [[Double]](repeating: pt, count: 2 * nseg + 1), weights = [1.0] + (0..<nseg).flatMap { _ in [w, 1.0] }
    var knots = [0.0, 0.0, 0.0]
    if nseg > 1 { for i in 1..<nseg { knots += [Double(i) / Double(nseg), Double(i) / Double(nseg)] } }
    knots += [1.0, 1.0, 1.0]
    return try NurbsCurve(degree: 2, ctrl: ctrl, knots: knots, weights: weights)
}

internal func curveParamOfPoint(_ fn: (Double) -> Vec, _ t0: Double, _ t1: Double, _ p: Vec, _ periodic: Bool) -> Double {
    _ = periodic; let n = 720, h = (t1 - t0) / Double(n)
    func f(_ t: Double) -> Double { dist(fn(t), p) }
    let best = (0...n).min { f(t0 + (t1 - t0) * Double($0) / Double(n)) < f(t0 + (t1 - t0) * Double($1) / Double(n)) } ?? 0
    let t = t0 + h * Double(best)
    return golden(f, max(t0, t - h), min(t1, t + h))
}

internal func polylineLen(_ pts: [[Double]]) -> Double {
    guard pts.count > 1 else { return 0 }
    return zip(pts.dropLast(), pts.dropFirst()).reduce(0) { a, pair in
        let x = Array(pair.0.prefix(3)) + [0, 0, 0], y = Array(pair.1.prefix(3)) + [0, 0, 0]
        return a + dist(Array(x.prefix(3)), Array(y.prefix(3)))
    }
}

internal func normaliseCurveKnots(_ nc: NurbsCurve) throws -> NurbsCurve {
    let span = nc.t1 - nc.t0, length = polylineLen(nc.ctrl) * SCALE
    guard span > 0, length > 0 else { return nc }; let f = length / span
    guard f < 0.5 || f > 2 else { return nc }
    return try NurbsCurve(degree: nc.degree, ctrl: nc.ctrl, knots: nc.knots.map { ($0 - nc.t0) * f }, weights: nc.weights)
}

internal func normaliseSurfaceKnots(_ ns: NurbsSurface) throws -> NurbsSurface {
    let du = ns.u1 - ns.u0, dv = ns.v1 - ns.v0
    let lu = (0..<ns.nV).reduce(0.0) { $0 + polylineLen((0..<ns.nU).map { ns.ctrl[$0][$1] }) } / Double(max(1, ns.nV)) * SCALE
    let lv = (0..<ns.nU).reduce(0.0) { $0 + polylineLen(ns.ctrl[$1]) } / Double(max(1, ns.nU)) * SCALE
    var fu = du > 0 && lu > 0 ? lu / du : 1, fv = dv > 0 && lv > 0 ? lv / dv : 1
    if 0.5...2 ~= fu { fu = 1 }; if 0.5...2 ~= fv { fv = 1 }
    if fu == 1 && fv == 1 { return ns }
    let uk = fu == 1 ? ns.uKnots : ns.uKnots.map { ($0 - ns.u0) * fu }, vk = fv == 1 ? ns.vKnots : ns.vKnots.map { ($0 - ns.v0) * fv }
    return try NurbsSurface(uDegree: ns.p, vDegree: ns.q, ctrl: ns.ctrl, uKnots: uk, vKnots: vk, weights: ns.weights)
}

internal func reverseCurve(_ nc: NurbsCurve) throws -> NurbsCurve {
    let knots = nc.knots.reversed().map { nc.t0 + nc.t1 - $0 }
    return try NurbsCurve(degree: nc.degree, ctrl: Array(nc.ctrl.reversed()), knots: Array(knots), weights: nc.weights.map { Array($0.reversed()) })
}

internal func carefulProject(_ ev: Surface, _ p: Vec) throws -> Vec {
    if let n = ev as? NurbsSurfaceAdapter {
        let s = n.s, (u0, u1, v0, v1) = n.ext; var best: (Double, Double, Double)?
        for i in 0...40 { for j in 0...40 { let u = u0 + (u1-u0)*Double(i)/40, v = v0 + (v1-v0)*Double(j)/40, d = dist(s.eval(u: u, v: v), p); if best == nil || d < best!.0 { best = (d, u, v) } } }
        guard let b = best else { throw GeomError(message: "NURBS projection has no candidate") }
        let r = newtonProject(s, p, b.1, b.2, n.ext); n.last = (r.0, r.1); return s.eval(u: r.0, v: r.1)
    }
    let uv = try ev.project(p); return try ev.eval(u: uv.0, v: uv.1)
}

internal final class OffsetEval: Surface {
    let base: Surface, offset: Double
    init(base: Surface, offset: Double) { self.base = base; self.offset = offset; super.init() }
    override func eval(u: Double, v: Double) throws -> Vec { add(try base.eval(u: u, v: v), mul(try base.normal(u: u, v: v), offset)) }
    override func normal(u: Double, v: Double) throws -> Vec { try base.normal(u: u, v: v) }
    override func project(_ p: Vec) throws -> (Double, Double) { try base.project(p) }
}

internal struct evNurbs {
    let curve: NurbsCurve
    internal private(set) var approx = false
    init(_ curve: NurbsCurve) { self.curve = curve }
    func callAsFunction(_ s: Double) -> Vec { Array(curve.eval(curve.t0 + (curve.t1 - curve.t0) * s).prefix(3)) }
}

internal func restrictCurve(_ nc: NurbsCurve, _ range: (Double, Double)) throws -> NurbsCurve {
    let a = max(range.0, nc.t0), b = min(range.1, nc.t1)
    if b <= a || (abs(a - nc.t0) < 1e-12 && abs(b - nc.t1) < 1e-12) { return nc }
    let p = nc.degree; var h = homog(nc.ctrl, nc.weights), knots = nc.knots
    for t in [a, b] { let m = knots.filter { abs($0 - t) < 1e-14 }.count; if m < p + 1 { let r = insertKnot(p, h, knots, t, p + 1 - m); h = r.0; knots = r.1 } }
    guard let ia = knots.firstIndex(where: { abs($0 - a) < 1e-14 }), let ib = knots.lastIndex(where: { abs($0 - b) < 1e-14 }) else { return nc }
    let knots2 = Array(knots[ia...ib]), h2 = Array(h[ia..<(ib - p)]), d = dehomog(h2, nc.isRational)
    return try NurbsCurve(degree: p, ctrl: d.0, knots: knots2, weights: d.1)
}

internal func slWriteStep(_ xtBodies: [(XTFile, XTNode, String)], _ fileName: String, _ warnings: inout [String]) throws -> (text: String, solids: Int, faces: Int) {
    let w = StepWriter()
    guard let firstBody = xtBodies.first else { throw SLDPRTConvertError(code: "empty_step", message: "no bodies to write") }
    let first = XtStepMapper(firstBody.0, warnings); first.w = w
    let ctx = first.headerEntities()
    let rawName = fileName.isEmpty ? "part" : String(fileName.split(separator: ".", omittingEmptySubsequences: false).dropLast().joined(separator: "."))
    let productName = (rawName.isEmpty ? "part" : rawName).replacingOccurrences(of: "'", with: "''")
    let prod = w.add("PRODUCT('\(productName)','\(productName)','',(#\(ctx["pc"]!))")
    let pdf = w.add("PRODUCT_DEFINITION_FORMATION('','',#\(prod))")
    let pd = w.add("PRODUCT_DEFINITION('design','',#\(pdf),#\(ctx["pdc"]!))")
    let pds = w.add("PRODUCT_DEFINITION_SHAPE('','',#\(pd))")
    var solids: [Int] = [], faces = 0
    for (xt, body, name) in xtBodies {
        let m = XtStepMapper(xt, warnings, name); m.w = w; m.warned = first.warned
        solids += try m.convertBody(body, name); faces += m.faceCount
        first.warned = m.warned
        warnings = m.warnings
    }
    first.warnings = warnings; first.finishWarnings(); warnings = first.warnings
    let origin = try w.axis2([0,0,0], [0,0,1], [1,0,0])
    let rep = w.add("ADVANCED_BREP_SHAPE_REPRESENTATION('',(#\(origin),\(solids.map { "#\($0)" }.joined(separator: ","))),#\(ctx["geo"]!))")
    w.add("SHAPE_DEFINITION_REPRESENTATION(#\(pds),#\(rep))")
    let head = ["ISO-10303-21;", "HEADER;", "FILE_DESCRIPTION(('sldprt2step conversion of Parasolid XT B-rep'),'2;1');", "FILE_NAME('\(fileName.replacingOccurrences(of: "'", with: "''"))','',(''),(''),'sldprt2step','','');", "FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));", "ENDSEC;", "DATA;"]
    return ((head + w.lines + ["ENDSEC;", "END-ISO-10303-21;", ""]).joined(separator: "\n"), solids.count, faces)
}
