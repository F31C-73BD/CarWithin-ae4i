import Foundation

/// Keep 480 instruments on their original 480-line output. 484/488 instruments
/// (AE6 / AE4 Pro / AE5i Pro) decode at their own height, so echo it back verbatim.
struct Zeeho62MediaSize: Equatable {
    let width: Int
    let height: Int
    static let standard = Self(width: 1024, height: 480)

    static func negotiate(width: Int, height: Int) throws -> Self {
        guard width == 1024 else { throw TailingError.protocolFailure("极核 6.2 寸不支持尺寸：\(width)×\(height)") }
        switch height {
        case 480: return .standard
        // 488 的面板（AE4 Pro / AE5i Pro 等）必须原样回 488；回 480 会差 8 行，仪表对不上就不拉帧。
        case 488: return Self(width: 1024, height: 488)
        case 484: return Self(width: 1024, height: 484)
        default: throw TailingError.protocolFailure("极核 6.2 寸不支持尺寸：\(width)×\(height)")
        }
    }
}
