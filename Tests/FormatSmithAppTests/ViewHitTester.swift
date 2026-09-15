import AppKit
import FormatSmithCore
import SwiftUI
import XCTest

/// 把一个 SwiftUI 视图放进真实窗口，然后派发真实的鼠标事件，观察动作有没有被执行。
///
/// 为什么需要这套东西：SwiftUI 没有公开的命中测试 API，而 `NSView.hitTest` 会把
/// 装饰性背景也算成命中，分不清「背景画在那里」和「按钮能接到点击」。
/// 直接发事件是唯一能问出「这一下点得到底算不算数」的办法。
///
/// 顺带一提：整个过程不需要界面获得焦点，也不依赖屏幕是否解锁，可以在 CI 上跑。
@MainActor
final class ViewHitTester {

    /// 记录动作是否被触发。
    final class Recorder: ObservableObject {
        @Published private(set) var hits = 0
        func record() { hits += 1 }
    }

    let recorder = Recorder()
    private let container: NSView
    private let window: NSWindow

    /// - Parameter build: 用传进来的 recorder 接到视图的动作上；
    ///   动作必须真的调用 `recorder.record()`，否则这个测试永远只会看到「没反应」。
    init<V: View>(size: CGSize, @ViewBuilder _ build: (Recorder) -> V) {
        let hosting = NSHostingView(rootView: build(recorder))
        hosting.frame = CGRect(origin: .zero, size: size)

        container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(hosting)

        window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    deinit {
        // deinit 不是主 actor，窗口在这里只是被释放，不做界面操作。
    }

    func tearDown() {
        window.orderOut(nil)
    }

    /// 在给定位置点一下，返回动作是否被触发。
    @discardableResult
    func click(at point: CGPoint) -> Bool {
        let before = recorder.hits
        let windowNumber = window.windowNumber

        func event(_ type: NSEvent.EventType, _ timestamp: TimeInterval, _ number: Int) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let down = event(.leftMouseDown, now, 0) { window.sendEvent(down) }
        if let up = event(.leftMouseUp, now + 0.05, 1) { window.sendEvent(up) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))

        return recorder.hits > before
    }

    /// 沿水平方向逐点试探，返回左右两侧「点得动」的边界（相对视图左边缘）。
    func horizontalHitRange(y: CGFloat, width: CGFloat) -> ClosedRange<CGFloat>? {
        var left: CGFloat?
        var right: CGFloat?

        var x: CGFloat = 0
        while x <= width {
            if click(at: CGPoint(x: x, y: y)) {
                if left == nil { left = x }
                right = x
            }
            x += 2
        }

        guard let left, let right else { return nil }
        return left...right
    }
}
