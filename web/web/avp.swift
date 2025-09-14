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

// MARK: - 📡 **RTSP 스트림 매니저**
class RTSPStreamManager: ObservableObject {
    static let shared = RTSPStreamManager()
    
    @Published var isRTSPStream: Bool = false
    @Published var rtspURL: URL?
    @Published var connectionState: RTSPConnectionState = .disconnected
    
    private var connectionTimer: Timer?
    
    private init() {
        TabPersistenceManager.debugMessages.append("📡 RTSP 스트림 매니저 초기화")
    }
    
    enum RTSPConnectionState {
        case disconnected
        case connecting
        case connected
        case failed
        case buffering
        
        var description: String {
            switch self {
            case .disconnected: return "연결 해제됨"
            case .connecting: return "연결 중..."
            case .connected: return "연결됨"
            case .failed: return "연결 실패"
            case .buffering: return "버퍼링 중..."
            }
        }
        
        var color: Color {
            switch self {
            case .disconnected: return .secondary
            case .connecting: return .orange
            case .connected: return .green
            case .failed: return .red
            case .buffering: return .blue
            }
        }
    }
    
    func startRTSPStream(_ url: URL) {
        rtspURL = url
        isRTSPStream = true
        connectionState = .connecting
        TabPersistenceManager.debugMessages.append("📡 RTSP 스트림 시작: \(url.absoluteString)")
        
        // 연결 상태 시뮬레이션 (실제 RTSP 연결 모니터링으로 대체 가능)
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            DispatchQueue.main.async {
                self.connectionState = .connected
                TabPersistenceManager.debugMessages.append("📡 RTSP 스트림 연결 완료")
            }
        }
    }
    
    func stopRTSPStream() {
        connectionTimer?.invalidate()
        connectionTimer = nil
        isRTSPStream = false
        rtspURL = nil
        connectionState = .disconnected
        TabPersistenceManager.debugMessages.append("📡 RTSP 스트림 중지")
    }
    
    func handlePlayerItemStatus(_ status: AVPlayerItem.Status) {
        DispatchQueue.main.async {
            switch status {
            case .readyToPlay:
                self.connectionState = .connected
                TabPersistenceManager.debugMessages.append("📡 RTSP 플레이어 준비 완료")
            case .failed:
                self.connectionState = .failed
                TabPersistenceManager.debugMessages.append("📡 RTSP 플레이어 실패")
            case .unknown:
                self.connectionState = .connecting
            @unknown default:
                self.connectionState = .connecting
            }
        }
    }
    
    func handlePlayerTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        DispatchQueue.main.async {
            switch status {
            case .playing:
                if self.connectionState != .connected {
                    self.connectionState = .connected
                }
            case .waitingToPlayAtSpecifiedRate:
                self.connectionState = .buffering
            case .paused:
                break
            @unknown default:
                break
            }
        }
    }
}

// MARK: - AVPlayerView: 비디오 재생 UI (PIP 관리자 완전 연동 + RTSP 지원)
struct AVPlayerView: View {
    let url: URL // 재생할 비디오 URL
    @State private var showPIPControls = true // PIP 버튼 표시 여부
    @State private var player: AVPlayer?
    
    // 🎬 **PIP 관리자 상태 감지**
    @StateObject private var pipManager = PIPManager.shared
    
    // 📡 **RTSP 스트림 관리자**
    @StateObject private var rtspManager = RTSPStreamManager.shared
    
    // 📡 **RTSP 스트림 여부 감지**
    private var isRTSPStream: Bool {
        url.scheme?.lowercased() == "rtsp"
    }
    
    var body: some View {
        ZStack {
            // AVPlayer 컨테이너
            if let player = player {
                AVPlayerControllerView(player: player)
                    .onAppear {
                        setupPlayer()
                        
                        // 🎬 **핵심**: AVPlayerViewController 매니저에 PIP 설정
                        AVPlayerViewControllerManager.shared.setupPIPController(for: player)
                        
                        // 자동 재생 시작
                        player.play()
                        TabPersistenceManager.debugMessages.append("🎬 비디오 재생 시작: \(url)")
                    }
            }

            // MARK: - PIP 토글 버튼 + RTSP 상태 표시
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        // 📡 **RTSP 연결 상태 표시**
                        if isRTSPStream {
                            rtspStatusView
                        }
                        
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
                
                // 📡 **RTSP 정보 오버레이 (하단)**
                if isRTSPStream {
                    rtspInfoOverlay
                }
            }
            .opacity(showPIPControls ? 1.0 : 0.0)
        }
        .onAppear {
            _ = SilentAudioPlayer.shared // 오디오 세션 유지
            setupPlayer()
            
            // 🎬 **핵심**: PIP 관련 알림 옵저버 등록
            setupPIPNotificationObservers()
            
            // 📡 **RTSP 스트림 시작**
            if isRTSPStream {
                rtspManager.startRTSPStream(url)
            }
            
            TabPersistenceManager.debugMessages.append("🎬 AVPlayerView 등장: \(url)")
        }
        .onDisappear {
            // PIP가 활성 상태가 아니면 플레이어 정리
            if !pipManager.isPIPActive {
                cleanupPlayer()
            }
            
            // 📡 **RTSP 스트림 정리**
            if isRTSPStream {
                rtspManager.stopRTSPStream()
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
    
    // MARK: - 📡 **RTSP 상태 표시 뷰**
    private var rtspStatusView: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14))
                    .foregroundColor(rtspManager.connectionState.color)
                
                Text("RTSP")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(rtspManager.connectionState.color.opacity(0.8))
            .cornerRadius(8)
            
            if rtspManager.connectionState == .connecting || rtspManager.connectionState == .buffering {
                ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
    }
    
    // MARK: - 📡 **RTSP 정보 오버레이**
    private var rtspInfoOverlay: some View {
        VStack {
            Spacer()
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 16))
                            .foregroundColor(rtspManager.connectionState.color)
                        
                        Text(rtspManager.connectionState.description)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    
                    Text(url.absoluteString)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                if rtspManager.connectionState == .failed {
                    Button("재시도") {
                        rtspManager.startRTSPStream(url)
                        player?.play()
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.7))
            .cornerRadius(12)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
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
        
        // 📡 **RTSP 스트림을 위한 추가 설정**
        if isRTSPStream {
            setupRTSPPlayer(avPlayer)
        }
        
        TabPersistenceManager.debugMessages.append("🎬 플레이어 설정 완료: \(url)")
    }
    
    // MARK: - 📡 **RTSP 플레이어 설정**
    private func setupRTSPPlayer(_ avPlayer: AVPlayer) {
        // RTSP 스트림을 위한 설정
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        
        // 플레이어 아이템 상태 관찰
        if let playerItem = avPlayer.currentItem {
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { _ in
                // RTSP 스트림은 일반적으로 끝나지 않으므로 재연결 시도
                TabPersistenceManager.debugMessages.append("📡 RTSP 스트림 종료 감지 - 재연결 시도")
                avPlayer.seek(to: .zero)
                avPlayer.play()
            }
            
            // 플레이어 아이템 상태 관찰
            playerItem.addObserver(self, forKeyPath: "status", options: [.new, .initial], context: nil)
        }
        
        // 플레이어 시간 제어 상태 관찰
        avPlayer.addObserver(self, forKeyPath: "timeControlStatus", options: [.new, .initial], context: nil)
        
        TabPersistenceManager.debugMessages.append("📡 RTSP 플레이어 설정 완료")
    }
    
    // MARK: - KVO 관찰자
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status", let playerItem = object as? AVPlayerItem {
            rtspManager.handlePlayerItemStatus(playerItem.status)
        } else if keyPath == "timeControlStatus", let player = object as? AVPlayer {
            rtspManager.handlePlayerTimeControlStatus(player.timeControlStatus)
        }
    }
    
    // MARK: - 플레이어 정리
    private func cleanupPlayer() {
        // KVO 관찰자 제거
        if let playerItem = player?.currentItem {
            playerItem.removeObserver(self, forKeyPath: "status")
        }
        player?.removeObserver(self, forKeyPath: "timeControlStatus")
        
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
