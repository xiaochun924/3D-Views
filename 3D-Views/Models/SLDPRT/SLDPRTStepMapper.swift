import Foundation

internal let SCALE = 1000.0

internal struct SLDPRTConvertError: Error, Sendable {
    internal let code: String
    internal let message: String
    internal init(code: String, message: String) { self.code = code; self.message = message }
}

internal func fmt(_ x: Double) throws -> String {
    guard x.isFinite else { throw SLDPRTConvertError(code: "convert_failed", message: "non-finite number in geometry") }
    if x == 0 { return "0." }
    var s = String(x)
    if s.contains("e") || s.contains("E") {
        let p = s.lowercased().split(separator: "e", maxSplits: 1).map(String.init)
        var m = p.first ?? "0"
        if !m.contains(".") { m += "." }
        return "\(m)E\(Int(p.count > 1 ? p[1] : "0") ?? 0)"
    }
    if !s.contains(".") { s += "." }
    if s.hasSuffix(".0") { s.removeLast() }
    return s
}
internal func fmm(_ x: Double) throws -> String { try fmt(x * SCALE) }
internal func fpt(_ p: Vec) throws -> String {
    guard p.count >= 3 else { throw SLDPRTConvertError(code: "convert_failed", message: "point has fewer than three coordinates") }
    return "(\(try fmm(p[0])),\(try fmm(p[1])),\(try fmm(p[2])))"
}
internal func fdir(_ p: Vec) throws -> String {
    guard p.count >= 3 else { throw SLDPRTConvertError(code: "convert_failed", message: "direction has fewer than three coordinates") }
    return "(\(try fmt(p[0])),\(try fmt(p[1])),\(try fmt(p[2])))"
}

internal final class StepWriter: @unchecked Sendable {
    internal var lines: [String] = []
    internal var nextID: Int = 1
    internal init() {}
    internal func add(_ text: String) -> Int { let id = nextID; nextID += 1; lines.append("#\(id)=\(text);"); return id }
    internal func point(_ p: Vec, _ name: String = "") throws -> Int { add("CARTESIAN_POINT('\(name)',\(try fpt(p)))") }
    internal func direction(_ d: Vec) throws -> Int { add("DIRECTION('',\(try fdir(try unit(d))))") }
    internal func axis2(_ origin: Vec, _ z: Vec, _ x: Vec) throws -> Int {
        let zz = try unit(z); var xx = sub(x, mul(zz, dot(x, zz)))
        if norm(xx) < 1e-12 { xx = try perp(zz) }
        return add("AXIS2_PLACEMENT_3D('',#\(try point(origin)),#\(try direction(zz)),#\(try direction(try unit(xx))))")
    }
}

internal final class SurfaceInfo: @unchecked Sendable {
    internal let stepID: Int; internal let match: Bool; internal let ev: Surface?; internal let approx: Bool
    internal init(stepID: Int, match: Bool, ev: Surface?, approx: Bool = false) { self.stepID = stepID; self.match = match; self.ev = ev; self.approx = approx }
}

internal final class XtStepMapper: @unchecked Sendable {
    internal let xt: XTFile
    internal var w: StepWriter
    internal var warnings: [String]
    internal let bodyLabel: String
    internal var surf: [Int: SurfaceInfo] = [:]
    internal var curveCache: [String: (Int, Bool, CurveEval)] = [:]
    internal var vertexIDs: [Int: Int] = [:]
    internal var edgeIDs: [Int: (Int, Int, Int)] = [:]
    internal var vertexPos: [Int: Vec] = [:]
    internal var blends: [Int: NurbsSurface] = [:]
    internal var warned: [String: Int] = [:]
    internal var faceCount = 0
    internal var solidCount = 0
    internal typealias CurveEval = (Double) throws -> Vec

    internal init(_ xt: XTFile, _ warnings: [String] = [], _ label: String = "") {
        self.xt = xt; self.w = StepWriter(); self.warnings = warnings; self.bodyLabel = label
    }
    internal func warn(_ key: String, _ text: String) { let n = warned[key, default: 0]; warned[key] = n + 1; if n == 0 { warnings.append(text) } }
    internal func finishWarnings() { for i in warnings.indices { for (k,n) in warned where n > 1 && warnings[i].hasPrefix(k + ":") && !warnings[i].hasSuffix("occurrences)") { warnings[i] += " (\(n) occurrences)" } } }
    internal func get(_ idx: Int) -> XTNode? { xt.get(idx) }
    internal func deref(_ n: XTNode?, _ f: String) -> XTNode? { xt.deref(n, f) }
    internal func chain(_ head: XTNode?, _ next: String) -> [XTNode] { xt.chain(head, next) }
    internal func int(_ n: XTNode?, _ key: String, _ d: Int = 0) -> Int { n?.f[key]?.intValue ?? d }
    internal func dbl(_ n: XTNode?, _ key: String, _ d: Double = 0) -> Double { n?.f[key]?.doubleValue ?? d }
    internal func str(_ n: XTNode?, _ key: String, _ d: String = "") -> String { n?.f[key]?.stringValue ?? d }
    internal func vec(_ n: XTNode?, _ key: String) -> Vec? { n?.f[key]?.vecValue }
    internal func doubles(_ n: XTNode?, _ key: String) -> [Double]? { n?.f[key]?.doublesValue }
    internal func ints(_ n: XTNode?, _ key: String) -> [Int]? { n?.f[key]?.intsValue }
    internal func vecs(_ n: XTNode?, _ key: String) -> [Vec]? { n?.f[key]?.vecsValue }

    internal func convertBody(_ body: XTNode, _ name: String) throws -> [Int] {
        let bt = int(body, "body_type")
        guard bt == 1 else { let kind = [2:"wire",3:"sheet",6:"general"][bt] ?? "type \(bt)"; throw SLDPRTConvertError(code:"empty_step", message:"body \(name) is a \(kind) body, not a solid (XT body_type=\(bt))") }
        var solids: [Int] = []
        for region in chain(deref(body,"region"),"next") where str(region,"type") == "S" {
            let shells = chain(deref(region,"shell"),"next"); if shells.isEmpty { continue }
            var ids: [(Int,Double)] = []
            for shell in shells { ids.append(try convertShell(shell)) }
            ids.sort { $0.1 > $1.1 }; let label = (solids.isEmpty ? name : "\(name)_\(solids.count + 1)").replacingOccurrences(of:"'", with:"''")
            if ids.count == 1 { solids.append(w.add("MANIFOLD_SOLID_BREP('\(label)',#\(ids[0].0))")) }
            else { warn("void_shells", "void_shells: solid \(name) has \(ids.count-1) inner void shells (BREP_WITH_VOIDS)"); let v = ids.dropFirst().map { w.add("ORIENTED_CLOSED_SHELL('',*,#\($0.0),.T.)") }; solids.append(w.add("BREP_WITH_VOIDS('\(label)',#\(ids[0].0),(\(v.map{"#\($0)"}.joined(separator:",")))")) }
        }
        guard !solids.isEmpty else { throw SLDPRTConvertError(code:"empty_step", message:"body \(name) has no solid region with shells") }; solidCount += solids.count; return solids
    }

    internal func convertShell(_ shell: XTNode) throws -> (Int, Double) {
        var faces: [Int] = []; var lo = [Double](repeating:.infinity,count:3); var hi = [Double](repeating:-.infinity,count:3); var seen = Set<Int>()
        for face in chain(deref(shell,"face"),"next") where seen.insert(face.index).inserted { faces.append(try convertFace(face, false, &lo, &hi)) }
        for face in chain(deref(shell,"front_face"),"next_front") where seen.insert(face.index).inserted { warn("front_face", "front_face: shell uses a face from its front side (flipped on output)"); faces.append(try convertFace(face, true, &lo, &hi)) }
        guard !faces.isEmpty else { throw SLDPRTConvertError(code:"unsupported_topology", message:"shell #\(shell.index) has no faces (acorn/wire shell)") }
        return (w.add("CLOSED_SHELL('',(\(faces.map{"#\($0)"}.joined(separator:",")))")), lo[0] < hi[0] ? dist(lo,hi) : 0)
    }

    internal func convertFace(_ face: XTNode, _ flip: Bool, _ lo: inout [Double], _ hi: inout [Double]) throws -> Int {
        guard let sn = deref(face,"surface") else { throw SLDPRTConvertError(code:"unsupported_topology", message:"face id \(int(face,"node_id")) has no surface (rubber face)") }
        let si = try surface(sn); var same = (str(face,"sense") == str(sn,"sense")) == si.match; if flip { same.toggle() }
        let loops = chain(deref(face,"loop"),"next"); guard !loops.isEmpty else { throw SLDPRTConvertError(code:"unsupported_topology", message:"face id \(int(face,"node_id")) (\(sn.name)) has no loops (unbounded periodic face)") }
        var specs: [(Int,Double,Bool)] = []
        for loop in loops {
            let fins = finRing(loop); guard !fins.isEmpty else { throw SLDPRTConvertError(code:"unsupported_topology", message:"loop id \(int(loop,"node_id")) has no fins") }
            if let v = deref(fins[0],"vertex"), deref(fins[0],"edge") == nil { specs.append((w.add("VERTEX_LOOP('',#\(try vertex(v,&lo,&hi)))"),0,true)); continue }
            var oes:[Int]=[]; var a=[Double](repeating:.infinity,count:3), b=[Double](repeating:-.infinity,count:3)
            for fin in fins { guard let edge=deref(fin,"edge") else { throw SLDPRTConvertError(code:"unsupported_topology",message:"mixed isolated/ordinary fins in loop id \(int(loop,"node_id"))") }; let (ec,sv,ev)=try edgeCurve(edge,&lo,&hi); var o=str(fin,"sense")=="+"; if flip{o.toggle()}; oes.append(w.add("ORIENTED_EDGE('',*,*,#\(ec),\(o ? ".T.":".F."))")); for id in [sv,ev] { if let p=vertexPos[id] { for k in 0..<3 { a[k]=min(a[k],p[k]); b[k]=max(b[k],p[k]) } } } }
            if flip { oes.reverse() }; specs.append((w.add("EDGE_LOOP('',(\(oes.map{"#\($0)"}.joined(separator:",")))")), a[0] < b[0] ? dist(a,b) : 0, false))
        }
        let outer = specs.indices.max { specs[$0].1 < specs[$1].1 } ?? 0
        let bounds = specs.enumerated().map { i,s in w.add("\(i == outer ? "FACE_OUTER_BOUND" : "FACE_BOUND")('',#\(s.0),.T.)") }
        faceCount += 1; return w.add("ADVANCED_FACE('',(\(bounds.map{"#\($0)"}.joined(separator:","))),#\(si.stepID),\(same ? ".T.":".F."))")
    }

    internal func finRing(_ loop: XTNode) -> [XTNode] { var out:[XTNode]=[], seen=Set<Int>(), cur=deref(loop,"halfedge"); while let c=cur, seen.insert(c.index).inserted, out.count < 1_000_000 { out.append(c); cur=deref(c,"forward") }; return out }
    internal func bboxAdd(_ lo: inout [Double], _ hi: inout [Double], _ p: Vec) { guard lo.count >= 3, hi.count >= 3, p.count >= 3 else { return }; for k in 0..<3 { lo[k] = min(lo[k], p[k]); hi[k] = max(hi[k], p[k]) } }
    internal func vertexPoint(_ v: XTNode?) -> Vec? {
        guard let vertex = v, let pointNode = deref(vertex, "point") else { return nil }
        return vec(pointNode, "pvec")
    }
    internal func vertex(_ v: XTNode, _ lo: inout [Double], _ hi: inout [Double]) throws -> Int { if let id=vertexIDs[v.index]{return id}; guard let p=vec(deref(v,"point"),"pvec"),p.count>=3 else{throw SLDPRTConvertError(code:"unsupported_topology",message:"vertex id \(int(v,"node_id")) has no point")}; vertexPos[v.index]=p; let id=w.add("VERTEX_POINT('',#\(try w.point(p)))"); vertexIDs[v.index]=id; bboxAdd(&lo,&hi,p); return id }
    internal func syntheticVertex(_ key: Int, _ p: Vec, _ lo: inout [Double], _ hi: inout [Double]) throws -> Int { let k = -1_000_000-key; if let id=vertexIDs[k]{return id}; vertexPos[k]=p; let id=w.add("VERTEX_POINT('',#\(try w.point(p)))"); vertexIDs[k]=id; bboxAdd(&lo,&hi,p); return id }

    internal func edgeCurve(_ edge: XTNode, _ lo: inout [Double], _ hi: inout [Double]) throws -> (Int,Int,Int) {
        if let x=edgeIDs[edge.index]{return x}; let fin=deref(edge,"halfedge"), other=deref(fin,"other"), end=deref(fin,"vertex"), start=deref(other,"vertex"); var c=deref(edge,"curve"); var tolerant=false
        if c == nil { tolerant=true; c=deref(fin,"curve") ?? deref(other,"curve"); guard c != nil else{throw SLDPRTConvertError(code:"unsupported_topology",message:"edge id \(int(edge,"node_id")) has neither a curve nor fin curves")}; warn("tolerant_edge","tolerant_edge: tolerant edges rebuilt from their fin SP-curves") }
        let ps=vec(deref(start,"point"),"pvec"), pe=vec(deref(end,"point"),"pvec"); let (cid,var sense,ev)=try curve(c!,ps,pe)
        let sv:Int, evID:Int, si:Int, ei:Int
        if let s=start,let e=end { si=s.index;ei=e.index;sv=try vertex(s,&lo,&hi);evID=try vertex(e,&lo,&hi); if tolerant { let a=try ev(0),b=try ev(1); if dist(a,ps!)+dist(b,pe!) > dist(a,pe!)+dist(b,ps!){sense.toggle()} } }
        else { let p=try ev(0); sv=try syntheticVertex(edge.index,p,&lo,&hi); evID=sv; si=-1_000_000-edge.index; ei=si }
        let id=w.add("EDGE_CURVE('',#\(sv),#\(evID),#\(cid),\(sense ? ".T.":".F."))"); let r=(id,si,ei); edgeIDs[edge.index]=r; return r
    }

    internal func curve(_ c: XTNode, _ start: Vec?, _ end: Vec?, _ range: (Double,Double)? = nil) throws -> (Int,Bool,CurveEval) {
        let sense=str(c,"sense","+")=="+"; switch c.type {
        case 30:
            guard let p = vec(c, "pvec"), let rawDirection = vec(c, "direction"), p.count >= 3 else { throw SLDPRTConvertError(code: "unsupported_curve", message: "line id \(int(c, "node_id")) without origin or direction") }
            let d = try unit(rawDirection)
            let pointID = try w.point(p)
            let directionID = try w.direction(d)
            let vectorID = w.add("VECTOR('',#\(directionID),1.)")
            let id = w.add("LINE('',#\(pointID),#\(vectorID))")
            var a = start ?? p
            var b = end ?? add(p, d)
            if !sense { swap(&a, &b) }
            return (id, sense, { t in lerp(a, b, t) })
        case 31, 32:
            guard let center = vec(c, "centre"), let normal = vec(c, "normal"), let axisX = vec(c, "x_axis") else { throw SLDPRTConvertError(code: "unsupported_curve", message: "analytic curve id \(int(c, "node_id")) has incomplete frame") }
            let n = try unit(normal), x = try unit(axisX)
            let major = c.type == 31 ? dbl(c, "radius") : dbl(c, "major_radius")
            let minor = c.type == 31 ? major : dbl(c, "minor_radius")
            let placement = try w.axis2(center, n, x)
            let entity = c.type == 31 ? "CIRCLE('',#\(placement),\(try fmm(major)))" : "ELLIPSE('',#\(placement),\(try fmm(major)),\(try fmm(minor)))"
            let id = w.add(entity), y = cross(n, x)
            return (id, sense, { t in let a = 2 * Double.pi * t; return add(center, add(mul(x, major * cos(a)), mul(y, minor * sin(a)))) })
        case 134:
            var nc = try nurbsCurve(c)
            guard nc.dim == 3 else { throw SLDPRTConvertError(code: "unsupported_curve", message: "2D B-curve id \(int(c, "node_id")) used directly by an edge") }
            if let range { nc = try restrictCurve(nc, range) }
            let id = try emitBSplineCurve(nc)
            return (id, sense, { t in nc.eval(nc.t0 + (nc.t1 - nc.t0) * t) })
        case 133:
            guard let basis = deref(c, "basis_curve") else { throw SLDPRTConvertError(code: "unsupported_curve", message: "trimmed curve id \(int(c, "node_id")) without basis") }
            let p1 = dbl(c, "parm_1"), p2 = dbl(c, "parm_2"), increasing = p2 > p1
            let pStart = vec(c, increasing ? "point_1" : "point_2"), pEnd = vec(c, increasing ? "point_2" : "point_1")
            let result = try curve(basis, pStart, pEnd, (min(p1, p2), max(p1, p2)))
            return (result.0, increasing == sense, result.2)
        case 38:
            let points = try intersectionPoints(c)
            var spline: NurbsCurve?
            if let refs = ints(c, "surface") {
                for ref in refs {
                    guard let support = get(ref), support.type == 59 else { continue }
                    if let boundary = try blendBoundaryCurve(support, points) { spline = boundary; break }
                }
            }
            if spline == nil {
                let (points, tangents) = try intersectionCurve(c)
                spline = try interpolateCubic(points, tangents)
            }
            guard let nc = spline else { throw SLDPRTConvertError(code: "unsupported_curve", message: "intersection curve id \(int(c, "node_id")) could not be approximated") }
            warn("intersection_curve", "intersection_curve: surface/surface intersection edges approximated by interpolating cubic splines through the XT chart points")
            let id = try emitBSplineCurve(nc)
            return (id, sense, { t in nc.eval(nc.t0 + (nc.t1 - nc.t0) * t) })
        case 137:
            let (nc, exact) = try spCurve3D(c, range)
            if !exact { warn("sp_curve", "sp_curve: curves defined in surface parameter space approximated by cubic splines through evaluated points") }
            let id = try emitBSplineCurve(nc)
            return (id, sense, { t in nc.eval(nc.t0 + (nc.t1 - nc.t0) * t) })
        case 200:
            guard let points = vecs(deref(deref(c, "data"), "pvec"), "values"), points.count >= 2, points.allSatisfy({ $0.count >= 3 }) else { throw SLDPRTConvertError(code: "unsupported_curve", message: "polyline id \(int(c, "node_id")) without points") }
            let pointIDs = try points.map { try w.point($0) }
            let id = w.add("POLYLINE('',(\(pointIDs.map { "#\($0)" }.joined(separator: ","))))")
            return (id, sense, { t in let z = min(max(t, 0), 1) * Double(points.count - 1); let i = min(Int(z), points.count - 2); return lerp(points[i], points[i + 1], z - Double(i)) })
        case 130:
            throw SLDPRTConvertError(code: "unsupported_curve", message: "foreign (PE) curve id \(int(c, "node_id")) cannot be represented")
        default:
            throw SLDPRTConvertError(code: "unsupported_curve", message: "curve node type \(c.name) (id \(int(c, "node_id"))) is not supported")
        }
    }

    internal func nurbsCurve(_ c: XTNode) throws -> NurbsCurve {
        guard let nb = deref(c, "nurbs"),
              let vertexNode = deref(nb, "bspline_vertices"),
              let values = doubles(vertexNode, "vertices"),
              let knotNode = deref(nb, "knot_mult"),
              let multiplicities = ints(knotNode, "mult"),
              let knotValues = doubles(deref(nb, "knots"), "knots") else {
            throw SLDPRTConvertError(code: "unsupported_curve", message: "B-curve id \(int(c, "node_id")) without NURBS data")
        }
        let degree = int(nb, "degree"), count = int(nb, "n_vertices"), dimension = int(nb, "vertex_dim")
        let rational = nb.f["rational"]?.boolValue ?? false
        guard count > 0, dimension > (rational ? 1 : 0), count <= values.count / dimension else {
            throw SLDPRTConvertError(code: "unsupported_curve", message: "B-curve id \(int(c, "node_id")) has invalid vertex dimensions")
        }
        var controls: [[Double]] = [], weights: [Double] = []
        for i in 0..<count {
            let start = i * dimension, row = Array(values[start..<(start + dimension)])
            if rational {
                let weight = row[dimension - 1]
                guard weight.isFinite, weight != 0 else { throw SLDPRTConvertError(code: "unsupported_curve", message: "B-curve id \(int(c, "node_id")) has zero weight") }
                controls.append(row.dropLast().map { $0 / weight }); weights.append(weight)
            } else { controls.append(row) }
        }
        do { return try NurbsCurve(degree: degree, ctrl: controls, knots: expandKnots(knotValues, multiplicities), weights: rational ? weights : nil) }
        catch let error as GeomError { throw SLDPRTConvertError(code: "unsupported_curve", message: "B-curve id \(int(c, "node_id")): \(error.message)") }
    }

    internal func nurbsSurface(_ s: XTNode) throws -> NurbsSurface {
        guard let nb = deref(s, "nurbs"), let vertexNode = deref(nb, "bspline_vertices"),
              let values = doubles(vertexNode, "vertices"),
              let uKnotNode = deref(nb, "u_knots"), let uValues = doubles(uKnotNode, "knots"), let uMult = ints(uKnotNode, "mult"),
              let vKnotNode = deref(nb, "v_knots"), let vValues = doubles(vKnotNode, "knots"), let vMult = ints(vKnotNode, "mult") else {
            throw SLDPRTConvertError(code: "unsupported_surface", message: "B-surface id \(int(s, "node_id")) without NURBS data")
        }
        let p = int(nb, "u_degree"), q = int(nb, "v_degree"), nu = int(nb, "n_u_vertices"), nv = int(nb, "n_v_vertices"), dimension = int(nb, "vertex_dim")
        let rational = nb.f["rational"]?.boolValue ?? false
        guard nu > 0, nv > 0, dimension >= (rational ? 4 : 3), nu <= Int.max / nv, nu * nv <= values.count / dimension else {
            throw SLDPRTConvertError(code: "unsupported_surface", message: "B-surface id \(int(s, "node_id")) has invalid vertex dimensions")
        }
        var controls: [[[Double]]] = [], weightGrid: [[Double]] = []
        for i in 0..<nu {
            var row: [[Double]] = [], weights: [Double] = []
            for j in 0..<nv {
                let start = (i * nv + j) * dimension, v = Array(values[start..<(start + dimension)])
                if rational {
                    let weight = v[dimension - 1]
                    guard weight.isFinite, weight != 0 else { throw SLDPRTConvertError(code: "unsupported_surface", message: "B-surface id \(int(s, "node_id")) has zero weight") }
                    row.append([v[0] / weight, v[1] / weight, v[2] / weight]); weights.append(weight)
                } else { row.append(Array(v.prefix(3))) }
            }
            controls.append(row); if rational { weightGrid.append(weights) }
        }
        do { return try NurbsSurface(uDegree: p, vDegree: q, ctrl: controls, uKnots: expandKnots(uValues, uMult), vKnots: expandKnots(vValues, vMult), weights: rational ? weightGrid : nil) }
        catch let error as GeomError { throw SLDPRTConvertError(code: "unsupported_surface", message: "B-surface id \(int(s, "node_id")): \(error.message)") }
    }

    internal func emitBSplineCurve(_ input: NurbsCurve) throws -> Int {
        let n = try input.clamped()
        let pointIDs = try n.ctrl.map { try w.point($0) }
        var distinct: [Double] = [], multiplicities: [Int] = []
        for knot in n.knots {
            if distinct.last == knot { multiplicities[multiplicities.count - 1] += 1 }
            else { distinct.append(knot); multiplicities.append(1) }
        }
        let mult = multiplicities.map(String.init).joined(separator: ",")
        let values = try distinct.map(fmt).joined(separator: ",")
        let controls = pointIDs.map { "#\($0)" }.joined(separator: ",")
        let closed = dist(n.eval(n.t0), n.eval(n.t1)) < 1e-9 ? ".T." : ".F."
        if let weights = n.weights {
            return w.add("(BOUNDED_CURVE()B_SPLINE_CURVE(\(n.degree),(\(controls)),.UNSPECIFIED.,\(closed),.F.)B_SPLINE_CURVE_WITH_KNOTS((\(mult)),(\(values)),.UNSPECIFIED.)CURVE()GEOMETRIC_REPRESENTATION_ITEM()RATIONAL_B_SPLINE_CURVE((\(try weights.map(fmt).joined(separator: ","))))REPRESENTATION_ITEM(''))")
        }
        return w.add("B_SPLINE_CURVE_WITH_KNOTS('',\(n.degree),(\(controls)),.UNSPECIFIED.,\(closed),.F.,(\(mult)),(\(values)),.UNSPECIFIED.)")
    }

    internal func surface(_ s: XTNode) throws -> SurfaceInfo {
        if let cached = surf[s.index] { return cached }
        let info: SurfaceInfo
        switch s.type {
        case 50:
            guard let p = vec(s, "pvec"), let n = vec(s, "normal"), let x = vec(s, "x_axis") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "plane id \(int(s, "node_id")) has incomplete frame") }
            let ev = try Plane(pvec: p, normal: n, xAxis: x)
            info = SurfaceInfo(stepID: w.add("PLANE('',#\(try w.axis2(ev.p, ev.n, ev.x)))"), match: true, ev: ev)
        case 51:
            guard let p = vec(s, "pvec"), let a = vec(s, "axis"), let x = vec(s, "x_axis") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "cylinder id \(int(s, "node_id")) has incomplete frame") }
            let ev = try Cylinder(pvec: p, axis: a, radius: dbl(s, "radius"), xAxis: x)
            info = SurfaceInfo(stepID: w.add("CYLINDRICAL_SURFACE('',#\(try w.axis2(ev.p, ev.a, ev.x)),\(try fmm(ev.r)))"), match: true, ev: ev)
        case 52:
            guard let p = vec(s, "pvec"), let a = vec(s, "axis"), let x = vec(s, "x_axis") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "cone id \(int(s, "node_id")) has incomplete frame") }
            let ev = try Cone(pvec: p, axis: a, radius: dbl(s, "radius"), sinA: dbl(s, "sin_half_angle"), cosA: dbl(s, "cos_half_angle"), xAxis: x)
            let angle = atan2(ev.sinA, ev.cosA), placement = try w.axis2(ev.p, ev.a, ev.x)
            info = SurfaceInfo(stepID: w.add("CONICAL_SURFACE('',#\(placement),\(try fmm(ev.r)),\(try fmt(angle)))"), match: true, ev: ev)
        case 53:
            guard let c = vec(s, "centre"), let a = vec(s, "axis"), let x = vec(s, "x_axis") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "sphere id \(int(s, "node_id")) has incomplete frame") }
            let ev = try Sphere(centre: c, radius: dbl(s, "radius"), axis: a, xAxis: x)
            info = SurfaceInfo(stepID: w.add("SPHERICAL_SURFACE('',#\(try w.axis2(ev.c, ev.a, ev.x)),\(try fmm(ev.r)))"), match: true, ev: ev)
        case 54:
            guard let c = vec(s, "centre"), let a = vec(s, "axis"), let x = vec(s, "x_axis") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "torus id \(int(s, "node_id")) has incomplete frame") }
            let ev = try Torus(centre: c, axis: a, major: dbl(s, "major_radius"), minor: dbl(s, "minor_radius"), xAxis: x)
            let major = abs(ev.major), minor = abs(ev.minor)
            let placement = try w.axis2(ev.c, ev.a, ev.x)
            if major > minor { info = SurfaceInfo(stepID: w.add("TOROIDAL_SURFACE('',#\(placement),\(try fmm(major)),\(try fmm(minor)))"), match: true, ev: ev) }
            else if major > 0 { info = SurfaceInfo(stepID: w.add("DEGENERATE_TOROIDAL_SURFACE('',#\(placement),\(try fmm(major)),\(try fmm(minor)),.T.)"), match: true, ev: ev) }
            else { warn("lemon_torus", "lemon_torus: inner self-intersecting torus mapped to DEGENERATE_TOROIDAL_SURFACE"); info = SurfaceInfo(stepID: w.add("DEGENERATE_TOROIDAL_SURFACE('',#\(placement),\(try fmm(major)),\(try fmm(minor)),.F.)"), match: true, ev: ev) }
        case 124:
            let ns = try nurbsSurface(s), sid = try emitBSplineSurface(ns)
            info = SurfaceInfo(stepID: sid, match: true, ev: NurbsSurfaceAdapter(s: ns))
        case 67:
            guard let section = deref(s, "section"), let sweepValue = vec(s, "sweep") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "swept surface id \(int(s, "node_id")) without section curve") }
            let sectionID = try curve(section, nil, nil).0, sweep = try unit(sweepValue), directionID = try w.direction(sweep), vectorID = w.add("VECTOR('',#\(directionID),1.)")
            let sid = w.add("SURFACE_OF_LINEAR_EXTRUSION('',#\(sectionID),#\(vectorID))")
            let evaluator = try curveParamEvaluator(section)
            let ev: Surface? = evaluator.flatMap { item in
                try? SweptSurface(section: { t in (try? item.0(t).0) ?? [0, 0, 0] }, t0: item.1, t1: item.2, sweep: sweep)
            }
            info = SurfaceInfo(stepID: sid, match: true, ev: ev)
        case 68:
            guard let profile = deref(s, "profile"), let base = vec(s, "base"), let axisValue = vec(s, "axis") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "spun surface id \(int(s, "node_id")) without profile curve") }
            let profileID = try curve(profile, nil, nil).0, axis = try unit(axisValue), pointID = try w.point(base), directionID = try w.direction(axis)
            let placementID = w.add("AXIS1_PLACEMENT('',#\(pointID),#\(directionID))"), sid = w.add("SURFACE_OF_REVOLUTION('',#\(profileID),#\(placementID))")
            let evaluator = try curveParamEvaluator(profile)
            let ev: Surface? = evaluator.flatMap { item in
                try? SpunSurface(profile: { t in (try? item.0(t).0) ?? [0, 0, 0] }, t0: item.1, t1: item.2, base: base, axis: axis)
            }
            info = SurfaceInfo(stepID: sid, match: true, ev: ev)
        case 60:
            guard let under = deref(s, "surface") else { throw SLDPRTConvertError(code: "unsupported_surface", message: "offset surface id \(int(s, "node_id")) without underlying surface") }
            let basis = try surface(under), offset = dbl(s, "offset") * (str(under, "sense", "+") == "+" ? 1 : -1)
            let stepOffset = offset * (basis.match ? 1 : -1)
            let sid = w.add("OFFSET_SURFACE('',#\(basis.stepID),\(try fmm(stepOffset)),.F.)")
            let ev: Surface? = try basis.ev.map { try OffsetEval(base: $0, offset: offset) }
            info = SurfaceInfo(stepID: sid, match: basis.match, ev: ev)
        case 56:
            let ns = try blendSurface(s), sid = try emitBSplineSurface(ns)
            warn("rolling_ball_blend", "rolling_ball_blend: exact rolling-ball blend surfaces approximated by interpolating rational B-spline surfaces (exact circular cross-sections)")
            info = SurfaceInfo(stepID: sid, match: true, ev: NurbsSurfaceAdapter(s: ns), approx: true)
        case 59:
            throw SLDPRTConvertError(code: "unsupported_surface", message: "blend boundary surface id \(int(s, "node_id")) used as a face surface")
        case 120:
            throw SLDPRTConvertError(code: "unsupported_surface", message: "foreign (PE) surface id \(int(s, "node_id")) cannot be represented")
        case 201:
            throw SLDPRTConvertError(code: "unsupported_surface", message: "mesh (facet) surface id \(int(s, "node_id")) is not a B-rep surface")
        default:
            throw SLDPRTConvertError(code: "unsupported_surface", message: "surface node type \(s.name) (id \(int(s, "node_id"))) is not supported")
        }
        surf[s.index] = info
        return info
    }
}

