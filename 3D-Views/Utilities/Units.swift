//
//  Units.swift
//  3D-Views
//
//  Unit handling and formatting.
//

import Foundation

enum DisplayUnit: String, CaseIterable {
    case millimeter = "mm"
    case centimeter = "cm"
    case inch = "in"
    case meter = "m"

    var fromMillimeter: Double {
        switch self {
        case .millimeter: return 1.0
        case .centimeter: return 0.1
        case .inch: return 1.0 / 25.4
        case .meter: return 0.001
        }
    }

    func format(_ mmValue: Float) -> String {
        String(format: "%.2f %@", mmValue * Float(fromMillimeter), rawValue)
    }
}
