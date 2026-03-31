import AVFoundation
import Get
import HLSCache
import Pulse
import PulseUI
import UIKit

final class ViewController: UIViewController, UITextFieldDelegate {
    private enum Constants {
        static let demoAlias = "MDDEMO"
        static let demoAssetID = "example-avplayer-stream"
        static let demoPlaylistURLString =
            "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8"
    }

    private let statusLabel = UILabel()
    private let playlistURLTextField = UITextField()
    private let playButton = UIButton(type: .system)
    private let playerContainerView = PlayerContainerView()
    private let pulseStore = LoggerStore.shared

    private var facade: HLSCacheFacade?
    private var player: AVPlayer?
    private var pulseNetworkLogger: NetworkLogger?
    private var apiClient: APIClient?
    private var didAutoPlay = false

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "HLSCache Example"
        view.backgroundColor = .systemBackground
        configurePulseAndGet()
        configureUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        runAutoPlayIfRequested()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resignFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        presentPulseConsole()
    }

    deinit {
        player?.pause()
        facade?.stopServer()
    }

    private func configurePulseAndGet() {
        let networkLogger = NetworkLogger(store: pulseStore)
        NetworkLogger.shared = networkLogger
        pulseNetworkLogger = networkLogger

        apiClient = APIClient(baseURL: nil) {
            $0.sessionDelegate = URLSessionProxyDelegate(logger: networkLogger)
        }

        pulseStore.storeMessage(
            label: "AVPlayerExample",
            level: .info,
            message: "Pulse initialized. Shake device to open logs."
        )
    }

    private func configureUI() {
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Enter an HLS URL, then tap Play. Shake device to open Pulse."

        playlistURLTextField.borderStyle = .roundedRect
        playlistURLTextField.text = Constants.demoPlaylistURLString
        playlistURLTextField.placeholder = "https://example.com/master.m3u8"
        playlistURLTextField.autocapitalizationType = .none
        playlistURLTextField.autocorrectionType = .no
        playlistURLTextField.spellCheckingType = .no
        playlistURLTextField.keyboardType = .URL
        playlistURLTextField.returnKeyType = .go
        playlistURLTextField.delegate = self

        playButton.configuration = .filled()
        playButton.configuration?.title = "Play Demo Stream"
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        playerContainerView.backgroundColor = .black
        playerContainerView.layer.cornerRadius = 12
        playerContainerView.layer.masksToBounds = true
        playerContainerView.playerLayer.videoGravity = .resizeAspect

        let stack = UIStackView(arrangedSubviews: [
            statusLabel,
            playlistURLTextField,
            playButton,
            playerContainerView
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            playerContainerView.heightAnchor.constraint(equalToConstant: 220)
        ])
    }

    @objc
    private func playTapped() {
        playButton.isEnabled = false
        statusLabel.text = "Preparing cache proxy..."

        do {
            let remoteURL = try requirePlaylistURL()
            let facade = try makeFacade()
            self.facade = facade

            _ = try facade.register(
                alias: Constants.demoAlias,
                assetID: Constants.demoAssetID,
                remoteURL: remoteURL
            )

            _ = try facade.startServer(host: "127.0.0.1", port: 0)
            let proxyURL = try facade.proxyURL(
                for: Constants.demoAlias,
                kind: .raw,
                remoteURL: remoteURL
            )

            statusLabel.text = "Playing stream through HLSCache proxy."
            pulseStore.storeMessage(
                label: "AVPlayerExample",
                level: .info,
                message: "Playing stream via proxy URL: \(proxyURL.absoluteString)"
            )
            playInline(url: proxyURL)
        } catch {
            statusLabel.text = "Failed: \(error.localizedDescription)"
            pulseStore.storeMessage(
                label: "AVPlayerExample",
                level: .error,
                message: "Playback failed: \(error.localizedDescription)"
            )
        }

        playButton.isEnabled = true
    }

    private func playInline(url: URL) {
        let player = player ?? AVPlayer()
        self.player = player
        playerContainerView.playerLayer.player = player
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    private func runAutoPlayIfRequested() {
        guard !didAutoPlay else { return }
        guard ProcessInfo.processInfo.environment["HLS_AUTOPLAY"] == "1" else { return }
        didAutoPlay = true
        playTapped()
    }

    private func makeFacade() throws -> HLSCacheFacade {
        if let facade {
            return facade
        }

        let cacheRoot = try appCacheRoot()
        let getClient = apiClient ?? APIClient(baseURL: nil)
        return HLSCacheFacade(
            baseDirectory: cacheRoot,
            networkClient: GetNetworkClient(client: getClient)
        )
    }

    private func appCacheRoot() throws -> URL {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "AVPlayerExample", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to resolve caches directory"
            ])
        }

        let root = cachesURL.appendingPathComponent("HLSCacheExample", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func requirePlaylistURL() throws -> URL {
        let text = (playlistURLTextField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw NSError(domain: "AVPlayerExample", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Please enter a valid http(s) playlist URL."
            ])
        }
        return url
    }

    private func presentPulseConsole() {
        guard presentedViewController == nil else { return }

        let console = MainViewController(store: pulseStore)
        console.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(dismissPulseConsole)
        )
        let nav = UINavigationController(rootViewController: console)
        present(nav, animated: true)
    }

    @objc
    private func dismissPulseConsole() {
        presentedViewController?.dismiss(animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        playTapped()
        return true
    }
}

private final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            fatalError("Expected AVPlayerLayer backing layer")
        }
        return layer
    }
}
