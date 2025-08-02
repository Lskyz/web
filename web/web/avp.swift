import SwiftUI
import AVKit
import AVFoundation

// ✅ 무음 오디오 싱글톤 → 항상 세션 유지
class SilentAudioPlayer {
    static let shared = SilentAudioPlayer()
    private var player: AVAudioPlayer?

    private init() {
        configureAudioSession()
        playSilentAudio()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("🔇 Audio Session 설정 실패: \(error)")
        }
    }

    private func playSilentAudio() {
        if let url = Bundle.main.url(forResource: "web", withExtension: "mp3") {
            do {
                player = try AVAudioPlayer(contentsOf: url)
                player?.volume = 0
                player?.numberOfLoops = -1
                player?.play()
            } catch {
                print("🔇 무음 오디오 재생 실패: \(error)")
            }
        }
    }
}

// ✅ AVPlayer를 SwiftUI에서 사용 가능하게 Wrapping
struct AVPlayerView: View {
    let url: URL
    @State private var showPIPControls = true

    var body: some View {
        ZStack {
            VideoPlayerContainer(url: url)

            // ✅ 수동 PIP 토글 버튼
            VStack {
                HStack {
                    Spacer()
                    Button(action: togglePIP) {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 22))
                            .padding(10)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 40)
                }
                Spacer()
            }
        }
        .onAppear {
            _ = SilentAudioPlayer.shared  // ✅ 오디오 세션 유지 (경고 제거용)
        }
    }

    // ✅ PIP 진입/종료 수동 토글
    private func togglePIP() {
        if let playerVC = AVPlayerViewControllerManager.shared.playerViewController,
           let player = playerVC.player {

            // ✅ AVPlayerLayer를 따로 생성하여 넘김
            let playerLayer = AVPlayerLayer(player: player)
            let pipController = AVPictureInPictureController(playerLayer: playerLayer)

            if let pipController = pipController {
                if pipController.isPictureInPictureActive {
                    pipController.stopPictureInPicture()
                } else if pipController.isPictureInPicturePossible {
                    pipController.startPictureInPicture()
                }
            }
        }
    }
}

// ✅ AVPlayerViewController 싱글톤 관리
class AVPlayerViewControllerManager {
    static let shared = AVPlayerViewControllerManager()
    var playerViewController: AVPlayerViewController?
}

// ✅ UIKit의 AVPlayerViewController 래핑
struct VideoPlayerContainer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let playerVC = AVPlayerViewController()
        let player = AVPlayer(url: url)
        playerVC.player = player
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.entersFullScreenWhenPlaybackBegins = true
        playerVC.exitsFullScreenWhenPlaybackEnds = true
        player.play()

        // ✅ 싱글톤에 참조 저장
        AVPlayerViewControllerManager.shared.playerViewController = playerVC
        return playerVC
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}