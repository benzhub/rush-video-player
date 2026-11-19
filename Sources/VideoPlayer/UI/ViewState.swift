import SwiftUI

/// 新版 SDK 的 `@State` 是 macro，需要 Xcode 內附的 SwiftUIMacros plugin。
/// 直接使用底層的 property wrapper 型別，只有 Command Line Tools 時也能建置。
typealias ViewState = SwiftUI.State
