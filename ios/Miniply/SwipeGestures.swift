import SwiftUI

/// A sideways pan that leaves vertical scrolling alone. SwiftUI's DragGesture
/// inside a ScrollView blocks scrolling when the finger starts on it, so this
/// sits on the scroll view itself and only starts on a horizontal movement.
private struct HorizontalPan: UIViewRepresentable {
    var rightOnly = false
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) {
        context.coordinator.pan = self
    }
    func makeCoordinator() -> Coordinator { Coordinator(pan: self) }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        private weak var host: UIView?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            host?.removeGestureRecognizer(coordinator.recognizer)
            host = nil
            guard window != nil else { return }
            coordinator.anchor = self
            // The hit view is the SwiftUI host, not this view: attach above it.
            var candidate = superview
            while let view = candidate, !(view is UIScrollView), view.superview?.superview != nil { candidate = view.superview }
            candidate?.addGestureRecognizer(coordinator.recognizer)
            host = candidate
            coordinator.scrollView = candidate as? UIScrollView
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var pan: HorizontalPan
        weak var anchor: UIView?
        weak var scrollView: UIScrollView?
        lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(moved))
            recognizer.delegate = self
            return recognizer
        }()
        init(pan: HorizontalPan) { self.pan = pan }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let anchor, let gesture = gesture as? UIPanGestureRecognizer,
                  anchor.bounds.contains(gesture.location(in: anchor)) else { return false }
            let velocity = gesture.velocity(in: anchor)
            guard abs(velocity.x) > abs(velocity.y) * 1.3 else { return false }
            guard pan.rightOnly else { return true }
            // The screen edge stays with "back".
            let start = gesture.location(in: nil).x - gesture.translation(in: nil).x
            return velocity.x > 0 && start > 24
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other === scrollView?.panGestureRecognizer
        }
        /// Since iOS 26 a swipe anywhere goes back. On a row this swipe wins.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && !(other is UIScreenEdgePanGestureRecognizer) && other !== scrollView?.panGestureRecognizer
        }
        @objc private func moved(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: anchor).x
            switch gesture.state {
            case .began:
                // Stops the list from drifting up and down during the swipe.
                scrollView?.panGestureRecognizer.isEnabled = false
                scrollView?.panGestureRecognizer.isEnabled = true
                pan.changed(translation)
            case .changed: pan.changed(translation)
            case .ended: pan.ended(translation, gesture.velocity(in: anchor).x)
            case .cancelled, .failed: pan.ended(0, 0)
            default: break
            }
        }
    }
}

/// Pulling down from the top of a scroll view, for a full-screen view that has no
/// system gesture to close it. Scrolling up and nested scroll views stay untouched.
struct PullDownPan: UIViewRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) { context.coordinator.pan = self }
    func makeCoordinator() -> Coordinator { Coordinator(pan: self) }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        private weak var host: UIScrollView?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            host?.removeGestureRecognizer(coordinator.recognizer)
            host = nil
            guard window != nil else { return }
            var candidate = superview
            while let view = candidate, !(view is UIScrollView) { candidate = view.superview }
            host = candidate as? UIScrollView
            host?.addGestureRecognizer(coordinator.recognizer)
            coordinator.scrollView = host
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var pan: PullDownPan
        weak var scrollView: UIScrollView?
        lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(moved))
            recognizer.delegate = self
            return recognizer
        }()
        init(pan: PullDownPan) { self.pan = pan }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let scrollView, let gesture = gesture as? UIPanGestureRecognizer else { return false }
            let velocity = gesture.velocity(in: scrollView)
            guard velocity.y > abs(velocity.x) * 1.3,
                  scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1 else { return false }
            // Song text scrolls by itself.
            var view = scrollView.hitTest(gesture.location(in: scrollView), with: nil)
            while let current = view, current !== scrollView {
                if current is UIScrollView { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other === scrollView?.panGestureRecognizer
        }
        @objc private func moved(_ gesture: UIPanGestureRecognizer) {
            let translation = max(0, gesture.translation(in: scrollView?.superview).y)
            switch gesture.state {
            case .began:
                // The page itself must not bounce along.
                scrollView?.panGestureRecognizer.isEnabled = false
                scrollView?.panGestureRecognizer.isEnabled = true
                pan.changed(translation)
            case .changed: pan.changed(translation)
            case .ended: pan.ended(translation, gesture.velocity(in: scrollView?.superview).y)
            case .cancelled, .failed: pan.ended(0, 0)
            default: break
            }
        }
    }
}

/// Swipe a row to the right to add it to the queue, and with `remove` to the left
/// to take it out. Works in plain scroll views, where `swipeActions` does nothing.
struct QueueSwipe: ViewModifier {
    let enabled: Bool
    let perform: () -> Void
    var remove: (() -> Void)? = nil
    /// True from the first sideways movement until shortly after the end, so
    /// lifting the finger does not also tap the row.
    @Binding var isSwiping: Bool
    @State private var offset: CGFloat = 0
    private let threshold: CGFloat = 76

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: offset)
                .background(alignment: .leading) {
                    if offset > 0 {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(offset >= threshold ? Color.black : Color.mint)
                            .frame(width: max(offset, 44), alignment: .center)
                            .frame(maxHeight: .infinity)
                            .background(offset >= threshold ? Color.mint : Color.mint.opacity(0.18))
                            .scaleEffect(offset >= threshold ? 1 : 0.96, anchor: .leading)
                    }
                }
                .background(alignment: .trailing) {
                    if offset < 0 {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: max(-offset, 44), alignment: .center)
                            .frame(maxHeight: .infinity)
                            .background(-offset >= threshold ? Color.red : Color.red.opacity(0.35))
                    }
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: abs(offset) >= threshold) { _, reached in reached }
                .background(HorizontalPan(rightOnly: remove == nil, changed: changed, ended: { _, _ in finish() }))
        } else {
            content
        }
    }

    private func changed(_ translation: CGFloat) {
        isSwiping = true
        let drag = remove == nil ? max(0, translation) : translation
        // Follows the finger, then resists past the point of action.
        let distance = abs(drag)
        let moved = distance <= threshold ? distance : threshold + (distance - threshold) * 0.35
        offset = drag < 0 ? -moved : moved
    }

    private func finish() {
        if offset >= threshold { perform() } else if offset <= -threshold { remove?() }
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { offset = 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            isSwiping = false
        }
    }
}

/// The active song between its neighbours: dragging sideways brings the next or
/// previous one into view as a preview, and only letting go far enough plays it.
struct TrackCarousel<Page: View>: View {
    let previous: Media?
    let current: Media
    let next: Media?
    let onPrevious: () -> Void
    let onNext: () -> Void
    @ViewBuilder let page: (Media) -> Page
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var committing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var threshold: CGFloat { width * 0.35 }

    var body: some View {
        ZStack(alignment: .top) {
            page(current)
                .frame(maxWidth: .infinity)
                .offset(x: offset)
            // Always laid out, so a cover is ready before it comes into view.
            if let previous { neighbour(previous, at: offset - width) }
            if let next { neighbour(next, at: offset + width) }
        }
        .contentShape(Rectangle())
        .background(GeometryReader { geometry in
            Color.clear.preference(key: CarouselWidthKey.self, value: geometry.size.width)
        })
        .onPreferenceChange(CarouselWidthKey.self) { width = $0 }
        .clipped()
        .sensoryFeedback(.selection, trigger: abs(offset) >= max(1, threshold))
        .background(HorizontalPan(changed: changed, ended: ended))
        // The song can also change by itself while the finger is down.
        .onChange(of: current.id) { _, _ in if !committing { offset = 0 } }
        .accessibilityAction(named: String(localized: "Nächster Titel")) { if next != nil { onNext() } }
        .accessibilityAction(named: String(localized: "Vorheriger Titel")) { if previous != nil { onPrevious() } }
    }

    private func neighbour(_ media: Media, at position: CGFloat) -> some View {
        page(media)
            .frame(maxWidth: .infinity)
            .offset(x: position)
            .opacity(offset == 0 ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func changed(_ drag: CGFloat) {
        guard !committing else { return }
        let available = drag < 0 ? next != nil : previous != nil
        offset = available ? drag : drag * 0.2
    }

    private func ended(_ translation: CGFloat, _ velocity: CGFloat) {
        guard !committing else { return }
        // A quick flick counts as well as a long drag.
        let reach = translation + velocity * 0.15
        if reach <= -threshold, next != nil { commit(to: -width, action: onNext) }
        else if reach >= threshold, previous != nil { commit(to: width, action: onPrevious) }
        else { settle() }
    }

    private func settle() {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { offset = 0 }
    }

    private func commit(to target: CGFloat, action: @escaping () -> Void) {
        committing = true
        let finish = {
            action()
            // Same moment as the song change: the neighbour becomes the center
            // page at the place it already has.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { offset = 0 }
            committing = false
        }
        if reduceMotion { finish(); return }
        withAnimation(.spring(duration: 0.28, bounce: 0), completionCriteria: .logicallyComplete) {
            offset = target
        } completion: { finish() }
    }
}

private struct CarouselWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Dims a row while pressed; `plain` buttons give no feedback at all.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Short confirmation above the mini player.
struct PlayerToast: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "text.line.last.and.arrowtriangle.forward")
            .font(.footnote.weight(.semibold))
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
