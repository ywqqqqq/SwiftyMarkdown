//
//  SwiftyLineProcessor.swift
//  SwiftyMarkdown
//
//  Created by Simon Fairbairn on 16/12/2019.
//  Copyright © 2019 Voyage Travel Apps. All rights reserved.
//

import Foundation
import os.log

extension OSLog {
    private static var subsystem = "SwiftyLineProcessor"
    static let swiftyLineProcessorPerformance = OSLog(subsystem: subsystem, category: "Swifty Line Processor Performance")
}

public protocol LineStyling {
    var shouldTokeniseLine : Bool { get }
    func styleIfFoundStyleAffectsPreviousLine() -> LineStyling?
}

public struct SwiftyLine : CustomStringConvertible {
    public let line : String
    public let lineStyle : LineStyling
    public let originalNumber: Int?  // 新增：保存原始序号
    public var description: String {
        return self.line
    }
    // 添加新的初始化方法
    public init(line: String, lineStyle: LineStyling, originalNumber: Int? = nil) {
        self.line = line
        self.lineStyle = lineStyle
        self.originalNumber = originalNumber
    }
}

extension SwiftyLine : Equatable {
    public static func == ( _ lhs : SwiftyLine, _ rhs : SwiftyLine ) -> Bool {
        return lhs.line == rhs.line && lhs.originalNumber == rhs.originalNumber
    }
}

public enum Remove {
    case leading
    case trailing
    case both
    case entireLine
    case none
}

public enum ChangeApplication {
    case current
    case previous
    case untilClose
}

public struct FrontMatterRule {
    let openTag : String
    let closeTag : String
    let keyValueSeparator : Character
}

public struct LineRule {
    let token : String
    let removeFrom : Remove
    let type : LineStyling
    let shouldTrim : Bool
    let changeAppliesTo : ChangeApplication
    
    public init(token : String, type : LineStyling, removeFrom : Remove = .leading, shouldTrim : Bool = true, changeAppliesTo : ChangeApplication = .current ) {
        self.token = token
        self.type = type
        self.removeFrom = removeFrom
        self.shouldTrim = shouldTrim
        self.changeAppliesTo = changeAppliesTo
    }
}

extension SwiftyLineProcessor {
    
    private func extractOriginalNumber(from text: String, for element: LineRule) -> Int? {
        guard text.contains(element.token),
              element.token.contains(". ") else {
            return nil
        }
        
        // 提取数字：从token中获取数字部分
        let numberPart = element.token.replacingOccurrences(of: ". ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")
        
        return Int(numberPart)
    }
}

public class SwiftyLineProcessor {
    
    public var processEmptyStrings : LineStyling?
    public internal(set) var frontMatterAttributes : [String : String] = [:]
    
    var closeToken : String? = nil
    let defaultType : LineStyling
    
    let lineRules : [LineRule]
    let frontMatterRules : [FrontMatterRule]
    
    let perfomanceLog = PerformanceLog(with: "SwiftyLineProcessorPerformanceLogging", identifier: "Line Processor", log: OSLog.swiftyLineProcessorPerformance)
        
    public init( rules : [LineRule], defaultRule: LineStyling, frontMatterRules : [FrontMatterRule] = []) {
        self.lineRules = rules
        self.defaultType = defaultRule
        self.frontMatterRules = frontMatterRules
    }
    
    func findLeadingLineElement( _ element : LineRule, in string : String ) -> String {
        var output = string
        if let range = output.index(output.startIndex, offsetBy: element.token.count, limitedBy: output.endIndex), output[output.startIndex..<range] == element.token {
            output.removeSubrange(output.startIndex..<range)
            return output
        }
        return output
    }
    
    func findTrailingLineElement( _ element : LineRule, in string : String ) -> String {
        var output = string
        let token = element.token.trimmingCharacters(in: .whitespaces)
        if let range = output.index(output.endIndex, offsetBy: -(token.count), limitedBy: output.startIndex), output[range..<output.endIndex] == token {
            output.removeSubrange(range..<output.endIndex)
            return output
            
        }
        return output
    }
    
    private func preprocessOrderedLists(_ text: String) -> String {
        // 匹配任意数字开头的列表项并标准化为 "1."
        let patterns = [
            // 普通有序列表: "数字. " -> "1. "
            (pattern: #"^(\d+)(\.\s+)"#, replacement: "1. "),
            // 三个空格缩进: "   数字. " -> "   1. "
            (pattern: #"^(\s{3})(\d+)(\.\s+)"#, replacement: "$11. "),
            // 六个空格缩进: "      数字. " -> "      1. "
            (pattern: #"^(\s{6})(\d+)(\.\s+)"#, replacement: "$11. "),
            // Tab缩进: "\t数字. " -> "\t1. "
            (pattern: #"^(\t)(\d+)(\.\s+)"#, replacement: "$11. "),
            // 双Tab缩进: "\t\t数字. " -> "\t\t1. "
            (pattern: #"^(\t\t)(\d+)(\.\s+)"#, replacement: "$11. ")
        ]
        
        var result = text
        for (pattern, replacement) in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [])
                let range = NSRange(location: 0, length: result.utf16.count)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            } catch {
                print("正则表达式处理错误: \(error)")
            }
        }
        return result
    }
    
    func processLineLevelAttributes( _ text : String ) -> SwiftyLine? {
        if text.isEmpty, let style = processEmptyStrings {
            return SwiftyLine(line: "", lineStyle: style)
        }
        let preprocessedText = preprocessOrderedLists(text)
            
        let previousLines = lineRules.filter({ $0.changeAppliesTo == .previous })

        for element in lineRules {
            guard element.token.count > 0 else {
                continue
            }
            var output : String = (element.shouldTrim) ? preprocessedText.trimmingCharacters(in: .whitespaces) : preprocessedText
            let unprocessed = output
            
            if let hasToken = self.closeToken, unprocessed != hasToken {
                return nil
            }
            
            if !preprocessedText.contains(element.token) {
                continue
            }
            
            let originalNumber = extractOriginalNumber(from: text, for: element)
            
            switch element.removeFrom {
            case .leading:
                output = findLeadingLineElement(element, in: output)
            case .trailing:
                output = findTrailingLineElement(element, in: output)
            case .both:
                output = findLeadingLineElement(element, in: output)
                output = findTrailingLineElement(element, in: output)
            case .entireLine:
                let maybeOutput = output.replacingOccurrences(of: element.token, with: "")
                output = ( maybeOutput.isEmpty ) ? maybeOutput : output
            default:
                break
            }
            // Only if the output has changed in some way
            guard unprocessed != output else {
                continue
            }
            
            if element.changeAppliesTo == .untilClose {
                self.closeToken = (self.closeToken == nil) ? element.token : nil
                return nil
            }
            
            output = (element.shouldTrim) ? output.trimmingCharacters(in: .whitespaces) : output
            return SwiftyLine(line: output, lineStyle: element.type, originalNumber: originalNumber)
            
        }
        
        for element in previousLines {
            let output = (element.shouldTrim) ? text.trimmingCharacters(in: .whitespaces) : text
            let charSet = CharacterSet(charactersIn: element.token )
            if output.unicodeScalars.allSatisfy({ charSet.contains($0) }) {
                return SwiftyLine(line: "", lineStyle: element.type)
            }
        }
        
        return SwiftyLine(line: text.trimmingCharacters(in: .whitespaces), lineStyle: defaultType)
    }
    
    func processFrontMatter( _ strings : [String] ) -> [String] {
        guard let firstString = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return strings
        }
        var rulesToApply : FrontMatterRule? = nil
        for matter in self.frontMatterRules {
            if firstString == matter.openTag {
                rulesToApply = matter
                break
            }
        }
        guard let existentRules = rulesToApply else {
            return strings
        }
        var outputString = strings
        // Remove the first line, which is the front matter opening tag
        let _ = outputString.removeFirst()
        var closeFound = false
        while !closeFound {
            let nextString = outputString.removeFirst()
            if nextString == existentRules.closeTag {
                closeFound = true
                continue
            }
            var keyValue = nextString.components(separatedBy: "\(existentRules.keyValueSeparator)")
            if keyValue.count < 2 {
                continue
            }
            let key = keyValue.removeFirst()
            let value = keyValue.joined()
            self.frontMatterAttributes[key] = value
        }
        while outputString.first?.isEmpty ?? false {
            outputString.removeFirst()
        }
        return outputString
    }
    
    public func process( _ string : String ) -> [SwiftyLine] {
        var foundAttributes : [SwiftyLine] = []
        
        
        self.perfomanceLog.start()
        
        var lines = string.components(separatedBy: CharacterSet.newlines)
        lines = self.processFrontMatter(lines)
        
        self.perfomanceLog.tag(with: "(Front matter completed)")
        

        for  heading in lines {
            
            if processEmptyStrings == nil && heading.isEmpty {
                continue
            }
                        
            guard let input = processLineLevelAttributes(String(heading)) else {
                continue
            }
            
            if let existentPrevious = input.lineStyle.styleIfFoundStyleAffectsPreviousLine(), foundAttributes.count > 0 {
                if let idx = foundAttributes.firstIndex(of: foundAttributes.last!) {
                    let updatedPrevious = foundAttributes.last!
                    foundAttributes[idx] = SwiftyLine(line: updatedPrevious.line, lineStyle: existentPrevious)
                }
                continue
            }
            foundAttributes.append(input)
            
            self.perfomanceLog.tag(with: "(line completed: \(heading)")
        }
        return foundAttributes
    }
    
}


