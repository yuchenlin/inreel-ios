import SwiftUI
import Photos
import SwiftData
import UIKit

/// Stable dual-slot hosts for Xiaohongshu-style follow-finger peek.
/// Slot identity never tracks asset id. Slots stay in fixed ZStack order (A, B);
/// settle springs to ±pageExtent then flips `frontSlot` + stackY→0 without remounting
/// AVPlayer / ZoomHost (front/back is zIndex/offset/active only).
///
/// The settle is frame-driven by `SpringDriver` (not `withAnimation` + sleep) so a new touch
/// can catch it mid-flight and reverse; the promote swap itself is unchanged.
private enum FeedCardSlot: Hashable {
    case a, b
}

struct FeedView: View {
    let authStatus: PHAuthorizationStatus
    @Binding var immersive: Bool
    var onRevealTabs: () -> Void

    @Environment(\.modelContext) private var modelContext
    /// False while Feed stays mounted under another tab (ZStack keep-alive).
    @Environment(\.isTabActive) private var isTabActive
    @Environment(BasketFlyController.self) private var basketFly
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(FeedTrack.storageKey) private var feedFilterRaw = FeedTrack.default.rawValue
    @AppStorage(AppSettings.cooldownDaysKey) private var cooldownDays = AppSettings.defaultCooldownDays

    @State private var viewModel = FeedViewModel()
    /// Horizontal only (basket). Vertical paging uses `stackY`.
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var notesPresentation: NotesPresentation?
    @State private var notesRefreshToken = 0
    @State private var isPaging = false
    @State private var pageExtent: CGFloat = UIScreen.main.bounds.height
    @State private var crossedBasketThreshold = false
    @State private var crossedBasketAt: Date?
    @State private var cardZoomed = false
    /// Raw horizontal drag (≤0) used for threshold / progress; display may rubber-band.
    @State private var basketDragRaw: CGFloat = 0
    /// Undo toast for the most recently basketed asset id.
    @State private var undoBasketID: String?
    @State private var undoHideTask: Task<Void, Never>?

    // Dual-slot stack (follow-finger peek).
    @State private var slotAAsset: PHAsset?
    @State private var slotBAsset: PHAsset?
    @State private var frontSlot: FeedCardSlot = .a
    /// Continuous vertical translation of the front card; neighbor rides at ±pageExtent.
    @State private var stackY: CGFloat = 0
    /// When true, back slot sits below (next). When false, back sits above (prev).
    @State private var neighborBelow = true
    @State private var neighborVisible = false

    // Interruptible settle + edge resistance.
    /// Frame-driven spring for page settle / cancel; `stop()` returns the on-screen value.
    @State private var settleDriver = SpringDriver()
    /// stackY = anchor + translation. 0 for gestures from rest; non-zero when a gesture
    /// caught an in-flight settle (or began during the promote) so the card never jumps.
    @State private var dragAnchorY: CGFloat?
    /// This gesture grabbed a moving card — stays vertical and uses paging-scroll targeting.
    @State private var gestureCaughtSettle = false
    @State private var gestureStartedWhilePaging = false
    /// This touch began on (or turned into) a long-video scrub — never page or basket it.
    @State private var gestureSawScrub = false
    /// Neighbor availability sampled once per gesture (drives rubber-band at feed edges).
    @State private var gestureHasNext = true
    @State private var gestureHasPrev = true
    @State private var edgeHapticFired = false
    /// Reduce Motion crossfade: back slot pinned at y=0 under the fading front.
    @State private var pinBackToCenter = false
    /// Opacity multiplier for the front slot (Reduce Motion crossfades only; 1 otherwise).
    @State private var frontFade: Double = 1

    private let swipeThreshold: CGFloat = 80
    /// Anti-mis-tap: ~160–180 or 42% of width (was fixed 120).
    private var basketSwipeThreshold: CGFloat {
        let w = UIScreen.main.bounds.width
        return max(160, min(180, w * 0.42))
    }
    private let basketAxisRatio: CGFloat = 1.35
    private let basketDwellSeconds: TimeInterval = 0.12

    private var selectedTrack: FeedTrack {
        FeedTrack.fromStorage(feedFilterRaw)
    }

    private var frontAsset: PHAsset? {
        frontSlot == .a ? slotAAsset : slotBAsset
    }

    private var backAsset: PHAsset? {
        frontSlot == .a ? slotBAsset : slotAAsset
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            // Left-swipe basket affordance behind the card (swipe-up never deletes).
            if basketDragRaw < -16 {
                basketAffordance
            }

            content
                .simultaneousGesture(pagingGesture)

            VStack(spacing: 8) {
                if authStatus == .limited {
                    limitedBanner
                }
                HStack {
                    Spacer()
                    trackMenu
                }
                .padding(.horizontal, 16)
                Spacer()
            }
            .padding(.top, 8)

            if immersive {
                VStack {
                    Spacer()
                    Button(action: onRevealTabs) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.70))
                            .padding(9)
                            .background(Circle().fill(Theme.floatingFill))
                    }
                    .accessibilityLabel(Text(String(localized: "feed.revealTabs")))
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }

            if undoBasketID != nil {
                undoToast
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .statusBarHidden(immersive)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: FeedPageHeightKey.self, value: geo.size.height)
            }
        }
        .onPreferenceChange(FeedPageHeightKey.self) { height in
            if height > 0 { pageExtent = height }
        }
        .task {
            Haptics.prepare()
            viewModel.configure(modelContext: modelContext, cooldownDays: cooldownDays)
            await viewModel.start(track: selectedTrack)
            syncSlotsFromViewModel(warmNext: true)
        }
        .onChange(of: viewModel.currentAsset?.localIdentifier) { _, newID in
            guard !isPaging else { return }
            // External model changes (track switch, library, basket from chrome) — resync slots.
            if newID != frontAsset?.localIdentifier {
                syncSlotsFromViewModel(warmNext: true)
            }
            cardZoomed = false
        }
        .onChange(of: cardZoomed) { _, zoomed in
            if zoomed, !isPaging {
                settleDriver.stop()
                dragOffset = .zero
                basketDragRaw = 0
                stackY = 0
            }
        }
        .onChange(of: feedFilterRaw) { _, newRaw in
            let track = FeedTrack.fromStorage(newRaw)
            Task {
                await viewModel.setTrack(track)
                syncSlotsFromViewModel(warmNext: true)
            }
        }
        .onChange(of: cooldownDays) { _, days in
            viewModel.updateCooldownDays(days)
        }
        .onChange(of: isTabActive) { _, active in
            // Detach pool entries while hidden so Liked viewer can acquire a clean AVPlayer
            // for the same asset (one AVPlayerLayer per player — dual hosts paint black).
            if !active {
                VideoPlayerPool.shared.releaseAll()
            }
        }
        .sheet(item: $notesPresentation, onDismiss: {
            notesRefreshToken += 1
        }) { item in
            NoteEditorSheet(localIdentifier: item.id, asset: item.asset)
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && frontAsset == nil {
            ProgressView()
                .tint(.white)
        } else if frontAsset != nil || viewModel.currentAsset != nil {
            cardStack
        } else if viewModel.sampler.isEmpty || viewModel.sampler.isExhausted {
            emptyState
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    /// Two persistent hosts in FIXED tree order (A then B). Front/back is only
    /// zIndex + offset + isActive — never reorder branches on `frontSlot` flip, or
    /// SwiftUI remounts ZoomHost / AVPlayerLayer and the settled video "re-renders".
    private var cardStack: some View {
        let h = max(pageExtent, 1)
        return ZStack {
            slotLayer(slot: .a, pageH: h)
            slotLayer(slot: .b, pageH: h)
        }
        // Clip so the peek neighbor doesn't paint over chrome outside the feed.
        .clipped()
    }

    @ViewBuilder
    private func slotLayer(slot: FeedCardSlot, pageH: CGFloat) -> some View {
        let asset: PHAsset? = (slot == .a) ? slotAAsset : slotBAsset
        if let asset {
            let isFront = frontSlot == slot
            // Opacity only — never remove the host from the tree on settle, or the
            // next warm/peek remounts ZoomHost / AVPlayerLayer.
            let show = isFront || neighborVisible
            let y = slotOffsetY(isFront: isFront, pageH: pageH)
            let displayX = isFront ? basketDisplayX : 0
            slotCard(asset: asset, slot: slot, active: isFront)
                .offset(
                    x: displayX,
                    y: isFront ? (y + dragOffset.height) : y
                )
                .rotationEffect(isFront ? .degrees(Double(min(0, displayX)) / 36.0) : .zero)
                .scaleEffect(
                    isFront && basketDragRaw < -16
                        ? max(0.94, 1 + basketDragRaw / 1400)
                        : 1
                )
                .overlay {
                    if isFront, basketProgress >= 1 {
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(Theme.accent.opacity(0.55), lineWidth: 2.5)
                            .allowsHitTesting(false)
                    }
                }
                .brightness(isFront && basketProgress >= 1 ? -0.06 : 0)
                .opacity(show ? (isFront ? frontFade : 1) : 0)
                .zIndex(isFront ? 1 : 0)
                .allowsHitTesting(isFront)
        }
    }

    private func slotOffsetY(isFront: Bool, pageH: CGFloat) -> CGFloat {
        if isFront { return stackY }
        // Reduce Motion crossfade: next card waits in place under the fading front.
        if pinBackToCenter { return 0 }
        let backBase: CGFloat = neighborBelow ? pageH : -pageH
        return backBase + stackY
    }

    @ViewBuilder
    private func slotCard(asset: PHAsset, slot: FeedCardSlot, active: Bool) -> some View {
        FeedCardView(
            asset: asset,
            notesRefreshToken: notesRefreshToken,
            onBasket: active ? { Task { await commitBasket() } } : nil,
            onNotes: active ? { notesPresentation = NotesPresentation(asset: asset) } : nil,
            zoomLock: active ? $cardZoomed : .constant(false),
            isActiveCard: active && isTabActive,
            tabBarVisible: !immersive
        )
        // Stable slot identity — MUST NOT use asset.localIdentifier (that remounts on settle).
        .id(slot)
        .transaction { $0.disablesAnimations = true }
    }

    private var basketProgress: CGFloat {
        min(1, max(0, -basketDragRaw / basketSwipeThreshold))
    }

    /// Rubber-band past threshold so overshoot feels resistant (display only).
    private var basketDisplayX: CGFloat {
        // During fly-off animation dragOffset.width is set far left — prefer that.
        if dragOffset.width < -basketSwipeThreshold * 1.5 {
            return dragOffset.width
        }
        let raw = basketDragRaw
        let t = basketSwipeThreshold
        if -raw <= t { return raw }
        let excess = -raw - t
        return -(t + excess * Motion.basketOverdragResistance)
    }

    private var basketAffordance: some View {
        let armed = basketProgress >= 1
        return ZStack {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.0),
                        Color.red.opacity(0.18 + 0.35 * Double(basketProgress) + (armed ? 0.12 : 0))
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 180)
            }
            .allowsHitTesting(false)

            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(armed ? Theme.accent : .white)
                        .scaleEffect(0.82 + 0.42 * basketProgress)
                        .shadow(color: (armed ? Theme.accent : .black).opacity(armed ? 0.55 : 0.35), radius: armed ? 12 : 8, y: 2)
                    Text(String(localized: "basket.add"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85 + 0.15 * Double(basketProgress)))
                        .opacity(Double(min(1, basketProgress * 1.4)))
                }
                .padding(.trailing, 26)
            }
        }
        .opacity(Double(min(1, basketProgress * 1.15)))
        .animation(reduceMotion ? Motion.reduced : Motion.basketArm, value: armed)
    }

    /// Compact Undo chip — sits *above* feed meta / side actions so it never
    /// covers date, albums, or the right-rail buttons. Fly-into-trash is the
    /// primary delete feedback; this is a secondary, narrow affordance only.
    private var undoToast: some View {
        VStack {
            Spacer()
            Button {
                if let id = undoBasketID {
                    performUndoBasket(id: id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .bold))
                    Text(String(localized: "feed.basketUndo.action"))
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.55))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(Text(String(localized: "feed.basketUndo.action")))
            // Meta uses floatingTabChromeBottomPad; lift ~72pt so the chip clears
            // the date row and right-rail circles without covering them.
            .padding(.bottom, Theme.floatingTabChromeBottomPad + 72)
        }
        // Rises a few points out of the chrome it belongs to (attached to the action, not a
        // floating alert). Reduce Motion: opacity only.
        .transition(reduceMotion ? .opacity : .offset(y: Motion.undoRise).combined(with: .opacity))
        .zIndex(20)
        .allowsHitTesting(true)
    }

    private var trackMenu: some View {
        Menu {
            ForEach(FeedTrack.allCases) { track in
                Button {
                    feedFilterRaw = track.rawValue
                } label: {
                    if track == selectedTrack {
                        Label(track.title, systemImage: "checkmark")
                    } else {
                        Text(track.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .semibold))
                Text(selectedTrack.title)
                    .font(.caption2.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Theme.floatingFill)
            )
        }
        .accessibilityLabel(Text(String(localized: "track.menu")))
    }

    private var limitedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "feed.limitedBanner"))
                        .font(.caption.weight(.semibold))
                    Text(
                        String(
                            format: String(localized: "feed.limitedCount"),
                            locale: .current,
                            viewModel.limitedAssetCount
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button {
                    PhotoLibrary.openSettings()
                } label: {
                    Text(String(localized: "feed.limited.openAll"))
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.22)))
                }
                .buttonStyle(.plain)

                Button {
                    PhotoLibrary.presentLimitedLibraryPicker()
                } label: {
                    Text(String(localized: "feed.limited.manage"))
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.9))
        )
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(String(localized: "track.empty.title"))
                .font(.title3.bold())
                .foregroundStyle(Theme.primaryText)
            Text(String(localized: "track.empty.body"))
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    /// Vertical = next/prev with follow-finger peek. Horizontal left = basket. Up never deletes.
    private var pagingGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                guard !cardZoomed else {
                    if !isPaging {
                        settleDriver.stop()
                        dragOffset = .zero
                        basketDragRaw = 0
                        stackY = 0
                    }
                    return
                }
                if VideoScrubGate.isScrubbing || VideoSpeedGate.isBoosting || gestureSawScrub {
                    // Scrub bar or center 2× long-press owns this touch (simultaneous with us).
                    if !gestureSawScrub {
                        gestureSawScrub = true
                        if !isPaging, !settleDriver.isRunning {
                            dragOffset = .zero
                            basketDragRaw = 0
                            stackY = 0
                        }
                    }
                    return
                }
                let dy = value.translation.height
                let dx = value.translation.width
                if !isDragging {
                    // First event of a new gesture.
                    isDragging = true
                    dragAnchorY = nil
                    gestureCaughtSettle = false
                    gestureStartedWhilePaging = isPaging
                    edgeHapticFired = false
                    refreshEdgeAvailability()
                }

                if settleDriver.isRunning {
                    let vertical = abs(dy) >= abs(dx)
                    if isPaging {
                        // Catch an in-flight page settle (Apple interruptibility) while it is
                        // still < 85% there. Horizontal intent waits for the promote.
                        guard vertical, abs(settleDriver.value) < Motion.pageInterruptFraction * max(pageExtent, 1) else { return }
                        let caught = settleDriver.stop()
                        isPaging = false
                        stackY = caught
                        gestureCaughtSettle = true
                        dragAnchorY = caught - dy
                    } else {
                        // Catch a cancel / edge bounce-back.
                        let caught = settleDriver.stop()
                        stackY = caught
                        if vertical, abs(caught) > 0.5 {
                            gestureCaughtSettle = true
                            dragAnchorY = caught - dy
                        } else {
                            stackY = 0
                        }
                    }
                } else if isPaging {
                    // Promote swap in progress (a few ms) — ignore until it lands.
                    return
                }

                if dragAnchorY == nil {
                    // From rest: card tracks the raw translation (unchanged feel). A gesture that
                    // began during the promote continues from where the card is, without a jump.
                    dragAnchorY = gestureStartedWhilePaging ? (stackY - dy) : 0
                    if gestureStartedWhilePaging {
                        // Front may have just been promoted — re-sample the edges.
                        refreshEdgeAvailability()
                    }
                }
                let anchor = dragAnchorY ?? 0

                // Axis lock: require clear horizontal dominance before basket mode.
                // A gesture that grabbed a moving card stays vertical.
                if !gestureCaughtSettle, abs(dx) > abs(dy) * basketAxisRatio {
                    // Horizontal = basket only (left). Keep warmed neighbor mounted (just collapse Y).
                    stackY = 0
                    let raw = min(0, dx)
                    basketDragRaw = raw
                    dragOffset = CGSize(width: raw, height: 0)
                    let past = raw <= -basketSwipeThreshold
                    if past, !crossedBasketThreshold {
                        crossedBasketThreshold = true
                        crossedBasketAt = Date()
                        Haptics.basketThreshold()
                    } else if !past, crossedBasketThreshold {
                        crossedBasketThreshold = false
                        crossedBasketAt = nil
                        Haptics.light()
                    }
                } else {
                    // Prefer vertical when ambiguous — up never deletes.
                    crossedBasketThreshold = false
                    crossedBasketAt = nil
                    basketDragRaw = 0
                    dragOffset = .zero
                    let raw = anchor + dy
                    stackY = resistedStackY(raw)
                    if raw < -6 {
                        prepareNeighbor(goingNext: true)
                    } else if raw > 6 {
                        prepareNeighbor(goingNext: false)
                    }
                    let atEdge = (raw < 0 && !gestureHasNext) || (raw > 0 && !gestureHasPrev)
                    if atEdge, abs(raw) > swipeThreshold, !edgeHapticFired {
                        // "No more" — one soft tick per gesture at the hard end.
                        edgeHapticFired = true
                        Haptics.soft()
                    }
                }
            }
            .onEnded { value in
                let anchor = dragAnchorY
                let caught = gestureCaughtSettle
                let sawScrub = gestureSawScrub
                defer {
                    gestureSawScrub = false
                    isDragging = false
                    crossedBasketThreshold = false
                    crossedBasketAt = nil
                    dragAnchorY = nil
                    gestureCaughtSettle = false
                    gestureStartedWhilePaging = false
                }
                guard !cardZoomed else {
                    if !isPaging {
                        settleDriver.stop()
                        dragOffset = .zero
                        basketDragRaw = 0
                        stackY = 0
                    }
                    return
                }
                if sawScrub { return }
                // Never accepted (whole gesture happened during a non-interruptible promote).
                guard !isPaging, let anchor else { return }
                let dy = value.translation.height
                let dx = value.translation.width
                let predictedY = value.predictedEndTranslation.height
                let predictedX = value.predictedEndTranslation.width
                let dwellOK: Bool = {
                    guard let t = crossedBasketAt else { return false }
                    return Date().timeIntervalSince(t) >= basketDwellSeconds
                }()

                if !caught, abs(dx) > abs(dy) * basketAxisRatio {
                    let pastNow = dx <= -basketSwipeThreshold
                    let predictedPast = predictedX < -basketSwipeThreshold
                    // Commit if past threshold with prediction, or held past threshold (dwell).
                    let shouldBasket = pastNow && (predictedPast || dwellOK)
                        || min(dx, predictedX) < -basketSwipeThreshold
                    if shouldBasket {
                        let releaseVelocity = value.velocity
                        Task { await commitBasket(releaseVelocity: releaseVelocity) }
                    } else {
                        withAnimation(reduceMotion ? Motion.reduced : Motion.basketCancel) {
                            dragOffset = .zero
                            basketDragRaw = 0
                        }
                    }
                    return
                }

                basketDragRaw = 0

                let bottomEdge: CGFloat = 110
                let startedNearBottom = value.startLocation.y > (pageExtent - bottomEdge)
                if !caught, anchor == 0, startedNearBottom, dy < -swipeThreshold,
                   let asset = frontAsset ?? viewModel.currentAsset {
                    settleToRest(atEdge: false, velocity: 0)
                    notesPresentation = NotesPresentation(asset: asset)
                    return
                }

                // Effective card offset (p) and its momentum projection. From rest anchor == 0,
                // so this is exactly the previous translation-based rule.
                let p = anchor + dy
                let projected = anchor + predictedY
                var commitNext = p < -swipeThreshold || projected < -swipeThreshold * 1.35
                var commitPrev = p > swipeThreshold || projected > swipeThreshold * 1.35
                if caught {
                    // Grabbed mid-settle: paging-scroll semantics — never skip past the current
                    // card; a flick back toward rest returns to it (change of mind).
                    if p <= 0 {
                        commitPrev = false
                        commitNext = projected < -swipeThreshold * 1.35 || (p < -swipeThreshold && projected < -swipeThreshold)
                    } else {
                        commitNext = false
                        commitPrev = projected > swipeThreshold * 1.35 || (p > swipeThreshold && projected > swipeThreshold)
                    }
                }

                // Swipe UP → next; swipe DOWN → previous. Never delete.
                let velocityY = value.velocity.height
                if commitNext, viewModel.peekNextAsset() != nil || viewModel.sampler.peekNextIdentifier() != nil {
                    commitPage(goingNext: true, velocity: velocityY)
                } else if commitPrev, viewModel.sampler.canGoBack {
                    commitPage(goingNext: false, velocity: velocityY)
                } else {
                    let atEdge = (p < 0 && !gestureHasNext) || (p > 0 && !gestureHasPrev)
                    settleToRest(atEdge: atEdge, velocity: velocityY)
                }
            }
    }

    private func refreshEdgeAvailability() {
        gestureHasNext = viewModel.peekNextAsset() != nil || viewModel.sampler.peekNextIdentifier() != nil
        gestureHasPrev = viewModel.sampler.canGoBack
    }

    /// Rubber-band past the first / last item (no neighbor in that direction).
    private func resistedStackY(_ raw: CGFloat) -> CGFloat {
        if raw < 0, !gestureHasNext { return -Self.rubberBand(-raw, extent: max(pageExtent, 1)) }
        if raw > 0, !gestureHasPrev { return Self.rubberBand(raw, extent: max(pageExtent, 1)) }
        return raw
    }

    /// UIScrollView-style resistance: rises with distance, never exceeds `extent`.
    static func rubberBand(_ x: CGFloat, extent d: CGFloat) -> CGFloat {
        let c = Motion.edgeRubberBandConstant
        return (1 - 1 / (x * c / d + 1)) * d
    }

    /// Spring the stack back to y=0 (cancel or edge bounce-back). Frame-driven, so a new touch
    /// can catch it. The warmed next neighbor is restored once at rest.
    private func settleToRest(atEdge: Bool, velocity: CGFloat) {
        dragOffset = .zero
        guard abs(stackY) > 0.5 else {
            settleDriver.stop()
            stackY = 0
            prepareNeighbor(goingNext: true)
            return
        }
        let spec: SpringSpec = reduceMotion ? Motion.reducedSettle : (atEdge ? Motion.edgeRelease : Motion.pageCancel)
        // Only hand off velocity that points home; edges / reduce motion settle from still.
        var v = (atEdge || reduceMotion) ? 0 : velocity
        if (0 - stackY) * v < 0 { v = 0 }
        v = max(-Motion.pageMaxHandoffVelocity, min(Motion.pageMaxHandoffVelocity, v))
        settleDriver.animate(
            from: stackY,
            to: 0,
            initialVelocity: v,
            response: spec.response,
            dampingFraction: spec.dampingFraction,
            onUpdate: { y in
                setStackYWithoutAnimation(y)
            },
            onComplete: {
                prepareNeighbor(goingNext: true)
            }
        )
    }

    private func setStackYWithoutAnimation(_ y: CGFloat) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            stackY = y
        }
    }

    /// Load peek target into the back slot without advancing the sampler.
    private func prepareNeighbor(goingNext: Bool) {
        let peek: PHAsset? = goingNext ? viewModel.peekNextAsset() : viewModel.peekPrevAsset()
        guard let peek else {
            neighborVisible = false
            return
        }
        // Avoid rewriting the same asset (would trigger VideoCardView softReset).
        let existingBackID = backAsset?.localIdentifier
        if existingBackID != peek.localIdentifier || neighborBelow != goingNext {
            assignBack(peek)
        }
        neighborBelow = goingNext
        neighborVisible = true
    }

    private func assignBack(_ asset: PHAsset) {
        if frontSlot == .a {
            slotBAsset = asset
        } else {
            slotAAsset = asset
        }
    }

    private func assignFront(_ asset: PHAsset) {
        if frontSlot == .a {
            slotAAsset = asset
        } else {
            slotBAsset = asset
        }
    }

    /// Idle / external sync: front = current, back = warmed next.
    private func syncSlotsFromViewModel(warmNext: Bool) {
        settleDriver.stop()
        pinBackToCenter = false
        frontFade = 1
        guard let current = viewModel.currentAsset else {
            slotAAsset = nil
            slotBAsset = nil
            neighborVisible = false
            stackY = 0
            dragOffset = .zero
            basketDragRaw = 0
            return
        }
        assignFront(current)
        if warmNext, let next = viewModel.peekNextAsset() {
            assignBack(next)
            neighborBelow = true
            neighborVisible = true
        } else {
            neighborVisible = false
        }
        stackY = 0
        dragOffset = .zero
        basketDragRaw = 0
    }

    /// Commit a vertical page. The settle is frame-driven from the live `stackY` with the
    /// finger's release velocity, and stays catchable by a new touch until ~85% there.
    /// Once landed, the promote is the same disablesAnimations swap as before (no remount).
    @MainActor
    private func commitPage(goingNext: Bool, velocity: CGFloat) {
        guard !isPaging else { return }
        isPaging = true

        prepareNeighbor(goingNext: goingNext)
        guard backAsset != nil else {
            isPaging = false
            settleToRest(atEdge: true, velocity: 0)
            return
        }

        let h = max(pageExtent, 1)
        let targetY: CGFloat = goingNext ? -h : h
        dragOffset = .zero

        if reduceMotion {
            // No vertical travel: crossfade to the neighbor in place, then promote.
            settleDriver.stop()
            var pin = Transaction()
            pin.disablesAnimations = true
            withTransaction(pin) {
                neighborVisible = true
                pinBackToCenter = true
            }
            withAnimation(Motion.pageCrossfade) {
                frontFade = 0
            } completion: {
                Task { @MainActor in await promoteSettledPage(goingNext: goingNext) }
            }
            return
        }

        // Hand off only velocity that points toward the target (a flick back is a cancel).
        var v = velocity
        if (targetY - stackY) * v < 0 { v = 0 }
        v = max(-Motion.pageMaxHandoffVelocity, min(Motion.pageMaxHandoffVelocity, v))

        // Keep dual-card peek (both cards slide together). Settled card lands at y=0.
        settleDriver.animate(
            from: stackY,
            to: targetY,
            initialVelocity: v,
            response: Motion.pageSettle.response,
            dampingFraction: Motion.pageSettle.dampingFraction,
            onUpdate: { y in
                setStackYWithoutAnimation(y)
            },
            onComplete: {
                Task { @MainActor in await promoteSettledPage(goingNext: goingNext) }
            }
        )
    }

    @MainActor
    private func promoteSettledPage(goingNext: Bool) async {
        guard isPaging else { return }
        defer { isPaging = false }

        // Promote the on-screen slot to front. Slots stay in fixed ZStack order, so
        // this only flips zIndex/active/offset — AVPlayer / ZoomHost do not remount.
        // stackY → 0 is position-continuous (back was at backBase+targetY == 0).
        var swap = Transaction()
        swap.disablesAnimations = true
        withTransaction(swap) {
            if goingNext {
                viewModel.next()
            } else {
                viewModel.previous()
            }
            frontSlot = (frontSlot == .a) ? .b : .a
            stackY = 0
            cardZoomed = false
            pinBackToCenter = false
            frontFade = 1
            // Keep retiring host opacity-0 for one turn so its softReset (warm next)
            // cannot composite over the settled front in the same frame.
            neighborVisible = false
        }
        await Task.yield()
        var warm = Transaction()
        warm.disablesAnimations = true
        withTransaction(warm) {
            if let next = viewModel.peekNextAsset() {
                assignBack(next)
                neighborBelow = true
                neighborVisible = true
            } else {
                neighborVisible = false
            }
        }
        Haptics.prepare()
    }

    @MainActor
    private func commitBasket(releaseVelocity: CGSize = .zero) async {
        guard !isPaging else { return }
        settleDriver.stop()
        isPaging = true
        defer {
            isPaging = false
            crossedBasketThreshold = false
            crossedBasketAt = nil
        }
        crossedBasketThreshold = true

        let departing = frontAsset ?? viewModel.currentAsset
        let basketedID = departing?.localIdentifier

        // Fly thumbnail into the floating trash tab (primary delete feedback).
        // Reduce Motion: no fly — the card fades and the badge count updates.
        if let departing, let basketedID, !reduceMotion {
            let bounds = UIScreen.main.bounds
            // Start where the card visually is at release (it may be dragged left / overdragged),
            // so the thumb continues the swipe instead of popping from screen center.
            let start = CGPoint(x: bounds.midX + basketDisplayX, y: bounds.midY - 24)
            let thumb = BasketFlyController.quickThumbnail(for: departing)
            basketFly.playFly(
                assetID: basketedID,
                startCenter: start,
                image: thumb,
                isVideo: departing.mediaType == .video,
                releaseVelocity: releaseVelocity
            )
        }

        // Prefer promoting the already-warmed next slot after the card settles.
        prepareNeighbor(goingNext: true)
        // Commit the model first: basketing can change what comes next (the sampler drops the
        // id from history / queue), so only reveal the warmed back slot if it really is the
        // next card. Otherwise the departing card fades to the background and the real next
        // card slides in after the swap (never flash a wrong card underneath).
        var commit = Transaction()
        commit.disablesAnimations = true
        withTransaction(commit) {
            viewModel.sendCurrentToBasket()
        }
        let nextIsWarm = backAsset != nil
            && viewModel.currentAsset?.localIdentifier == backAsset?.localIdentifier

        var pin = Transaction()
        pin.disablesAnimations = true
        withTransaction(pin) {
            pinBackToCenter = nextIsWarm
            stackY = 0
        }
        if reduceMotion {
            // Crossfade in place (no fly, no travel).
            withAnimation(Motion.reduced) {
                frontFade = 0
            }
            try? await Task.sleep(nanoseconds: Motion.reducedSwapDelay)
        } else {
            // Hand off to the fly immediately: the departing card fades where the finger left
            // it (ease-out — no ease-in hesitation) while the next card waits in place
            // underneath, so the reveal is a short crossfade instead of a black gap.
            withAnimation(Motion.basketCommit) {
                frontFade = 0
            }
            try? await Task.sleep(nanoseconds: Motion.basketCommitSwapDelay)
        }

        let w = UIScreen.main.bounds.width
        var swap = Transaction()
        swap.disablesAnimations = true
        withTransaction(swap) {
            if nextIsWarm, let current = viewModel.currentAsset,
               current.localIdentifier == backAsset?.localIdentifier {
                // Promote warmed next without remount.
                frontSlot = (frontSlot == .a) ? .b : .a
                dragOffset = .zero
                basketDragRaw = 0
                stackY = 0
                if let next = viewModel.peekNextAsset() {
                    assignBack(next)
                    neighborBelow = true
                    neighborVisible = true
                } else {
                    neighborVisible = false
                }
            } else if let current = viewModel.currentAsset {
                assignFront(current)
                dragOffset = CGSize(width: reduceMotion ? 0 : w * 0.18, height: 0)
                basketDragRaw = 0
                if let next = viewModel.peekNextAsset() {
                    assignBack(next)
                    neighborBelow = true
                    neighborVisible = true
                } else {
                    neighborVisible = false
                }
            } else {
                slotAAsset = nil
                slotBAsset = nil
                neighborVisible = false
                dragOffset = .zero
                basketDragRaw = 0
            }
            cardZoomed = false
            pinBackToCenter = false
            frontFade = 1
        }

        if dragOffset.width != 0 {
            withAnimation(Motion.basketSlideIn) {
                dragOffset = .zero
                basketDragRaw = 0
            }
            try? await Task.sleep(nanoseconds: Motion.basketSlideInSettle)
        }
        if let basketedID {
            presentUndoToast(for: basketedID)
        }
        Haptics.prepare()
    }

    private func presentUndoToast(for id: String) {
        undoHideTask?.cancel()
        withAnimation(reduceMotion ? Motion.reduced : Motion.undoPresent) {
            undoBasketID = id
        }
        undoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Motion.undoDwell)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? Motion.reduced : Motion.undoDismiss) {
                if undoBasketID == id {
                    undoBasketID = nil
                }
            }
        }
    }

    private func performUndoBasket(id: String) {
        undoHideTask?.cancel()
        viewModel.undoBasket(localIdentifier: id)
        withAnimation(reduceMotion ? Motion.reduced : Motion.undoDismiss) {
            undoBasketID = nil
        }
    }
}

private struct FeedPageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
