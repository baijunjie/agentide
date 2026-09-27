import AgentIDEProtocol
import SwiftUI
import UIKit

enum WorkspaceLevel: Codable, Equatable {
    case session
    case browser
    case file(TextFileSelection)
    case changes
    case diff(GitChange)

    var depth: Int {
        switch self {
        case .session: 0
        case .browser, .changes: 1
        case .file, .diff: 2
        }
    }
}

struct WorkspaceNavigationState: Codable, Equatable {
    var level: WorkspaceLevel = .session
    var fullScreenImage: ImageFileSelection?
    private(set) var presentedFile: TextFileSelection?
    private(set) var presentedChange: GitChange?

    mutating func showBrowser() {
        level = .browser
    }

    mutating func showChanges() { level = .changes }

    mutating func prepareDiff(_ change: GitChange) { presentedChange = change }

    mutating func activatePreparedDiff() {
        guard level == .changes, let presentedChange else { return }
        level = .diff(presentedChange)
    }

    mutating func prepareFile(_ selection: TextFileSelection) {
        presentedFile = selection
    }

    mutating func activatePreparedFile() {
        guard level == .browser, let presentedFile else { return }
        level = .file(presentedFile)
    }

    mutating func showImage(_ selection: ImageFileSelection) {
        fullScreenImage = selection
    }

    mutating func goBack() {
        switch level {
        case .session:
            break
        case .browser, .changes:
            level = .session
        case .file:
            level = .browser
        case .diff:
            level = .changes
        }
    }

    mutating func returnToSession() {
        level = .session
        fullScreenImage = nil
        presentedFile = nil
        presentedChange = nil
    }

    mutating func finishFileDismissal() {
        if case .file = level { return }
        presentedFile = nil
        if case .diff = level { return }
        presentedChange = nil
    }

}

struct WorkspaceNavigationContainer<SessionContent: View, BrowserContent: View, FileContent: View, ChangesContent: View, DiffContent: View>: View {
    @Binding var navigation: WorkspaceNavigationState
    @ViewBuilder let sessionContent: (CGFloat) -> SessionContent
    @ViewBuilder let browserContent: () -> BrowserContent
    @ViewBuilder let fileContent: (TextFileSelection) -> FileContent
    @ViewBuilder let changesContent: () -> ChangesContent
    @ViewBuilder let diffContent: (GitChange) -> DiffContent
    @State private var dragTranslation: CGFloat = 0
    @State private var navigationInset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let depth = interactiveDepth(width: width)
            let inactiveInset = inactiveLayerWidth(width)

            ZStack(alignment: .leading) {
                sessionContent(navigationInset)
                    .workspaceLayer(sessionStyle(depth: depth, width: width))
                    .allowsHitTesting(navigation.level == .session)
                    .accessibilityHidden(navigation.level != .session)

                browserContent()
                    .frame(width: width - inactiveInset)
                    .workspaceLayer(browserStyle(depth: depth, width: width, inactiveInset: inactiveInset))
                    .allowsHitTesting(navigation.level == .browser)
                    .accessibilityHidden(navigation.level != .browser)

                changesContent()
                    .frame(width: width - inactiveInset)
                    .workspaceLayer(browserStyle(depth: depth, width: width, inactiveInset: inactiveInset))
                    .allowsHitTesting(navigation.level == .changes)
                    .accessibilityHidden(navigation.level != .changes)

                if let selection = navigation.presentedFile {
                    fileContent(selection)
                        .frame(width: width - inactiveInset)
                        .workspaceLayer(fileStyle(depth: depth, width: width, inactiveInset: inactiveInset))
                        .allowsHitTesting(navigation.level == .file(selection))
                        .accessibilityHidden(navigation.level != .file(selection))
                }
                if let change = navigation.presentedChange {
                    diffContent(change)
                        .frame(width: width - inactiveInset)
                        .workspaceLayer(fileStyle(depth: depth, width: width, inactiveInset: inactiveInset))
                        .allowsHitTesting(navigation.level == .diff(change))
                        .accessibilityHidden(navigation.level != .diff(change))
                }

                retiredLayerReturnArea(width: inactiveInset)
                fileReturnHandle(width: width)
            }
            .frame(width: width, height: geometry.size.height, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                workspaceGesture(width: width),
                // The file layer owns horizontal scrolling. Keep descendant gestures active while excluding this container gesture.
                including: navigation.level.depth == 2 ? .subviews : .all
            )
            .background {
                NavigationClearanceReader(clearance: $navigationInset)
                    .allowsHitTesting(false)
            }
        }
    }

    private func interactiveDepth(width: CGFloat) -> CGFloat {
        let base = CGFloat(navigation.level.depth)
        guard width > 0 else { return base }
        if base == 0, dragTranslation > 0 {
            return min(1, dragTranslation / (width * 0.72))
        }
        if base > 0, dragTranslation < 0 {
            return max(base - 1, base + dragTranslation / (width * 0.72))
        }
        return base
    }

    private func workspaceGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                guard accepts(value, width: width) else { return }
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                guard accepts(value, width: width) else {
                    resetDrag()
                    return
                }
                let projected = value.predictedEndTranslation.width
                let threshold = width * 0.24
                if navigation.level == .session, projected > threshold {
                    withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
                        navigation.showBrowser()
                        dragTranslation = 0
                    }
                } else if navigation.level != .session, projected < -threshold {
                    returnToPreviousLevel()
                } else {
                    resetDrag()
                }
            }
    }

    private func accepts(_ value: DragGesture.Value, width: CGFloat) -> Bool {
        let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.25
        let beginsAwayFromSystemBackEdge = value.startLocation.x > width * 0.68
        switch navigation.level {
        case .session:
            return horizontal && beginsAwayFromSystemBackEdge && value.translation.width > 0
        case .browser, .changes:
            return horizontal && beginsAwayFromSystemBackEdge && value.translation.width < 0
        case .file, .diff:
            return false
        }
    }

    @ViewBuilder private func fileReturnHandle(width: CGFloat) -> some View {
        if navigation.level.depth == 2 {
            Image(systemName: "chevron.left")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
                .contentShape(Rectangle())
                .gesture(fileReturnGesture(width: width))
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(8)
                .zIndex(4)
        }
    }

    private func fileReturnGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard acceptsFileReturn(value) else { return }
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                guard acceptsFileReturn(value) else {
                    resetDrag()
                    return
                }
                let projected = value.predictedEndTranslation.width
                if projected < -(width * 0.18) {
                    returnToPreviousLevel()
                } else {
                    resetDrag()
                }
            }
    }

    private func acceptsFileReturn(_ value: DragGesture.Value) -> Bool {
        value.translation.width < 0 &&
            abs(value.translation.width) > abs(value.translation.height) * 1.25
    }

    @ViewBuilder private func retiredLayerReturnArea(width: CGFloat) -> some View {
        if navigation.level != .session {
            Button {
                returnToPreviousLevel()
            } label: {
                Color.clear
                    .contentShape(Rectangle())
                    .accessibilityLabel("Return to previous workspace level")
            }
            .buttonStyle(.plain)
            .frame(width: width)
            .zIndex(3)
        }
    }

    private func returnToPreviousLevel() {
        let leavesFile = navigation.level.depth == 2
        withAnimation(
            .interactiveSpring(response: 0.36, dampingFraction: 0.86),
            completionCriteria: .logicallyComplete
        ) {
            navigation.goBack()
            dragTranslation = 0
        } completion: {
            if leavesFile { navigation.finishFileDismissal() }
        }
    }

    private func resetDrag() {
        withAnimation(.interactiveSpring(response: 0.36, dampingFraction: 0.86)) {
            dragTranslation = 0
        }
    }

    private func sessionStyle(depth: CGFloat, width: CGFloat) -> WorkspaceLayerStyle {
        let retirement = min(depth, 1)
        let departure = max(depth - 1, 0)
        return WorkspaceLayerStyle(
            offset: -width * (0.08 * retirement + 0.92 * departure),
            scale: 1 - 0.06 * retirement,
            blur: 5 * retirement,
            opacity: 1 - 0.22 * retirement - 0.78 * departure,
            shadow: 0,
            zIndex: 0
        )
    }

    private func browserStyle(depth: CGFloat, width: CGFloat, inactiveInset: CGFloat) -> WorkspaceLayerStyle {
        let arrival = min(max(depth, 0), 1)
        let retirement = max(depth - 1, 0)
        return WorkspaceLayerStyle(
            offset: width * (1 - arrival) + inactiveInset * arrival * (1 - retirement),
            scale: 1 - 0.05 * retirement,
            blur: 5 * retirement,
            opacity: arrival * (1 - 0.22 * retirement),
            shadow: 18 * arrival,
            zIndex: 1
        )
    }

    private func fileStyle(depth: CGFloat, width: CGFloat, inactiveInset: CGFloat) -> WorkspaceLayerStyle {
        let arrival = min(max(depth - 1, 0), 1)
        return WorkspaceLayerStyle(
            offset: width * (1 - arrival) + inactiveInset * arrival,
            scale: 1,
            blur: 0,
            opacity: arrival,
            shadow: 18 * arrival,
            zIndex: 2
        )
    }

    private func inactiveLayerWidth(_ width: CGFloat) -> CGFloat {
        min(width * 0.25, 108)
    }
}

private struct NavigationClearanceReader: UIViewRepresentable {
    @Binding var clearance: CGFloat

    func makeUIView(context: Context) -> NavigationClearanceView {
        NavigationClearanceView()
    }

    func updateUIView(_ view: NavigationClearanceView, context: Context) {
        view.onChange = { value in
            if abs(clearance - value) > 0.5 { clearance = value }
        }
        view.measureClearance()
    }
}

private final class NavigationClearanceView: UIView {
    var onChange: ((CGFloat) -> Void)?
    private var lastValue: CGFloat = -1
    private var retryCount = 0
    private var retryScheduled = false

    override func layoutSubviews() {
        super.layoutSubviews()
        measureClearance()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        retryCount = 0
        measureClearance()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        measureClearance()
    }

    func measureClearance() {
        guard let window,
              let navigationBar = (enclosingNavigationController() ?? navigationController(in: window.rootViewController))?.navigationBar else {
            scheduleRetry()
            return
        }
        // GeometryReader lays the workspace out from the window origin, beneath NavigationStack chrome.
        let value = max(0, navigationBar.convert(navigationBar.bounds, to: window).maxY)
        if abs(lastValue - value) > 0.5 {
            lastValue = value
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard window != nil, retryCount < 20, !retryScheduled else { return }
        retryCount += 1
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            retryScheduled = false
            measureClearance()
        }
    }

    private func enclosingNavigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let navigationController = current as? UINavigationController { return navigationController }
            if let controller = current as? UIViewController,
               let navigationController = controller.navigationController {
                return navigationController
            }
            responder = current.next
        }
        return nil
    }

    private func navigationController(in controller: UIViewController?) -> UINavigationController? {
        guard let controller else { return nil }
        if let navigationController = controller as? UINavigationController { return navigationController }
        if let presented = navigationController(in: controller.presentedViewController) { return presented }
        for child in controller.children {
            if let navigationController = navigationController(in: child) { return navigationController }
        }
        return nil
    }
}

private struct WorkspaceLayerStyle {
    let offset: CGFloat
    let scale: CGFloat
    let blur: CGFloat
    let opacity: CGFloat
    let shadow: CGFloat
    let zIndex: Double
}

private extension View {
    func workspaceLayer(_ style: WorkspaceLayerStyle) -> some View {
        offset(x: style.offset)
            .scaleEffect(style.scale, anchor: .leading)
            .blur(radius: style.blur)
            .opacity(max(0, style.opacity))
            .shadow(color: .black.opacity(style.shadow > 0 ? 0.2 : 0), radius: style.shadow, x: -6)
            .zIndex(style.zIndex)
    }
}
