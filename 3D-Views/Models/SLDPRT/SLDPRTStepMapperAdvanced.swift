import Foundation

// Advanced mapping helpers. These methods preserve the source mapper's
// tolerances and warnings while using the Swift geometry kernel.
extension XtStepMapper {
    internal func emitBSplineSurface(_ input: NurbsSurface) throws -> Int {
        let ns = try input.clamped()
        func knotData(_ values: [Double]) throws -> (String, String) {
            var distinct: [Double] = []
            var mult: [Int] = []
            for value in values {
                if let last = distinct.last, value == last {
                    mult[mult.count - 1] += 1
                } else { distinct.append(value); mult.append(1) }
            }
            return (mult.map(String.init).joined(separator: ","), try distinct.map(fmt).joined(separator: ","))
        }
        let rows = try ns.ctrl.map { row in
            "(\(try row.map { "#\(w.point($0))" }.joined(separator: ",")))"
        }.joined(separator: ",")
        let (um, uk) = try knotData(ns.uKnots)
        let (vm, vk) = try knotData(ns.vKnots)
        let uc = (0..<ns.nV).allSatisfy { j in dist(ns.ctrl[0][j], ns.ctrl[ns.nU - 1][j]) < 1e-9 }
        let vc = (0..<ns.nU).allSatisfy { i in dist(ns.ctrl[i][0], ns.ctrl[i][ns.nV - 1]) < 1e-9 }
        let closed = "\(uc ? ".T." : ".F."),\(vc ? ".T." : ".F.")"
        if let weights = ns.weights {
            let wg = "(\(weights.map { "(\(try $0.map(fmt).joined(separator: ",")))" }.joined(separator: ",")))"
            return w.add("(BOUNDED_SURFACE()B_SPLINE_SURFACE(\(ns.p),\(ns.q),(\(rows)),.UNSPECIFIED.,\(closed),.F.)B_SPLINE_SURFACE_WITH_KNOTS((\(um)),(\(vm)),(\(uk)),(\(vk)),.UNSPECIFIED.)GEOMETRIC_REPRESENTATION_ITEM()RATIONAL_B_SPLINE_SURFACE(\(wg))REPRESENTATION_ITEM('')SURFACE())")
        }
        return w.add("B_SPLINE_SURFACE_WITH_KNOTS('',\(ns.p),\(ns.q),(\(rows)),.UNSPECIFIED.,\(closed),.F.,(\(um)),(\(vm)),(\(uk)),(\(vk)),.UNSPECIFIED.)")
    }

    internal func intersectionPoints(_ c: XTNode) throws -> [Vec] {
        guard let chart = deref(c, "chart"), let raw = chart.f["hvec"]?.vecsValue else {
            throw SLDPRTConvertError(code: "unsupported_curve", message: "intersection curve id \(int(c, "node_id")) without chart")
        }
        var points = raw
        for (key, atStart) in [("start", true), ("end", false)] {
            if let n = deref(c, key), ["T", "L"].contains(str(n, "type")), let q = n.f["hvec"]?.vecsValue?.first {
                if atStart { if points.first.map({ dist($0, q) > 1e-9 }) ?? true { points.insert(q, at: 0) } }
                else if points.last.map({ dist($0, q) > 1e-9 }) ?? true { points.append(q) }
            }
        }
        var clean: [Vec] = []
        for p in points where clean.last.map({ dist($0, p) > 1e-10 }) ?? true { clean.append(p) }
        guard clean.count >= 2 else { throw SLDPRTConvertError(code: "unsupported_curve", message: "intersection curve id \(int(c, "node_id")) has fewer than two distinct chart points") }
        return clean
    }

    internal func intersectionEvaluators(_ c: XTNode) throws -> [(Surface, Bool)]? {
        guard let refs = c.f["surface"]?.intsValue else { return nil }
        var out: [(Surface, Bool)] = []
        for ref in refs {
            guard let node = get(ref), let ev = try surface(node).ev else { return nil }
            out.append((ev, str(node, "sense", "+") == "+"))
        }
        return out
    }

    internal func intersectionCurve(_ c: XTNode) throws -> ([Vec], [Vec]?) {
        let points = try intersectionPoints(c)
        guard let evaluators = try intersectionEvaluators(c) else { return (points, nil) }
        // The chart is authoritative; analytic refinement is deliberately bounded.
        var tangents: [Vec] = []
        for i in points.indices {
            let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
            tangents.append(try unit(sub(b, a)))
        }
        _ = evaluators
        return (points, tangents)
    }

    internal func blendBoundaryCurve(_ bound: XTNode, _ reference: [Vec]) throws -> NurbsCurve? {
        guard let blend = deref(bound, "blend"), blend.type == 56 else { return nil }
        let ns = try blendSurface(blend)
        let spine = deref(blend, "spine")
        let swap = str(spine, "sense", "+") != "+"
        let boundary = int(bound, "boundary")
        let col = ((1 - boundary) == 0) != swap ? 0 : ns.nV - 1
        let ctrl = ns.ctrl.map { $0[col] }
        let weights = ns.weights?.map { $0[col] }
        let curve = try NurbsCurve(degree: ns.p, ctrl: ctrl, knots: ns.uKnots, weights: weights)
        if !reference.isEmpty {
            let a = curve.eval(curve.t0), b = curve.eval(curve.t1)
            if dist(a, reference[0]) + dist(b, reference[reference.count - 1]) > dist(a, reference[reference.count - 1]) + dist(b, reference[0]) { return try reverseCurve(curve) }
        }
        return curve
    }

    internal func spCurve3D(_ c: XTNode, _ range: (Double, Double)?) throws -> (NurbsCurve, Bool) {
        guard let host = deref(c, "surface"), let bc = deref(c, "b_curve") else { throw SLDPRTConvertError(code: "unsupported_curve", message: "SP-curve id \(int(c, "node_id")) without surface or 2D curve") }
        let c2 = try nurbsCurve(bc); guard c2.dim == 2, let ev = try surface(host).ev else { throw SLDPRTConvertError(code: "unsupported_curve", message: "SP-curve id \(int(c, "node_id")) cannot be evaluated") }
        let a = range.map { max(c2.t0, $0.0) } ?? c2.t0, b = range.map { min(c2.t1, $0.1) } ?? c2.t1
        let count = max(8, 4 * c2.ctrl.count)
        var pts: [Vec] = []
        for i in 0...count { let t = a + (b - a) * Double(i) / Double(count); let uv = c2.eval(t); pts.append(try ev.eval(u: uv[0], v: uv[1])) }
        return (try interpolateCubic(pts), host.type == 50)
    }

    internal func curveParamEvaluator(_ c: XTNode) throws -> ((Double) throws -> (Vec, Vec), Double, Double)? {
        switch c.type {
        case 30:
            let p = vec(c, "pvec")!, d = try unit(vec(c, "direction")!)
            return ({ t in (add(p, mul(d, t)), d) }, -1000, 1000)
        case 31:
            let p = vec(c, "centre")!, n = try unit(vec(c, "normal")!), x = try unit(vec(c, "x_axis")!), r = dbl(c, "radius"), y = cross(n, x)
            return ({ t in (add(p, add(mul(x, r * cos(t)), mul(y, r * sin(t)))), add(mul(x, -r * sin(t)), mul(y, r * cos(t)))) }, 0, 2 * Double.pi)
        case 32:
            let p = vec(c, "centre")!, n = try unit(vec(c, "normal")!), x = try unit(vec(c, "x_axis")!), a = dbl(c, "major_radius"), b = dbl(c, "minor_radius"), y = cross(n, x)
            return ({ t in (add(p, add(mul(x, a * cos(t)), mul(y, b * sin(t)))), add(mul(x, -a * sin(t)), mul(y, b * cos(t)))) }, 0, 2 * Double.pi)
        case 134:
            let n = try nurbsCurve(c); guard n.dim == 3 else { return nil }; return ({ t in n.evalDeriv(t) }, n.t0, n.t1)
        default: return nil
        }
    }

    internal func blendSurface(_ s: XTNode) throws -> NurbsSurface {
        if let cached = blends[s.index] { return cached }
        guard let spine = deref(s, "spine") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "blend surface id \(int(s, "node_id")) without spine") }
        let supports = (s.f["surface"]?.intsValue ?? []).compactMap(get)
        guard supports.count == 2 else { throw SLDPRTConvertError(code: "unsupported_surface", message: "blend surface id \(int(s, "node_id")) with missing support surface") }
        let radius = (doubles(s, "range") ?? [0, 0]).map(abs).max() ?? 0
        let ce = try curveParamEvaluator(spine)
        let points: [Vec]
        if let ce {
            points = try (0...64).map { i in let t = ce.1 + (ce.2 - ce.1) * Double(i) / 64; return try ce.0(t).0 }
        } else { points = try intersectionPoints(spine) }
        guard points.count >= 2 else { throw SLDPRTConvertError(code: "unsupported_surface", message: "blend surface id \(int(s, "node_id")) spine too short") }
        var rows: [NurbsCurve] = []
        for p in points {
            let f0 = try supports[0].type == 56 ? p : try surface(supports[0]).ev!.eval(u: try surface(supports[0]).ev!.project(p).0, v: try surface(supports[0]).ev!.project(p).1)
            let f1 = try surface(supports[1]).ev!.eval(u: try surface(supports[1]).ev!.project(p).0, v: try surface(supports[1]).ev!.project(p).1)
            let x = try unit(sub(f0, p)); let d = sub(f1, p); let y0 = sub(d, mul(x, dot(d, x))); let y = try unit(y0)
            let angle = atan2(dot(d, y), dot(d, x)); rows.append(try arcNurbs(centre: p, xAxis: x, yAxis: y, radius: radius > 0 ? radius : dist(f0, p), a0: 0, a1: max(angle, 1e-9)))
        }
        let params = points.enumerated().map { Double($0.offset) }
        let result = try interpolateCubicSurfaceRows(rows, params)
        blends[s.index] = result
        warn("rolling_ball_blend", "rolling_ball_blend: exact rolling-ball blend surfaces approximated by interpolating rational B-spline surfaces (exact circular cross-sections)")
        return result
    }

    internal func curveSupport(_ blend: XTNode) throws -> Surface {
        guard let spine = deref(blend, "spine") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "degenerate blend id \(int(blend, "node_id")) without spine") }
        let eval = try curveParamEvaluator(spine)
        guard let eval else { throw SLDPRTConvertError(code: "unsupported_surface", message: "cliff edge curve cannot be evaluated") }
        let pts = try (0...256).map { i in let t = eval.1 + (eval.2 - eval.1) * Double(i) / 256; return try eval.0(t).0 }
        return try CurveSupport(curve: interpolateCubic(pts))
    }

    internal func spineSamples(_ spine: XTNode, _ blend: XTNode, _ offsets: [(Surface, Bool)]) throws -> ([Vec], ((Double) throws -> Vec)?) {
        if spine.type == 38 { return (try intersectionPoints(spine), nil) }
        guard let ev = try curveParamEvaluator(spine) else { throw SLDPRTConvertError(code: "unsupported_surface", message: "blend spine cannot be sampled") }
        let pts = try (0...64).map { i in let t = ev.1 + (ev.2 - ev.1) * Double(i) / 64; return try ev.0(t).0 }
        _ = blend; _ = offsets
        return (pts, { u in try ev.0(ev.1 + (ev.2 - ev.1) * u).0 })
    }

    internal func headerEntities() -> [String: Int] {
        let app = w.add("APPLICATION_CONTEXT('automotive_design')")
        _ = w.add("APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2003,#\(app))")
        let pc = w.add("PRODUCT_CONTEXT('',#\(app),'mechanical')")
        let pdc = w.add("PRODUCT_DEFINITION_CONTEXT('detailed design',#\(app),'design')")
        let mm = w.add("(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.))")
        let rad = w.add("(NAMED_UNIT(*)PLANE_ANGLE_UNIT()SI_UNIT($,.RADIAN.))")
        let sr = w.add("(NAMED_UNIT(*)SI_UNIT($,.STERADIAN.))")
        let unc = w.add("UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-05),#\(mm),'distance_accuracy_value','Maximum model space distance between geometric entities at asserted connectivities')")
        let geo = w.add("(GEOMETRIC_REPRESENTATION_CONTEXT(3)GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#\(unc)))GLOBAL_UNIT_ASSIGNED_CONTEXT((#\(mm),#\(rad),#\(sr))REPRESENTATION_CONTEXT('Context3D','3D'))")
        return ["app": app, "pc": pc, "pdc": pdc, "geo": geo]
    }
}

