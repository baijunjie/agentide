import SwiftUI

enum WorkspaceLevel: Equatable {
    case session
    case browser
    case file(TextFileSelection)

    var depth: Int {
        switch self {
        case .session: 0
        case .browser: 1
        case .file: 2
        }
    }
}

struct WorkspaceNavigationState {
    var level: WorkspaceLevel = .session
    var fullScreenImage: ImageFileSelection?
    private(set) var presentedFile: TextFileSelection?

    mutating func showBrowser() {
        level = .browser
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
        case .browser:
            level = .session
        case .file:
            level = .browser
        }
    }

    mutating func finishFileDismissal() {
        if case .file = level { return }
        presentedFile = nil
    }
}

struct WorkspaceNavigationContainer<SessionContent: View, BrowserContent: View, FileContent: View>: View {
    @Binding var navigation: WorkspaceNavigationState
    @ViewBuilder let sessionContent: () -> SessionContent
    @ViewBuilder let browserContent: () -> BrowserContent
    @ViewBuilder let fileContent: (TextFileSelection) -> FileContent
    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let depth = interactiveDepth(width: width)
            let inactiveInset = inactiveLayerWidth(width)

            ZStack(alignment: .leading) {
                sessionContent()
                    .workspaceLayer(sessionStyle(depth: depth, width: width))
                    .allowsHitTesting(navigation.level == .session)
                    .accessibilityHidden(navigation.level != .session)

                browserContent()
                    .frame(width: width - inactiveInset)
                    .workspaceLayer(browserStyle(depth: depth, width: width, inactiveInset: inactiveInset))
                    .allowsHitTesting(navigation.level == .browser)
                    .accessibilityHidden(navigation.level != .browser)

                if let selection = navigation.presentedFile {
                    fileContent(selection)
                        .frame(width: width - inactiveInset)
                        .workspaceLayer(fileStyle(depth: depth, width: width, inactiveInset: inactiveInset))
                        .allowsHitTesting(navigation.level == .file(selection))
                        .accessibilityHidden(navigation.level != .file(selection))
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
        case .browser:
            return horizontal && beginsAwayFromSystemBackEdge && value.translation.width < 0
        case .file:
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
