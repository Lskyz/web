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
    
    // 🎬 **PIP 컨트롤러 관리 추가**
    private var pipController: AVPictureInPictureController?
    
    // 🎬 **PIP 상태 변경 감지를 위한 델리게이트**
    private var pipDelegate: PIPControllerDelegate?
    
    private init() {
        TabPersistenceManager.debugMessages.append("🎬 AVPlayerViewController 매니저 초기화")
    }
    
    // 🎬 **PIP 컨트롤러 설정**
    func setupPIPController(for player: AVPlayer) {
        let playerLayer = AVPlayerLayer(player: player)
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        
        if let pipController = pipController {
            pipDelegate = PIPControllerDelegate()
            pipController.delegate = pipDelegate
            TabPersistenceManager.debugMessages.append("🎬 PIP 컨트롤러 설정 완료")
        } else {
            TabPersistenceManager.debugMessages.append("⚠️ PIP 컨트롤러 생성 실패")
        }
    }
    
    // 🎬 **PIP 시작**
    func startPIP() -> Bool {
        guard let pipController = pipController,
              pipController.isPictureInPicturePossible else {
            TabPersistenceManager.debugMessages.append("⚠️ PIP 시작 불가능")
            return false
        }
        
        pipController.startPictureInPicture()
        TabPersistenceManager.debugMessages.append("🎬 PIP 시작 요청")
        return true
    }
    
    // 🎬 **PIP 중지**
    func stopPIP() {
        guard let pipController = pipController,
              pipController.isPictureInPictureActive else {
            TabPersistenceManager.debugMessages.append("⚠️ PIP 중지 불가능 - 활성 상태 아님")
            return
        }
        
        pipController.stopPictureInPicture()
        TabPersistenceManager.debugMessages.append("🎬 PIP 중지 요청")
    }
    
    // 🎬 **PIP 가능 여부 확인**
    var isPIPPossible: Bool {
        return pipController?.isPictureInPicturePossible ?? false
    }
    
    // 🎬 **PIP 활성 여부 확인**
    var isPIPActive: Bool {
        return pipController?.isPictureInPictureActive ?? false
    }
}

// MARK: - 🎬 **PIP 컨트롤러 델리게이트**
private class PIPControllerDelegate: NSObject, AVPictureInPictureControllerDelegate {
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        TabPersistenceManager.debugMessages.append("🎬 PIP 시작 예정")
    }
    
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            // 🎬 **핵심**: PIPManager에 PIP 시작 알림
            PIPManager.shared.pipDidStart()
            TabPersistenceManager.debugMessages.append("🎬 PIP 시작됨 - PIPManager 알림")
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        TabPersistenceManager.debugMessages.append("❌ PIP 시작 실패: \(error.localizedDescription)")
    }
    
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        TabPersistenceManager.debugMessages.append("🎬 PIP 중지 예정")
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            // 🎬 **핵심**: PIPManager에 PIP 중지 알림
            PIPManager.shared.pipDidStop()
            TabPersistenceManager.debugMessages.append("🎬 PIP 중지됨 - PIPManager 알림")
        }
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎬 PIP 복원 요청")
        completionHandler(true)
    }
}

// MARK: - AVPlayerView: 비디오 재생 UI (PIP 관리자 완전 연동)
struct AVPlayerView: View {
    let url: URL // 재생할 비디오 URL
    @State private var showPIPControls = true // PIP 버튼 표시 여부
    @State private var player: AVPlayer?
    
    // 🎬 **PIP 관리자 상태 감지**
    @StateObject private var pipManager = PIPManager.shared
    
    var body: some View {
        ZStack {
            // AVPlayer 컨테이너
            if let player = player {
                AVPlayerControllerView(player: player)
                    .onAppear {
                        // 🎬 **핵심**: AVPlayerViewController 매니저에 PIP 설정
                        AVPlayerViewControllerManager.shared.setupPIPController(for: player)
                        
                        // 자동 재생 시작
                        player.play()
                        TabPersistenceManager.debugMessages.append("🎬 비디오 재생 시작: \(url)")
                    }
            }

            // MARK: - PIP 토글 버튼
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        // PIP 시작/중지 버튼
                        Button(action: togglePIP) {
                            Image(systemName: pipManager.isPIPActive ? "pip.exit" : "pip.enter")
                                .font(.system(size: 22))
                                .padding(10)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .disabled(!AVPlayerViewControllerManager.shared.isPIPPossible)
                        
                        // PIP 상태 표시
                        if pipManager.isPIPActive {
                            Text("PIP 활성")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        
                        // 현재 PIP 탭 표시 (디버그용)
                        if let pipTab = pipManager.currentPIPTab {
                            Text("탭: \(String(pipTab.uuidString.prefix(4)))")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 40)
                }
                Spacer()
            }
            .opacity(showPIPControls ? 1.0 : 0.0)
        }
        .onAppear {
            _ = SilentAudioPlayer.shared // 오디오 세션 유지
            setupPlayer()
            
            // 🎬 **핵심**: PIP 관련 알림 옵저버 등록
            setupPIPNotificationObservers()
            
            TabPersistenceManager.debugMessages.append("🎬 AVPlayerView 등장: \(url)")
        }
        .onDisappear {
            // PIP가 활성 상태가 아니면 플레이어 정리
            if !pipManager.isPIPActive {
                cleanupPlayer()
            }
            
            // 알림 옵저버 제거
            NotificationCenter.default.removeObserver(self)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showPIPControls.toggle()
            }
        }
    }
    
    // MARK: - 플레이어 설정
    private func setupPlayer() {
        let avPlayer = AVPlayer(url: url)
        self.player = avPlayer
        
        // AVPlayerViewController 매니저에 등록
        let playerVC = AVPlayerViewController()
        playerVC.player = avPlayer
        AVPlayerViewControllerManager.shared.playerViewController = playerVC
        
        TabPersistenceManager.debugMessages.append("🎬 플레이어 설정 완료: \(url)")
    }
    
    // MARK: - 플레이어 정리
    private func cleanupPlayer() {
        player?.pause()
        player = nil
        AVPlayerViewControllerManager.shared.playerViewController = nil
        TabPersistenceManager.debugMessages.append("🎬 플레이어 정리 완료")
    }
    
    // MARK: - 🎬 **PIP 알림 옵저버 설정**
    private func setupPIPNotificationObservers() {
        // PIP 시작 알림 수신
        NotificationCenter.default.addObserver(
            forName: .init("StartPIPForTab"),
            object: nil,
            queue: .main
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let _ = userInfo["tabID"] as? UUID,
                  let _ = userInfo["url"] as? URL else { return }
            
            // 자동으로 PIP 시작
            _ = AVPlayerViewControllerManager.shared.startPIP()
            TabPersistenceManager.debugMessages.append("🎬 자동 PIP 시작 (알림 수신)")
        }
        
        // PIP 중지 알림 수신
        NotificationCenter.default.addObserver(
            forName: .init("StopPIPForTab"),
            object: nil,
            queue: .main
        ) { _ in
            AVPlayerViewControllerManager.shared.stopPIP()
            TabPersistenceManager.debugMessages.append("🎬 자동 PIP 중지 (알림 수신)")
        }
    }

    // MARK: - PIP 모드 토글
    private func togglePIP() {
        if pipManager.isPIPActive {
            // PIP 중지
            AVPlayerViewControllerManager.shared.stopPIP()
            TabPersistenceManager.debugMessages.append("🎬 수동 PIP 중지")
        } else {
            // PIP 시작
            let success = AVPlayerViewControllerManager.shared.startPIP()
            TabPersistenceManager.debugMessages.append("🎬 수동 PIP 시작 \(success ? "성공" : "실패")")
        }
    }
}

// MARK: - AVPlayerControllerView: AVPlayerViewController 래퍼
private struct AVPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let playerVC = AVPlayerViewController()
        playerVC.player = player
        playerVC.showsPlaybackControls = true
        playerVC.allowsPictureInPicturePlayback = true
        
        // 📱 모바일에 최적화된 설정
        playerVC.videoGravity = .resizeAspect
        playerVC.canStartPictureInPictureAutomaticallyFromInline = true
        
        return playerVC
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // 필요한 경우 업데이트 로직 추가
    }
}
