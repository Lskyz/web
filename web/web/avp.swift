import SwiftUI
import AVKit
import AVFoundation

// MARK: - SilentAudioPlayer: 무음 오디오 재생으로 오디오 세션 유지
class SilentAudioPlayer {
    static let shared = SilentAudioPlayer()
    private var player: AVAudioPlayer?

    // MARK: - 초기화: 오디오 세션 설정 및 무음 재생 시작
    private init() {
        configureAudioSession()
        playSilentAudio()
        TabPersistenceManager.debugMessages.append("SilentAudioPlayer 초기화")
    }

    // MARK: - 오디오 세션 설정 (다른 앱과 혼합 재생)
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            TabPersistenceManager.debugMessages.append("오디오 세션 설정 성공")
        } catch {
            TabPersistenceManager.debugMessages.append("오디오 세션 설정 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 무음 오디오 재생 (세션 유지용)
    private func playSilentAudio() {
        if let url = Bundle.main.url(forResource: "web", withExtension: "mp3") {
            do {
                player = try AVAudioPlayer(contentsOf: url)
                player?.volume = 0
                player?.numberOfLoops = -1
                player?.play()
                TabPersistenceManager.debugMessages.append("무음 오디오 재생 시작")
            } catch {
                TabPersistenceManager.debugMessages.append("무음 오디오 재생 실패: \(error.localizedDescription)")
            }
        } else {
            TabPersistenceManager.debugMessages.append("무음 오디오 파일(web.mp3) 없음")
        }
    }
}

// MARK: - AVPlayerViewControllerManager: AVPlayerViewController 싱글톤 관리
class AVPlayerViewControllerManager {
    static let shared = AVPlayerViewControllerManager()
    var playerViewController: AVPlayerViewController?
}


// MARK: - AVPlayerView: 비디오 재생 UI
struct AVPlayerView: View {
    let url: URL // 재생할 비디오 URL
    @State private var showPIPControls = true // PIP 버튼 표시 여부

    var body: some View {
        ZStack {

            // MARK: - PIP 토글 버튼
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
            _ = SilentAudioPlayer.shared // 오디오 세션 유지
            TabPersistenceManager.debugMessages.append("AVPlayerView 등장: \(url)")
        }
    }

    // MARK: - PIP 모드 토글
    private func togglePIP() {
        if let playerVC = AVPlayerViewControllerManager.shared.playerViewController,
           let player = playerVC.player {
            let playerLayer = AVPlayerLayer(player: player)
            let pipController = AVPictureInPictureController(playerLayer: playerLayer)
            if let pipController = pipController {
                if pipController.isPictureInPictureActive {
                    pipController.stopPictureInPicture()
                    TabPersistenceManager.debugMessages.append("PIP 종료")
                } else if pipController.isPictureInPicturePossible {
                    pipController.startPictureInPicture()
                    TabPersistenceManager.debugMessages.append("PIP 시작")
                }
            } else {
                TabPersistenceManager.debugMessages.append("PIP 컨트롤러 생성 실패")
            }
        }
    }
}
