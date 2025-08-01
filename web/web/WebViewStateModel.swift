import Foundation
import Combine
import AVFoundation

class WebViewStateModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?

    func goBack() {
        NotificationCenter.default.post(name: NSNotification.Name("WebViewGoBack"), object: nil)
    }
    func goForward() {
        NotificationCenter.default.post(name: NSNotification.Name("WebViewGoForward"), object: nil)
    }
    func reload() {
        NotificationCenter.default.post(name: NSNotification.Name("WebViewReload"), object: nil)
    }
}

class SilentAudioPlayer {
    static let shared = SilentAudioPlayer()
    private var player: AVAudioPlayer?

    func start() {
        guard let url = Bundle.main.url(forResource: "silent", withExtension: "mp3") else {
            print("silent.mp3 파일이 누락되었습니다.")
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 0
            player?.prepareToPlay()
            player?.play()
        } catch {
            print("무음 오디오 재생 실패: \(error)")
        }
    }

    func stop() {
        player?.stop()
    }
}
