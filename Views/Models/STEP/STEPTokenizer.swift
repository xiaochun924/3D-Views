//
//  STEPTokenizer.swift
//  Views
//
//  A tokenizer for ISO 10303-21 (STEP) exchange structures.
//  Produces a flat token stream that the parser consumes.
//

import Foundation

/// A single lexical token in a STEP physical file.
enum STEPToken: Equatable {
    case reference(Int)
    case number(Double)
    case name(String)
    case string(String)
    case enumeration(String)
    case undefined
    case lparen
    case rparen
    case semicolon
    case equals
    case asterisk
}

enum STEPTokenError: Error, CustomStringConvertible {
    case unexpectedCharacter(Character, Int)
    case unterminatedString(Int)

    var description: String {
        switch self {
        case .unexpectedCharacter(let c, let pos):
            return "Unexpected character '\(c)' at offset \(pos)"
        case .unterminatedString(let pos):
            return "Unterminated string starting at offset \(pos)"
        }
    }
}

/// Splits a STEP file's DATA section into a token stream.
enum STEPTokenizer {

    static func tokenize(_ text: String) throws -> [STEPToken] {
        var tokens: [STEPToken] = []
        tokens.reserveCapacity(4096)

        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        while i < n {
            let c = Character(scalars[i])

            if c.isWhitespace || c.isNewline {
                i += 1
                continue
            }
            if c == "(" {
                var depth = 1
                i += 1
                while i < n, depth > 0 {
                    let cc = Character(scalars[i])
                    if cc == "(" { depth += 1 }
                    else if cc == ")" { depth -= 1 }
                    i += 1
                }
                continue
            }

            switch c {
            case ";": tokens.append(.semicolon); i += 1
            case "=": tokens.append(.equals); i += 1
            case "(": tokens.append(.lparen); i += 1
            case ")": tokens.append(.rparen); i += 1
            case "*": tokens.append(.asterisk); i += 1
            case "$": tokens.append(.undefined); i += 1
            case "#":
                i += 1
                var num = ""
                while i < n, Character(scalars[i]).isNumber {
                    num.append(Character(scalars[i])); i += 1
                }
                guard let v = Int(num) else {
                    throw STEPTokenError.unexpectedCharacter(c, i)
                }
                tokens.append(.reference(v))
            case "'":
                i += 1
                var str = ""
                while i < n {
                    let cc = Character(scalars[i])
                    if cc == "'" {
                        if i + 1 < n, Character(scalars[i + 1]) == "'" {
                            str.append("'")
                            i += 2
                            continue
                        }
                        i += 1
                        break
                    }
                    str.append(cc)
                    i += 1
                }
                tokens.append(.string(str))
            case ".":
                i += 1
                var name = ""
                while i < n, Character(scalars[i]).isLetter || Character(scalars[i]).isNumber {
                    name.append(Character(scalars[i])); i += 1
                }
                if i < n, Character(scalars[i]) == "." { i += 1 }
                tokens.append(.enumeration(name))
            default:
                if c.isNumber || c == "-" || c == "+" || c == "." {
                    var num = ""
                    while i < n {
                        let cc = Character(scalars[i])
                        if cc.isNumber || cc == "-" || cc == "+" || cc == "." || cc == "e" || cc == "E" {
                            num.append(cc)
                            i += 1
                        } else { break }
                    }
                    if let v = Double(num) {
                        tokens.append(.number(v))
                    }
                } else if c.isLetter || c == "_" {
                    var name = ""
                    while i < n {
                        let cc = Character(scalars[i])
                        if cc.isLetter || cc.isNumber || cc == "_" {
                            name.append(cc); i += 1
                        } else { break }
                    }
                    tokens.append(.name(name))
                } else {
                    throw STEPTokenError.unexpectedCharacter(c, i)
                }
            }
        }

        return tokens
    }
}
