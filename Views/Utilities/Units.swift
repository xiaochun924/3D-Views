//
//  Units.swift
//  Views
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

    /// Formats an area given in square millimetres.
    ///
    /// The conversion factor is squared, not reused as-is: the value is a product of two
    /// lengths, so it scales with the square of the unit change. Reporting a 100 mm² face
    /// as "10.00 cm²" instead of "1.00 cm²" is exactly the error that would come from
    /// using the linear factor.
    func formatArea(_ mmSquared: Float) -> String {
        String(format: "%.2f %@²", mmSquared * Float(fromMillimeter * fromMillimeter), rawValue)
    }

    /// Formats a volume given in cubic millimetres, with the factor cubed for the same
    /// reason `formatArea` squares it.
    func formatVolume(_ mmCubed: Float) -> String {
        let factor = fromMillimeter * fromMillimeter * fromMillimeter
        return String(format: "%.2f %@³", mmCubed * Float(factor), rawValue)
    }
}
