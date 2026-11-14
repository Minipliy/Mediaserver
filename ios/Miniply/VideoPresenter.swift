import AVKit
import Combine
import SwiftUI
import UIKit

/// Native full-screen video player (AVPlayerViewController), always in landscape,
/// with AirPlay, Picture-in-Picture, scrubbing and the system close button.
final class FullscreenPlayerController: AVPlayerViewController, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
    var onClose: (@MainActor () -> Void)?
    private var pictureInPictureActive = false
    weak var playback: PlayerModel?
    private var timeObserver: Any?
    private var phaseWatch: AnyCancellable?
    private weak var observedPlayer: AVPlayer?
    private var shownActions = ""
    /// "Nächste Folge" floating over the video
    /// (AVPlayerViewController's own contextual actions exist only on tvOS).
    private lazy var nextButton = makeActionButton(title: String(localized: "Nächste Folge"), symbol: "forward.end.fill") { [weak self] in
        self?.playback?.next()
    }
    /// Only offered when the server found the same intro in every episode of the season.
    private lazy var introButton = makeActionButton(title: String(localized: "Intro überspringen"), symbol: "forward.fill") { [weak self] in
        guard let self, let intro = self.playback?.current?.intro else { return }
        self.playback?.seek(intro.end)
    }
    private lazy var actionStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [introButton, nextButton])
        stack.axis = .vertical
        stack.alignment = .trailing
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    /// The player's own menu cannot be extended on iOS: a button of its own that shows
    /// after a tap, like the player's controls, and then fades again.
    private lazy var subtitleButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "captions.bubble")
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            MainActor.assumeIsolated { self?.chooseSubtitle() }
        })
        button.accessibilityLabel = String(localized: "Untertitel")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0
        return button
    }()
    private var subtitleButtonFade: Task<Void, Never>?
    private static let subtitleButtonSeconds = 4

    private func installSubtitleButton() {
        guard subtitleButton.superview == nil else { return }
        view.addSubview(subtitleButton)
        NSLayoutConstraint.activate([
            subtitleButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            subtitleButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(showSubtitleButton))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func showSubtitleButton() {
        guard playback?.current?.subtitles?.isEmpty == false else { return }
        subtitleButtonFade?.cancel()
        UIView.animate(withDuration: 0.2) { self.subtitleButton.alpha = 1 }
        subtitleButtonFade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.subtitleButtonSeconds))
            guard !Task.isCancelled else { return }
            UIView.animate(withDuration: 0.3) { self?.subtitleButton.alpha = 0 }
        }
    }

    private func updateSubtitleButton(for media: Media) {
        subtitleButton.isHidden = media.subtitles?.isEmpty != false
    }

    private func chooseSubtitle() {
        guard let playback, let media = playback.current else { return }
        let selected = playback.preferredSubtitle(for: media)?.id
        let sheet = UIAlertController(title: String(localized: "Untertitel"), message: nil, preferredStyle: .actionSheet)
        func add(_ title: String, _ subtitle: SubtitleRef?) {
            sheet.addAction(UIAlertAction(title: subtitle?.id == selected ? "✓ " + title : title, style: .default) { [weak playback] _ in
                MainActor.assumeIsolated { playback?.chooseSubtitle(subtitle, for: media) }
            })
        }
        add(String(localized: "Aus"), nil)
        for track in media.subtitles ?? [] { add(track.label, track) }
        sheet.addAction(UIAlertAction(title: String(localized: "Abbrechen"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = subtitleButton
        sheet.popoverPresentationController?.sourceRect = subtitleButton.bounds
        present(sheet, animated: true)
    }

    private func makeActionButton(title: String, symbol: String, action: @escaping @MainActor () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.92)
        configuration.baseForegroundColor = .black
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            MainActor.assumeIsolated { action() }
        })
        button.isHidden = true
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.35
        button.layer.shadowRadius = 8
        return button
    }

    private func installActionButtons() {
        guard actionStack.superview == nil else { return }
        view.addSubview(actionStack)
        NSLayoutConstraint.activate([
            actionStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            actionStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -96),
        ])
    }
    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = UIFont.preferredFont(forTextStyle: .title3).withSize(22)
        label.adjustsFontForContentSizeCategory = true
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isAccessibilityElement = false
        return label
    }()
    private let subtitleBackground: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.layer.cornerRadius = 6
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private func installSubtitleView() {
        guard let overlay = contentOverlayView, subtitleBackground.superview == nil else { return }
        overlay.addSubview(subtitleBackground)
        subtitleBackground.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            subtitleLabel.leadingAnchor.constraint(equalTo: subtitleBackground.leadingAnchor, constant: 10),
            subtitleLabel.trailingAnchor.constraint(equalTo: subtitleBackground.trailingAnchor, constant: -10),
            subtitleLabel.topAnchor.constraint(equalTo: subtitleBackground.topAnchor, constant: 4),
            subtitleLabel.bottomAnchor.constraint(equalTo: subtitleBackground.bottomAnchor, constant: -4),
            subtitleBackground.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            subtitleBackground.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            subtitleBackground.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.86),
        ])
    }

    /// Without a player item nothing tells the viewer why the screen is black.
    private func showConnectionPhase(_ phase: String?) {
        guard playback?.reconnecting == true else { return }
        subtitleLabel.text = phase
        subtitleBackground.isHidden = phase == nil
    }

    private func updateSubtitle(at time: Double) {
        let text = playback?.subtitleText(at: time)
        if subtitleLabel.text != text { subtitleLabel.text = text }
        subtitleBackground.isHidden = text == nil
    }

    /// Watch the playback time to offer "Nächste Folge" near the end of an episode.
    func startContextualActions() {
        stopContextualActions()
        guard let player else { return }
        observedPlayer = player
        installSubtitleView()
        installActionButtons()
        installSubtitleButton()
        phaseWatch = playback?.$phase.sink { [weak self] phase in self?.showConnectionPhase(phase) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateContextualActions() }
        }
    }

    func stopContextualActions() {
        if let timeObserver { observedPlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        phaseWatch = nil
        observedPlayer = nil
        nextButton.isHidden = true
        introButton.isHidden = true
        shownActions = ""
        subtitleBackground.isHidden = true
    }

    private func updateContextualActions() {
        guard let playback, let current = playback.current, current.kind == "video", let player else { return }
        let time = player.currentTime().seconds
        let duration = playback.duration
        guard time.isFinite else { return }
        updateSubtitle(at: time)
        updateSubtitleButton(for: current)
        let next = playback.nextItem
        let showNext = next?.kind == "video" && duration > 60 && duration - time < 60
        // Until a second before its end, so a tap never lands after the intro is over.
        let showIntro = current.intro.map { time >= $0.start && time < $0.end - 1 } ?? false
        let key = "\(showNext)\(showIntro)\(next?.id ?? "")"
        if key != shownActions {
            shownActions = key
            UIView.animate(withDuration: 0.25) {
                self.introButton.isHidden = !showIntro
                self.nextButton.isHidden = !showNext
                self.actionStack.layoutIfNeeded()
            }
        }
    }

    /// The tap only reveals the button: the player keeps handling it as well.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { touch.view !== subtitleButton }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startContextualActions()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { returnToPortrait() }
        if (isBeingDismissed || presentingViewController == nil) && !pictureInPictureActive {
            stopContextualActions()
            onClose?()
        }
    }

    /// The app would otherwise stay in the player's landscape after closing it.
    private func returnToPortrait() {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = VideoPresenter.topViewController()?.view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPictureActive = true
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPictureActive = false
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool {
        true
    }

    /// Return from Picture-in-Picture to full screen.
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard presentingViewController == nil, let top = VideoPresenter.topViewController() else {
            completionHandler(true)
            return
        }
        top.present(self, animated: true) { completionHandler(true) }
    }
}

@MainActor
enum VideoPresenter {
    private static weak var current: FullscreenPlayerController?

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    static func present(_ playback: PlayerModel) {
        if let current, current.presentingViewController != nil { return }
        guard let top = topViewController() else { return }
        let controller = current ?? FullscreenPlayerController()
        controller.player = playback.player
        controller.modalPresentationStyle = .fullScreen
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = false
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.speeds = [0.5, 0.75, 1, 1.25, 1.5, 2].map { rate in
            AVPlaybackSpeed(rate: Float(rate), localizedName: rate == 1 ? "Normal" : String(format: "%g×", rate).replacingOccurrences(of: ".", with: ","))
        }
        controller.playback = playback
        controller.onClose = { [weak playback] in
            playback?.persistPosition()
        }
        current = controller
        top.present(controller, animated: true)
    }

    static func dismiss() {
        guard let current, current.presentingViewController != nil else { return }
        current.dismiss(animated: true)
    }
}

/// Start a video (with the following episodes as queue) in full screen.
@MainActor
func playFullscreen(_ media: Media, queue: [Media] = [], playback: PlayerModel, model: AppModel) {
    playback.play(media, in: queue.isEmpty ? [media] : queue, model: model)
    VideoPresenter.present(playback)
}
