//
//  STEPParser.swift
//  Views
//
//  Parses ISO 10303-21 text into a STEPModel.
//

import Foundation

enum STEPParserError: Error, CustomStringConvertible {
    case notASTEPFile
    case expected(String)
    case unexpectedToken(STEPToken)

    var description: String {
        switch self {
        case .notASTEPFile: "Not a STEP file (no ISO-10303-21 header)."
        case .expected(let s): "Expected: \(s)"
        case .unexpectedToken(let t): "Unexpected token: \(t)"
        }
    }
}

struct STEPParser {

    /// Parse STEP file text. Throws if it is not a recognizable STEP file.
    static func parse(text: String) throws -> STEPModel {
        let uppercased = text.uppercased()
        guard uppercased.contains("ISO-10303-21") else {
            throw STEPParserError.notASTEPFile
        }

        // Locate the DATA section, which is what we care about.
        guard let dataRange = uppercased.range(of: "DATA;") else {
            throw STEPParserError.expected("DATA; section")
        }
        let tail = String(text[dataRange.upperBound...])
        // Cut off at ENDSEC.
        let endSearch = tail.uppercased()
        let endIdx = endSearch.range(of: "ENDSEC;")?.lowerBound ?? endSearch.endIndex
        let dataText = String(tail[..<endIdx])

        let tokens = try STEPTokenizer.tokenize(dataText)

        var model = STEPModel()
        // Best-effort unit extraction from the full header.
        if let mm = uppercased.range(of: "MILLIMETRE") ?? uppercased.range(of: "MILLIMETER") {
            model.lengthUnit = "millimeter"
            _ = mm
        } else if uppercased.contains("METRE") || uppercased.contains("METER") {
            model.lengthUnit = "meter"
        } else if uppercased.contains("INCH") {
            model.lengthUnit = "inch"
        }

        var i = 0
        while i < tokens.count {
            // Entity record: #id = NAME ( args ) ;
            guard case .reference(let refID) = tokens[i] else {
                i += 1
                continue
            }
            i += 1
            guard i < tokens.count, case .equals = tokens[i] else {
                continue
            }
            i += 1
            guard i < tokens.count, case .name(let typeName) = tokens[i] else {
                continue
            }
            i += 1

            var args: [STEPValue] = []
            if i < tokens.count, case .lparen = tokens[i] {
                (args, i) = try parseArgumentList(tokens, start: i)
            }
            if i < tokens.count, case .semicolon = tokens[i] {
                i += 1
            }

            model.add(STEPEntity(id: refID, type: typeName, arguments: args))
        }

        return model
    }

    /// Parses a parenthesized argument list starting at a `lparen` token.
    /// Returns the parsed values and the index just past the closing `rparen`.
    private static func parseArgumentList(_ tokens: [STEPToken], start: Int) throws -> ([STEPValue], Int) {
        var i = start + 1 // skip (
        var values: [STEPValue] = []
        while i < tokens.count {
            switch tokens[i] {
            case .rparen:
                i += 1
                return (values, i)
            case .lparen:
                let (sub, j) = try parseArgumentList(tokens, start: i)
                values.append(.list(sub))
                i = j
            case .number(let d):
                // Integers in STEP are written without a decimal point.
                if d.rounded() == d, let asInt = Int(exactly: d) {
                    values.append(.integer(asInt))
                } else {
                    values.append(.number(d))
                }
                i += 1
            case .string(let s): values.append(.string(s)); i += 1
            case .reference(let r): values.append(.reference(r)); i += 1
            case .enumeration(let e): values.append(.enumeration(e)); i += 1
            case .undefined: values.append(.undefined); i += 1
            case .name(let n):
                // Rare: a bare name inside args; treat as enum-ish.
                values.append(.enumeration(n.uppercased())); i += 1
            default:
                throw STEPParserError.unexpectedToken(tokens[i])
            }
        }
        throw STEPParserError.expected("closing )")
    }
}
