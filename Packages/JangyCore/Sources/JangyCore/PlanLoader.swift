import Foundation

/// JSON 层错误：把 DecodingError 翻译成人/Agent 可读的字段路径。
public enum PlanLoaderError: Error, Equatable, CustomStringConvertible {
    case decodingFailed(path: String, message: String)

    public var description: String {
        switch self {
        case .decodingFailed(let path, let message): return "\(path): \(message)"
        }
    }
}

extension PlanLoaderError: LocalizedError {
    public var errorDescription: String? { description }
}

public enum PlanLoader {

    public static func load(from url: URL) throws -> EditPlan {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(EditPlan.self, from: data)
        } catch let error as DecodingError {
            let (path, message) = describe(error)
            throw PlanLoaderError.decodingFailed(path: path, message: message)
        }
    }

    static func describe(_ error: DecodingError) -> (path: String, message: String) {
        switch error {
        case .keyNotFound(let key, let context):
            return (pathString(context.codingPath + [key]), "缺少字段 \(key.stringValue)")
        case .typeMismatch(_, let context):
            return (pathString(context.codingPath), "类型不匹配: \(context.debugDescription)")
        case .valueNotFound(_, let context):
            return (pathString(context.codingPath), "值为空: \(context.debugDescription)")
        case .dataCorrupted(let context):
            return (pathString(context.codingPath), "数据损坏: \(context.debugDescription)")
        @unknown default:
            return ("(root)", "未知解码错误")
        }
    }

    static func pathString(_ codingPath: [CodingKey]) -> String {
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return result.isEmpty ? "(root)" : result
    }
}
