//
//  SLDPRTXTSchema.swift
//  3D-Views
//
//  Swift port of the Parasolid XT base schema (SCH_13006) node layouts.
//
//  Ported from `sldprt2step` (https://github.com/BlinkingSun/sldprt2step),
//  Apache License 2.0. Upstream of `sldprt2step` is `open-sld-to-step`
//  (Apache-2.0, clean-room implementation).
//
//  Field kinds (XT Format Reference 2.1.4): u byte, c char, l logical, n short,
//  w unicode short, d int, f double, i interval (2f), v vector (3f), b box (6f),
//  h hvec (only the 3f position is written), p pointer index, t tag (int).
//  A field with n == VAR is the variable-length tail whose element count
//  precedes the node index in the stream.
//
//  Fields added to the schema after V13 (mesh/polyline/lattice chains, the BODY
//  owner class change, REGION.owner, INTERSECTION.intersection_data,
//  TRANSFORM.precision, LIMIT.term_use, ...) are deliberately NOT listed: files
//  carry them as embedded 'I'/'A' edits relative to this base (spec 2.1.2).
//

/// XT 字段。对应 Python 的 `Field` NamedTuple（name, kind, n=1, ptr_class=0）。
struct XTField: Sendable {
    let name: String
    let kind: Character
    let n: Int
    let ptrClass: Int

    init(_ name: String, _ kind: Character, _ n: Int = 1, _ ptrClass: Int = 0) {
        self.name = name
        self.kind = kind
        self.n = n
        self.ptrClass = ptrClass
    }
}

enum XTSchema: Sendable {

    /// Python: `VAR = -1`
    static let VAR: Int = -1

    /// Python: `NODE_NAMES: Dict[int, str]`
    static let nodeNames: [Int: String] = [
        10: "ASSEMBLY", 11: "INSTANCE", 12: "BODY", 13: "SHELL", 14: "FACE", 15: "LOOP",
        16: "EDGE", 17: "HALFEDGE", 18: "VERTEX", 19: "REGION", 29: "POINT", 30: "LINE",
        31: "CIRCLE", 32: "ELLIPSE", 38: "INTERSECTION", 40: "CHART", 41: "LIMIT",
        45: "BSPLINE_VERTICES", 50: "PLANE", 51: "CYLINDER", 52: "CONE", 53: "SPHERE",
        54: "TORUS", 56: "BLENDED_EDGE", 59: "BLEND_BOUND", 60: "OFFSET_SURF", 67: "SWEPT_SURF",
        68: "SPUN_SURF", 70: "LIST", 74: "POINTER_LIS_BLOCK", 79: "ATT_DEF_ID", 80: "ATTRIB_DEF",
        81: "ATTRIBUTE", 82: "INT_VALUES", 83: "REAL_VALUES", 84: "CHAR_VALUES", 85: "POINT_VALUES",
        86: "VECTOR_VALUES", 87: "AXIS_VALUES", 88: "TAG_VALUES", 89: "DIRECTION_VALUES",
        90: "FEATURE", 91: "MEMBER_OF_FEATURE", 98: "UNICODE_VALUES", 99: "FIELD_NAMES",
        100: "TRANSFORM", 101: "WORLD", 102: "KEY", 120: "PE_SURF", 121: "INT_PE_DATA",
        122: "EXT_PE_DATA", 124: "B_SURFACE", 125: "SURFACE_DATA", 126: "NURBS_SURF",
        127: "KNOT_MULT", 128: "KNOT_SET", 130: "PE_CURVE", 133: "TRIMMED_CURVE", 134: "B_CURVE",
        135: "CURVE_DATA", 136: "NURBS_CURVE", 137: "SP_CURVE", 141: "GEOMETRIC_OWNER",
        163: "HELIX_SU_FORM", 176: "PART_XMT_BLOCK", 184: "HELIX_CU_FORM", 185: "POLYLINE_DATA",
        189: "PSM_MESH", 190: "INTEGER_TOOTH", 191: "INTEGER_COMB", 192: "VECTOR_TOOTH",
        193: "VECTOR_COMB", 200: "POLYLINE", 201: "MESH", 204: "INTERSECTION_DATA",
        205: "OFFSET_VALUES", 206: "MESH_OFFSET_DATA", 207: "SCHEMA_CHAR_VALUES",
        208: "NEW_NODE_MAP", 209: "MOD_NODE_MAP", 210: "NEW_FIELD_MAP", 211: "SCHEMA_DATA",
        212: "OLD_NODE_MAP", 213: "OLD_FIELD_MAP", 220: "REAL_TOOTH", 221: "REAL_COMB",
        222: "LATTICE", 223: "LATTICE_DATA_IRREGULAR", 224: "GRAPH_COMPACT",
        229: "TRANSFORM_PRECISION",
    ]

    /// Layouts of the base schema (SCH_13006). Types absent from this dict are
    /// "not in the base schema": the file then carries their full definition.
    ///
    /// Python: `BASE: Dict[int, List[Field]]`
    static let base: [Int: [XTField]] = [
        10: [XTField("highest_node_id", "d"), XTField("attributes_features", "p"), XTField("attribute_chains", "p"),
             XTField("list", "p"), XTField("surface", "p"), XTField("curve", "p"), XTField("point", "p"), XTField("key", "p"),
             XTField("res_size", "f"), XTField("res_linear", "f"), XTField("ref_instance", "p"), XTField("next", "p"),
             XTField("previous", "p"), XTField("state", "u"), XTField("owner", "p"), XTField("type", "u"),
             XTField("sub_instance", "p")],
        11: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("type", "u"), XTField("part", "p"),
             XTField("transform", "p"), XTField("assembly", "p"), XTField("next_in_part", "p"), XTField("prev_in_part", "p"),
             XTField("next_of_part", "p"), XTField("prev_of_part", "p")],
        12: [XTField("highest_node_id", "d"), XTField("attributes_features", "p"), XTField("attribute_chains", "p"),
             XTField("surface", "p"), XTField("curve", "p"), XTField("point", "p"), XTField("key", "p"), XTField("res_size", "f"),
             XTField("res_linear", "f"), XTField("ref_instance", "p"), XTField("next", "p"), XTField("previous", "p"),
             XTField("state", "u"), XTField("owner", "p"), XTField("body_type", "u"), XTField("nom_geom_state", "u"),
             XTField("shell", "p"), XTField("boundary_surface", "p"), XTField("boundary_curve", "p"),
             XTField("boundary_point", "p"), XTField("region", "p"), XTField("edge", "p"), XTField("vertex", "p")],
        13: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("body", "p"), XTField("next", "p"),
             XTField("face", "p"), XTField("edge", "p"), XTField("vertex", "p"), XTField("region", "p"), XTField("front_face", "p")],
        14: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("tolerance", "f"), XTField("next", "p"),
             XTField("previous", "p"), XTField("loop", "p"), XTField("shell", "p"), XTField("surface", "p"), XTField("sense", "c"),
             XTField("next_on_surface", "p"), XTField("previous_on_surface", "p"), XTField("next_front", "p"),
             XTField("previous_front", "p"), XTField("front_shell", "p")],
        15: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("halfedge", "p"), XTField("face", "p"),
             XTField("next", "p")],
        16: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("tolerance", "f"), XTField("halfedge", "p"),
             XTField("previous", "p"), XTField("next", "p"), XTField("curve", "p"), XTField("next_on_curve", "p"),
             XTField("previous_on_curve", "p"), XTField("owner", "p")],
        17: [XTField("attributes_features", "p"), XTField("loop", "p"), XTField("forward", "p"), XTField("backward", "p"),
             XTField("vertex", "p"), XTField("other", "p"), XTField("edge", "p"), XTField("curve", "p"), XTField("next_at_vx", "p"),
             XTField("sense", "c")],
        18: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("halfedge", "p"), XTField("previous", "p"),
             XTField("next", "p"), XTField("point", "p"), XTField("tolerance", "f"), XTField("owner", "p")],
        19: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("body", "p"), XTField("next", "p"),
             XTField("previous", "p"), XTField("shell", "p"), XTField("type", "c")],
        29: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("owner", "p"), XTField("next", "p"),
             XTField("previous", "p"), XTField("pvec", "v")],
        30: XTSchema.common() + [XTField("pvec", "v"), XTField("direction", "v")],
        31: XTSchema.common() + [XTField("centre", "v"), XTField("normal", "v"), XTField("x_axis", "v"), XTField("radius", "f")],
        32: XTSchema.common() + [XTField("centre", "v"), XTField("normal", "v"), XTField("x_axis", "v"),
                                 XTField("major_radius", "f"), XTField("minor_radius", "f")],
        38: XTSchema.common() + [XTField("surface", "p", 2), XTField("chart", "p"), XTField("start", "p"), XTField("end", "p")],
        40: [XTField("base_parameter", "f"), XTField("base_scale", "f"), XTField("chart_count", "d"),
             XTField("chordal_error", "f"), XTField("angular_error", "f"), XTField("parameter_error", "f", 2),
             XTField("hvec", "h", XTSchema.VAR)],
        41: [XTField("type", "c"), XTField("hvec", "h", XTSchema.VAR)],
        45: [XTField("vertices", "f", XTSchema.VAR)],
        50: XTSchema.common() + [XTField("pvec", "v"), XTField("normal", "v"), XTField("x_axis", "v")],
        51: XTSchema.common() + [XTField("pvec", "v"), XTField("axis", "v"), XTField("radius", "f"), XTField("x_axis", "v")],
        52: XTSchema.common() + [XTField("pvec", "v"), XTField("axis", "v"), XTField("radius", "f"), XTField("sin_half_angle", "f"),
                                 XTField("cos_half_angle", "f"), XTField("x_axis", "v")],
        53: XTSchema.common() + [XTField("centre", "v"), XTField("radius", "f"), XTField("axis", "v"), XTField("x_axis", "v")],
        54: XTSchema.common() + [XTField("centre", "v"), XTField("axis", "v"), XTField("major_radius", "f"),
                                 XTField("minor_radius", "f"), XTField("x_axis", "v")],
        56: XTSchema.common() + [XTField("blend_type", "c"), XTField("surface", "p", 2), XTField("spine", "p"),
                                 XTField("range", "f", 2), XTField("thumb_weight", "f", 2), XTField("boundary", "p", 2),
                                 XTField("start", "p"), XTField("end", "p")],
        59: XTSchema.common() + [XTField("boundary", "n"), XTField("blend", "p")],
        60: XTSchema.common() + [XTField("check", "c"), XTField("true_offset", "l"), XTField("surface", "p"),
                                 XTField("offset", "f"), XTField("scale", "f")],
        67: XTSchema.common() + [XTField("section", "p"), XTField("sweep", "v"), XTField("scale", "f")],
        68: XTSchema.common() + [XTField("profile", "p"), XTField("base", "v"), XTField("axis", "v"), XTField("start", "v"),
                                 XTField("end", "v"), XTField("start_param", "f"), XTField("end_param", "f"),
                                 XTField("x_axis", "v"), XTField("scale", "f")],
        70: [XTField("node_id", "d"), XTField("owner", "p"), XTField("next", "p"), XTField("previous", "p"), XTField("list_type", "u"),
             XTField("list_length", "d"), XTField("block_length", "d"), XTField("size_of_entry", "d"), XTField("list_block", "p")],
        74: [XTField("n_entries", "d"), XTField("next_block", "p"), XTField("entries", "p", XTSchema.VAR)],
        79: [XTField("string", "c", XTSchema.VAR)],
        80: [XTField("next", "p"), XTField("identifier", "p"), XTField("type_id", "d"), XTField("actions", "u", 8),
             XTField("field_names", "p"), XTField("legal_owners", "l", 14), XTField("fields", "u", XTSchema.VAR)],
        81: [XTField("node_id", "d"), XTField("definition", "p"), XTField("owner", "p"), XTField("next", "p"), XTField("previous", "p"),
             XTField("next_of_type", "p"), XTField("previous_of_type", "p"), XTField("fields", "p", XTSchema.VAR)],
        82: [XTField("values", "d", XTSchema.VAR)],
        83: [XTField("values", "f", XTSchema.VAR)],
        84: [XTField("values", "c", XTSchema.VAR)],
        85: [XTField("values", "v", XTSchema.VAR)],
        86: [XTField("values", "v", XTSchema.VAR)],
        87: [XTField("values", "v", XTSchema.VAR)],
        88: [XTField("values", "t", XTSchema.VAR)],
        89: [XTField("values", "v", XTSchema.VAR)],
        90: [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("owner", "p"), XTField("next", "p"),
             XTField("previous", "p"), XTField("type", "u"), XTField("first_member", "p")],
        91: [XTField("dummy_node_id", "d"), XTField("owning_feature", "p"), XTField("owner", "p"), XTField("next", "p"),
             XTField("previous", "p"), XTField("next_member", "p"), XTField("previous_member", "p")],
        98: [XTField("values", "w", XTSchema.VAR)],
        99: [XTField("names", "p", XTSchema.VAR)],
        100: [XTField("node_id", "d"), XTField("owner", "p"), XTField("next", "p"), XTField("previous", "p"),
               XTField("rotation_matrix", "f", 9), XTField("translation_vector", "v"), XTField("scale", "f"),
               XTField("flag", "d"), XTField("perspective_vector", "v")],
        101: [XTField("assembly", "p"), XTField("attribute", "p"), XTField("body", "p"), XTField("transform", "p"),
               XTField("surface", "p"), XTField("curve", "p"), XTField("point", "p"), XTField("alive", "l"), XTField("attrib_def", "p"),
               XTField("highest_id", "d"), XTField("current_id", "d")],
        102: [XTField("string", "c", XTSchema.VAR)],
        120: XTSchema.common() + [XTField("type", "c"), XTField("data", "p"), XTField("tf", "p"), XTField("internal_geom", "p", XTSchema.VAR)],
        121: [XTField("geom_type", "d"), XTField("real_array", "p"), XTField("int_array", "p")],
        122: [XTField("key", "p"), XTField("real_array", "p"), XTField("int_array", "p")],
        124: XTSchema.common() + [XTField("nurbs", "p"), XTField("data", "p")],
        125: [XTField("original_uint", "i"), XTField("original_vint", "i"), XTField("extended_uint", "i"),
              XTField("extended_vint", "i"), XTField("self_int", "u"), XTField("original_u_start", "c"),
              XTField("original_u_end", "c"), XTField("original_v_start", "c"), XTField("original_v_end", "c"),
              XTField("extended_u_start", "c"), XTField("extended_u_end", "c"), XTField("extended_v_start", "c"),
              XTField("extended_v_end", "c"), XTField("analytic_form_type", "c"), XTField("swept_form_type", "c"),
              XTField("spun_form_type", "c"), XTField("blend_form_type", "c"), XTField("analytic_form", "p"),
              XTField("swept_form", "p"), XTField("spun_form", "p"), XTField("blend_form", "p")],
        126: [XTField("u_periodic", "l"), XTField("v_periodic", "l"), XTField("u_degree", "n"), XTField("v_degree", "n"),
              XTField("n_u_vertices", "d"), XTField("n_v_vertices", "d"), XTField("u_knot_type", "u"), XTField("v_knot_type", "u"),
              XTField("n_u_knots", "d"), XTField("n_v_knots", "d"), XTField("rational", "l"), XTField("u_closed", "l"),
              XTField("v_closed", "l"), XTField("surface_form", "u"), XTField("vertex_dim", "n"),
              XTField("bspline_vertices", "p"), XTField("u_knot_mult", "p"), XTField("v_knot_mult", "p"),
              XTField("u_knots", "p"), XTField("v_knots", "p")],
        127: [XTField("mult", "n", XTSchema.VAR)],
        128: [XTField("knots", "f", XTSchema.VAR)],
        130: XTSchema.common() + [XTField("type", "c"), XTField("data", "p"), XTField("tf", "p"), XTField("internal_geom", "p", XTSchema.VAR)],
        133: XTSchema.common() + [XTField("basis_curve", "p"), XTField("point_1", "v"), XTField("point_2", "v"),
                                  XTField("parm_1", "f"), XTField("parm_2", "f")],
        134: XTSchema.common() + [XTField("nurbs", "p"), XTField("data", "p")],
        135: [XTField("self_int", "u"), XTField("analytic_form", "p")],
        136: [XTField("degree", "n"), XTField("n_vertices", "d"), XTField("vertex_dim", "n"), XTField("n_knots", "d"),
              XTField("knot_type", "u"), XTField("periodic", "l"), XTField("closed", "l"), XTField("rational", "l"),
              XTField("curve_form", "u"), XTField("bspline_vertices", "p"), XTField("knot_mult", "p"), XTField("knots", "p")],
        137: XTSchema.common() + [XTField("surface", "p"), XTField("b_curve", "p"), XTField("original", "p"),
                                  XTField("tolerance_to_original", "f")],
        141: [XTField("owner", "p"), XTField("next", "p"), XTField("previous", "p"), XTField("shared_geometry", "p")],
        163: [XTField("axis_pt", "v"), XTField("axis_dir", "v"), XTField("hand", "c"), XTField("turns", "i"), XTField("pitch", "f"),
              XTField("gap", "f"), XTField("tol", "f")],
        184: [XTField("axis_pt", "v"), XTField("axis_dir", "v"), XTField("point", "v"), XTField("hand", "c"), XTField("turns", "i"),
              XTField("pitch", "f"), XTField("tol", "f")],
    ]

    /// Bytes per element for fixed-size kinds (neutral binary, big-endian).
    ///
    /// Python: `KIND_SIZE`
    static let kindSize: [Character: Int] = ["u": 1, "c": 1, "l": 1, "n": 2, "w": 2, "d": 4, "t": 4, "f": 8, "i": 16, "v": 24,
                                             "b": 48, "h": 24]

    /// Python: `NULL_INT = -32764`
    static let nullInt: Int = -32764

    /// Python: `NULL_DOUBLE = -3.14158e13`
    static let nullDouble: Double = -3.14158e13

    /// Python: `_common() -> List[Field]`
    static func common() -> [XTField] {
        return [XTField("node_id", "d"), XTField("attributes_features", "p"), XTField("owner", "p"),
                XTField("next", "p"), XTField("previous", "p"), XTField("geometric_owner", "p"), XTField("sense", "c")]
    }

    /// Python: `is_variable(fields) -> bool`
    static func isVariable(_ fields: [XTField]) -> Bool {
        return !fields.isEmpty && fields[fields.count - 1].n == XTSchema.VAR
    }
}
