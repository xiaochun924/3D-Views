//
//  STEPModel.swift
//  3D-Views
//
//  In-memory representation of the parsed STEP DATA section.
//

import Foundation

/// A generic argument value inside an entity record.
enum STEPValue: Equatable, CustomStringConvertible {
    case number(Double)
    case integer(Int)
    case string(String)
    case reference(Int)
    case enumeration(String)
    case undefined
    case list([STEPValue])

    var description: String {
        switch self {
        case .number(let d): return d.description
        case .integer(let i): return i.description
        case .string(let s): return "'\(s)'"
        case .reference(let i): return "#\(i)"
        case .enumeration(let e): return ".\(e)."
        case .undefined: return "$"
        case .list(let l): return "(\(l.map(\.description).joined(separator: ",")))"
        }
    }
}

/// One parsed entity record, e.g. `#123=CARTESIAN_POINT('',(1.,2.,3.));`
struct STEPEntity: Equatable {
    let id: Int
    let type: String
    let arguments: [STEPValue]
}

/// The whole parsed STEP document.
struct STEPModel: Equatable {
    /// Map from entity id to entity.
    private(set) var entities: [Int: STEPEntity] = [:]
    /// Ordered list of entity ids as they appeared in the file.
    private(set) var order: [Int] = []
    /// Units found in the file (e.g. millimeter, inch).
    var lengthUnit: String = "millimeter"
    /// File description from header.
    var fileDescription: [String] = []

    subscript(_ id: Int?) -> STEPEntity? {
        guard let id else { return nil }
        return entities[id]
    }

    mutating func add(_ entity: STEPEntity) {
        entities[entity.id] = entity
        order.append(entity.id)
    }

    /// All entities of a given type (e.g. "CARTESIAN_POINT").
    func entities(ofType type: String) -> [STEPEntity] {
        order.compactMap { entities[$0] }.filter { $0.type == type }
    }
}
