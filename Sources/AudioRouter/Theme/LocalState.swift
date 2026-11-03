import Combine

/// Local view state holder used with `@StateObject`.
/// (The macOS SDK's `@State` is implemented as a macro whose plugin ships only
/// with full Xcode; this keeps the project buildable with Command Line Tools.)
final class LocalState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
