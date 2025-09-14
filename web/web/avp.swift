import SwiftUI
import AVKit
import AVFoundation
// 🎬 **VLC RTSP 지원 추가**
import VLCKitSPM

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

// MARK: - 📡 **RTSP 스트림 매니저 (완전 개선)**
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
        
        // 🚨 **연결 타이머를 더 짧게 조정**
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            DispatchQueue.main.async {
                // VLC 플레이어 상태를 확인하여 더 정확한 상태 설정
                if VLCMediaPlayerManager.shared.isPlaying {
                    self.connectionState = .connected
                } else if VLCMediaPlayerManager.shared.isPlayerReady {
                    self.connectionState = .buffering
                } else {
                    self.connectionState = .failed
                }
                TabPersistenceManager.debugMessages.append("📡 RTSP 연결 상태 업데이트: \(self.connectionState.description)")
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
    
    // 📡 **VLC 전용 상태 처리 강화**
    func handleVLCPlayerState(_ state: VLCMediaPlayerState) {
        DispatchQueue.main.async {
            switch state {
            case .playing:
                self.connectionState = .connected
                TabPersistenceManager.debugMessages.append("📡 VLC RTSP 재생 중")
            case .buffering:
                self.connectionState = .buffering
                TabPersistenceManager.debugMessages.append("📡 VLC RTSP 버퍼링")
            case .error:
                self.connectionState = .failed
                TabPersistenceManager.debugMessages.append("❌ VLC RTSP 오류")
            case .stopped, .ended:
                self.connectionState = .disconnected
                TabPersistenceManager.debugMessages.append("📡 VLC RTSP 중지됨")
            case .opening:
                self.connectionState = .connecting
                TabPersistenceManager.debugMessages.append("📡 VLC RTSP 연결 중")
            case .esAdded:
                // Elementary stream added - 스트림 데이터가 감지됨을 의미
                self.connectionState = .buffering
                TabPersistenceManager.debugMessages.append("📡 VLC Elementary Stream 추가됨 - 버퍼링 상태로 전환")
            case .paused:
                TabPersistenceManager.debugMessages.append("📡 VLC RTSP 일시정지")
            @unknown default:
                TabPersistenceManager.debugMessages.append("📡 VLC 알 수 없는 상태: \(state.rawValue)")
            }
        }
    }
}

// MARK: - 📡 **VLC 미디어 플레이어 매니저 (완전 개선)**
class VLCMediaPlayerManager: ObservableObject {
    static let shared = VLCMediaPlayerManager()
    
    @Published var mediaPlayer: VLCMediaPlayer?
    @Published var isPlaying: Bool = false
    @Published var isPlayerReady: Bool = false
    
    // 🚨 **핵심 추가**: 플레이어 초기화 상태 추적
    @Published var isPlayerInitialized: Bool = false
    private var initializationTimer: Timer?
    
    private init() {
        TabPersistenceManager.debugMessages.append("📡 VLC 미디어 플레이어 매니저 초기화")
    }
    
    // 🚨 **완전 개선된 플레이어 설정**
    func setupPlayer(for url: URL, drawable: UIView) {
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 설정 시작: \(url.absoluteString)")
        
        // 🚨 **1단계**: 기존 플레이어 완전 정리
        cleanupPlayer()
        
        // 🚨 **2단계**: 새 플레이어 생성
        let newPlayer = VLCMediaPlayer()
        mediaPlayer = newPlayer
        
        // 🚨 **3단계**: 델리게이트 먼저 설정 (가장 중요)
        newPlayer.delegate = VLCPlayerDelegate.shared
        
        // 🚨 **4단계**: drawable 설정 최적화
        setupDrawable(newPlayer, drawable: drawable)
        
        // 🚨 **5단계**: 미디어 생성 및 최적화 옵션 설정
        let media = createOptimizedRTSPMedia(for: url)
        newPlayer.media = media
        
        // 🚨 **6단계**: 상태 업데이트
        isPlayerReady = true
        isPlayerInitialized = true
        
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 설정 완료")
        
        // 🚨 **7단계**: 초기화 확인 타이머
        startInitializationTimer()
    }
    
    // 🚨 **drawable 설정 최적화**
    private func setupDrawable(_ player: VLCMediaPlayer, drawable: UIView) {
        // drawable 크기 검증 및 강제 설정
        if drawable.bounds.size == .zero {
            drawable.frame = UIScreen.main.bounds
            TabPersistenceManager.debugMessages.append("📡 VLC drawable 크기 강제 설정: \(drawable.bounds)")
        }
        
        // 배경색 설정 (검은색 배경 보장)
        drawable.backgroundColor = .black
        
        // VLC에 drawable 설정
        player.drawable = drawable
        
        TabPersistenceManager.debugMessages.append("📡 VLC drawable 설정 완료: bounds=\(drawable.bounds)")
    }
    
    // 🚨 **RTSP 최적화 미디어 생성**
    private func createOptimizedRTSPMedia(for url: URL) -> VLCMedia {
        let media = VLCMedia(url: url)
        
        // 📡 **RTSP 스트림 최적화 옵션 - 개선된 설정**
        media.addOption("--network-caching=300")      // 캐싱 시간 단축 (더 빠른 시작)
        media.addOption("--rtsp-tcp")                 // TCP 사용 (안정성)
        media.addOption("--no-rtsp-kasenna")          // Kasenna 호환성 비활성화
        media.addOption("--rtsp-frame-buffer-size=500000") // 프레임 버퍼 크기
        media.addOption("--live-caching=300")         // 라이브 스트림 캐싱
        media.addOption("--clock-jitter=0")           // 클럭 지터 최소화
        media.addOption("--no-audio")                 // 오디오 비활성화 (비디오만 포커스)
        media.addOption("--verbose=2")                // 디버깅 로그
        
        TabPersistenceManager.debugMessages.append("📡 RTSP 최적화 미디어 생성 완료")
        return media
    }
    
    // 🚨 **초기화 확인 타이머**
    private func startInitializationTimer() {
        initializationTimer?.invalidate()
        initializationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            DispatchQueue.main.async {
                if !self.isPlaying {
                    TabPersistenceManager.debugMessages.append("⚠️ VLC 플레이어 3초 후에도 재생되지 않음 - 자동 재시작")
                    self.forceRestart()
                }
            }
        }
    }
    
    // 🚨 **강제 재시작**
    private func forceRestart() {
        guard let currentURL = mediaPlayer?.media?.url else { return }
        
        TabPersistenceManager.debugMessages.append("🔄 VLC 플레이어 강제 재시작 시도")
        
        // 현재 drawable 보존
        let currentDrawable = mediaPlayer?.drawable as? UIView
        
        // 플레이어 재설정
        if let drawable = currentDrawable {
            setupPlayer(for: currentURL, drawable: drawable)
            
            // 재생 시작
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.play()
            }
        }
    }
    
    func play() {
        guard let player = mediaPlayer, isPlayerReady else {
            TabPersistenceManager.debugMessages.append("❌ VLC 플레이어가 준비되지 않아서 재생 불가")
            return
        }
        
        player.play()
        isPlaying = true
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 재생 시작")
        
        // 재생 확인 타이머
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let currentPlayer = self.mediaPlayer {
                TabPersistenceManager.debugMessages.append("📡 VLC 상태 확인: \(currentPlayer.state.rawValue)")
            }
        }
    }
    
    func pause() {
        mediaPlayer?.pause()
        isPlaying = false
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 일시정지")
    }
    
    func stop() {
        initializationTimer?.invalidate()
        mediaPlayer?.stop()
        isPlaying = false
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 정지")
    }
    
    func cleanupPlayer() {
        initializationTimer?.invalidate()
        
        if let player = mediaPlayer {
            player.stop()
            player.delegate = nil
            player.drawable = nil
            mediaPlayer = nil
            isPlaying = false
            isPlayerReady = false
            isPlayerInitialized = false
            TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 정리 완료")
        }
    }
    
    // 🔥 drawable 강제 업데이트 (뷰 레이아웃 변경 시 호출)
    func updateDrawable(_ newDrawable: UIView) {
        guard let player = mediaPlayer, isPlayerReady else { return }
        
        if player.drawable as? UIView !== newDrawable {
            // 배경색 설정
            newDrawable.backgroundColor = .black
            
            player.drawable = newDrawable
            TabPersistenceManager.debugMessages.append("📡 VLC drawable 업데이트: bounds=\(newDrawable.bounds)")
        }
    }
}

// MARK: - 📡 **VLC 플레이어 델리게이트 (상태 감지 강화)**
private class VLCPlayerDelegate: NSObject, VLCMediaPlayerDelegate {
    static let shared = VLCPlayerDelegate()
    
    private override init() {
        super.init()
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 델리게이트 초기화")
    }
    
    // 🚨 **핵심**: 플레이어 상태 변경 감지 (강화)
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { 
            TabPersistenceManager.debugMessages.append("⚠️ VLC 델리게이트: 플레이어 객체 없음")
            return 
        }
        
        let state = player.state
        let stateDesc = stateDescription(state)
        TabPersistenceManager.debugMessages.append("📡 VLC 상태 변경: \(state.rawValue) (\(stateDesc))")
        
        // 메인 큐에서 상태 업데이트
        DispatchQueue.main.async {
            // RTSP 매니저에 상태 전달
            RTSPStreamManager.shared.handleVLCPlayerState(state)
            
            // 플레이어 매니저 상태 업데이트
            let manager = VLCMediaPlayerManager.shared
            manager.isPlaying = (state == .playing)
            
            // 🚨 **특별 처리**: esAdded 상태에서 자동 재생 시도
            if state == .esAdded {
                TabPersistenceManager.debugMessages.append("📡 Elementary Stream 감지 - 재생 시도")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !manager.isPlaying {
                        player.play()
                        TabPersistenceManager.debugMessages.append("📡 자동 재생 시도 (esAdded 후)")
                    }
                }
            }
        }
        
        // 🚨 **오류 상태일 때 추가 정보 로깅 및 재시도**
        if state == .error {
            TabPersistenceManager.debugMessages.append("❌ VLC 오류 상세: \(player.media?.description ?? "미디어 없음")")
            
            // 오류 시 재시도 로직
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let media = player.media, let url = media.url {
                    TabPersistenceManager.debugMessages.append("🔄 VLC 오류 복구 시도")
                    player.media = media  // 미디어 재설정
                    player.play()         // 재생 재시도
                }
            }
        }
    }
    
    // 📡 **상태 설명 헬퍼 - 모든 케이스 포함**
    private func stateDescription(_ state: VLCMediaPlayerState) -> String {
        switch state {
        case .stopped: return "정지"
        case .opening: return "열기"
        case .buffering: return "버퍼링"
        case .ended: return "종료"
        case .error: return "오류"
        case .playing: return "재생"
        case .paused: return "일시정지"
        case .esAdded: return "스트림 감지됨"  // 더 명확한 설명
        @unknown default: return "알 수 없음(\(state.rawValue))"
        }
    }
    
    // 📡 **추가**: 플레이어 시간 변경 감지
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // 현재 재생 시간 정보 (필요시 구현)
        // TabPersistenceManager.debugMessages.append("📡 VLC 시간 변경")
    }
    
    // 📡 **추가**: 미디어 끝남 감지
    func mediaPlayerReachedEnd(_ aNotification: Notification) {
        TabPersistenceManager.debugMessages.append("📡 VLC 미디어 재생 완료")
        DispatchQueue.main.async {
            VLCMediaPlayerManager.shared.isPlaying = false
            RTSPStreamManager.shared.connectionState = .disconnected
        }
    }
    
    // 📡 **추가**: 미디어 변경 감지
    func mediaPlayerMediaChanged(_ aNotification: Notification) {
        TabPersistenceManager.debugMessages.append("📡 VLC 미디어 변경됨")
    }
    
    // 📡 **추가**: 버퍼링 진행 상황
    func mediaPlayerBuffering(_ aNotification: Notification) {
        TabPersistenceManager.debugMessages.append("📡 VLC 버퍼링 진행 중")
        DispatchQueue.main.async {
            RTSPStreamManager.shared.connectionState = .buffering
        }
    }
}

// MARK: - AVPlayerView: 비디오 재생 UI (VLC RTSP 지원 + PIP 관리자 완전 연동)
struct AVPlayerView: View {
    let url: URL // 재생할 비디오 URL
    var showInline: Bool = false // 🎯 인라인 표시 여부 추가
    @State private var showPIPControls = true // PIP 버튼 표시 여부
    @State private var player: AVPlayer?
    @State private var rtspObserver: RTSPPlayerObserver? // KVO 관찰자
    @Environment(\.dismiss) private var dismiss // 닫기 기능 추가
    
    // 🎬 **PIP 관리자 상태 감지**
    @StateObject private var pipManager = PIPManager.shared
    
    // 📡 **RTSP 스트림 관리자**
    @StateObject private var rtspManager = RTSPStreamManager.shared
    
    // 📡 **VLC 플레이어 관리자**
    @StateObject private var vlcManager = VLCMediaPlayerManager.shared
    
    // 📡 **RTSP 스트림 여부 감지**
    private var isRTSPStream: Bool {
        url.scheme?.lowercased() == "rtsp" || url.scheme?.lowercased() == "rtsps"
    }
    
    var body: some View {
        ZStack {
            // 플레이어 컨테이너 - RTSP인지에 따라 VLC 또는 AVPlayer 사용
            if isRTSPStream {
                // 📡 **VLC 플레이어 사용 (RTSP) - 화면 렌더링 문제 해결**
                VLCPlayerView(url: url)
                    .background(Color.black) // 🔥 검은색 배경 강제 설정
                    .clipped() // 🔥 뷰 경계 강제 적용
            } else {
                // 🎬 **AVPlayer 사용 (일반 비디오)**
                if let player = player {
                    AVPlayerControllerView(player: player)
                        .onAppear {
                            setupAVPlayer()
                            
                            // 🎬 **핵심**: AVPlayerViewController 매니저에 PIP 설정
                            AVPlayerViewControllerManager.shared.setupPIPController(for: player)
                            
                            // 자동 재생 시작
                            player.play()
                            TabPersistenceManager.debugMessages.append("🎬 비디오 재생 시작: \(url)")
                        }
                }
            }

            // MARK: - 컨트롤 오버레이 (닫기 버튼 추가)
            VStack {
                HStack {
                    // 🎯 인라인 표시일 때만 닫기 버튼 표시
                    if showInline {
                        Button(action: {
                            // 플레이어 정리
                            if isRTSPStream {
                                vlcManager.stop()
                                rtspManager.stopRTSPStream()
                            } else {
                                player?.pause()
                            }
                            
                            // 현재 탭의 showAVPlayer를 false로 설정
                            NotificationCenter.default.post(name: .init("CloseAVPlayer"), object: nil)
                            TabPersistenceManager.debugMessages.append("🎬 플레이어 닫기")
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .padding(.leading, 20)
                        .padding(.top, 40)
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 12) {
                        // 📡 **RTSP 연결 상태 표시**
                        if isRTSPStream {
                            rtspStatusView
                        }
                        
                        // PIP 시작/중지 버튼 (현재는 일반 비디오만 지원)
                        if !isRTSPStream && !showInline {
                            Button(action: togglePIP) {
                                Image(systemName: pipManager.isPIPActive ? "pip.exit" : "pip.enter")
                                    .font(.system(size: 22))
                                    .padding(10)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())
                            }
                            .disabled(!AVPlayerViewControllerManager.shared.isPIPPossible)
                        }
                        
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
                
                // 📡 **RTSP 정보 오버레이 (하단) - 개선**
                if isRTSPStream {
                    rtspInfoOverlay
                }
            }
            .opacity(showPIPControls ? 1.0 : 0.0)
        }
        .onAppear {
            _ = SilentAudioPlayer.shared // 오디오 세션 유지
            
            if !isRTSPStream {
                setupAVPlayer()
                // 🎬 **핵심**: PIP 관련 알림 옵저버 등록 (일반 비디오만)
                setupPIPNotificationObservers()
            }
            
            // 📡 **RTSP 스트림 시작**
            if isRTSPStream {
                rtspManager.startRTSPStream(url)
                TabPersistenceManager.debugMessages.append("📡 RTSP 스트림 매니저 시작: \(url.absoluteString)")
            }
            
            TabPersistenceManager.debugMessages.append("🎬 AVPlayerView 등장: \(url)")
            
            // 닫기 알림 옵저버 등록
            NotificationCenter.default.addObserver(
                forName: .init("CloseAVPlayer"),
                object: nil,
                queue: .main
            ) { _ in
                if showInline, let tabsBinding = getTabsBinding() {
                    for index in tabsBinding.wrappedValue.indices {
                        if tabsBinding.wrappedValue[index].playerURL == url {
                            tabsBinding.wrappedValue[index].showAVPlayer = false
                            break
                        }
                    }
                }
            }
        }
        .onDisappear {
            if isRTSPStream {
                // VLCPlayerView의 dismantleUIView에서 정리
            } else {
                // PIP가 활성 상태가 아니면 플레이어 정리
                if !pipManager.isPIPActive {
                    cleanupAVPlayer()
                }
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
    
    // MARK: - 📡 **RTSP 상태 표시 뷰 (개선)**
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
            
            // 🚨 **상태별 추가 정보**
            switch rtspManager.connectionState {
            case .connecting, .buffering:
                ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            case .failed:
                Button("재시도") {
                    retryRTSPConnection()
                }
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(6)
            default:
                EmptyView()
            }
        }
    }
    
    // 🚨 **RTSP 재연결 로직**
    private func retryRTSPConnection() {
        TabPersistenceManager.debugMessages.append("🔄 RTSP 재연결 시도")
        
        // VLC 플레이어 재시작
        vlcManager.cleanupPlayer()
        
        // 잠시 후 재시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            rtspManager.startRTSPStream(url)
        }
    }
    
    // MARK: - 📡 **RTSP 정보 오버레이 (개선)**
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
                        
                        // VLC 재생 상태 표시
                        if vlcManager.isPlaying {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                        
                        // 🔥 VLC 플레이어 준비 상태 표시
                        if vlcManager.isPlayerReady {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                        
                        // 🚨 **초기화 상태 표시**
                        if vlcManager.isPlayerInitialized {
                            Image(systemName: "gear.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Text(url.absoluteString)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                // 🚨 **상태별 액션 버튼**
                switch rtspManager.connectionState {
                case .failed:
                    Button("재시도") {
                        retryRTSPConnection()
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    
                case .connected:
                    if !vlcManager.isPlaying {
                        Button("재생") {
                            vlcManager.play()
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    
                default:
                    EmptyView()
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
    
    // MARK: - AVPlayer 설정 (일반 비디오용)
    private func setupAVPlayer() {
        let avPlayer = AVPlayer(url: url)
        self.player = avPlayer
        
        // AVPlayerViewController 매니저에 등록
        let playerVC = AVPlayerViewController()
        playerVC.player = avPlayer
        AVPlayerViewControllerManager.shared.playerViewController = playerVC
        
        TabPersistenceManager.debugMessages.append("🎬 AVPlayer 설정 완료: \(url)")
    }
    
    // MARK: - AVPlayer 정리
    private func cleanupAVPlayer() {
        // KVO 관찰자 제거
        if let observer = rtspObserver,
           let playerItem = player?.currentItem {
            playerItem.removeObserver(observer, forKeyPath: "status")
        }

        if let observer = rtspObserver {
            player?.removeObserver(observer, forKeyPath: "timeControlStatus")
        }

        rtspObserver = nil
        player?.pause()
        player = nil
        AVPlayerViewControllerManager.shared.playerViewController = nil
        TabPersistenceManager.debugMessages.append("🎬 AVPlayer 정리 완료")
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

    // MARK: - PIP 모드 토글 (일반 비디오만)
    private func togglePIP() {
        guard !isRTSPStream else { return } // RTSP는 PIP 미지원
        
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
    
    // 탭 배열 바인딩 가져오기 (헬퍼 함수)
    private func getTabsBinding() -> Binding<[WebTab]>? {
        // 실제 앱에서는 환경 변수나 다른 방법으로 접근
        return nil
    }
}

// MARK: - 📡 **VLC 플레이어 뷰 (RTSP 전용) - 🚨 완전 개선**
struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> VLCContainerView {
        TabPersistenceManager.debugMessages.append("📡 VLCPlayerView makeUIView 시작")
        
        // 🔥 **핵심**: 커스텀 컨테이너 뷰 사용으로 레이아웃 문제 해결
        let containerView = VLCContainerView()
        containerView.backgroundColor = .black
        
        // 🚨 **중요**: 초기 프레임 설정
        containerView.frame = UIScreen.main.bounds
        
        TabPersistenceManager.debugMessages.append("📡 VLC 컨테이너 뷰 생성 완료: \(containerView.frame)")
        
        // 🚨 **즉시 플레이어 설정 (makeUIView에서)**
        DispatchQueue.main.async {
            containerView.setupVLCPlayer(for: self.url)
        }
        
        return containerView
    }
    
    func updateUIView(_ uiView: VLCContainerView, context: Context) {
        TabPersistenceManager.debugMessages.append("📡 VLCPlayerView updateUIView 호출")
        
        // 🚨 **플레이어 설정 확인 및 업데이트**
        if !uiView.isPlayerSetup {
            uiView.setupVLCPlayer(for: self.url)
        }
        
        // 기존 플레이어의 drawable 업데이트
        VLCMediaPlayerManager.shared.updateDrawable(uiView)
    }
    
    static func dismantleUIView(_ uiView: VLCContainerView, coordinator: ()) {
        uiView.cleanup()
        VLCMediaPlayerManager.shared.cleanupPlayer()
        TabPersistenceManager.debugMessages.append("📡 VLCPlayerView 해체 - 플레이어 정리")
    }
}

// MARK: - 📡 **VLC 컨테이너 뷰 (레이아웃 문제 완전 해결)**
class VLCContainerView: UIView {
    var isPlayerSetup: Bool = false
    private var currentURL: URL?
    private var setupRetryCount: Int = 0
    private let maxRetryCount: Int = 3
    
    override init(frame: CGRect) {
        super.init(frame: UIScreen.main.bounds) // 🚨 전체 화면 크기로 초기화
        backgroundColor = .black
        clipsToBounds = true  // 🚨 경계 클리핑 활성화
        TabPersistenceManager.debugMessages.append("📡 VLCContainerView 초기화: \(self.frame)")
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        clipsToBounds = true
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // 🔥 레이아웃이 변경될 때마다 VLC drawable 업데이트
        if isPlayerSetup {
            VLCMediaPlayerManager.shared.updateDrawable(self)
        }
        
        TabPersistenceManager.debugMessages.append("📡 VLC 컨테이너 레이아웃: \(bounds)")
    }
    
    func setupVLCPlayer(for url: URL) {
        guard !isPlayerSetup || currentURL != url else {
            TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 이미 설정됨 또는 동일한 URL")
            return
        }
        
        currentURL = url
        isPlayerSetup = true
        setupRetryCount += 1
        
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 설정 시작 (시도 \(setupRetryCount)/\(maxRetryCount)): \(url.absoluteString)")
        TabPersistenceManager.debugMessages.append("📡 컨테이너 상태: bounds=\(bounds), superview=\(superview != nil)")
        
        // 🚨 **더 안정적인 프레임 설정**
        if bounds.size.width == 0 || bounds.size.height == 0 {
            frame = UIScreen.main.bounds
            TabPersistenceManager.debugMessages.append("📡 VLC 컨테이너 프레임 보정: \(frame)")
        }
        
        // VLC 플레이어 설정
        VLCMediaPlayerManager.shared.setupPlayer(for: url, drawable: self)
        
        // 🚨 **지연된 재생 시작 (더 안정적)**
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            VLCMediaPlayerManager.shared.play()
            TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 지연 재생 시작")
        }
        
        // 🚨 **설정 실패 시 재시도 로직**
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !VLCMediaPlayerManager.shared.isPlaying && self.setupRetryCount < self.maxRetryCount {
                TabPersistenceManager.debugMessages.append("⚠️ VLC 설정 실패 - 재시도 (\(self.setupRetryCount)/\(self.maxRetryCount))")
                self.retrySetup()
            }
        }
    }
    
    // 🚨 **재시도 로직**
    private func retrySetup() {
        guard let url = currentURL, setupRetryCount < maxRetryCount else { return }
        
        isPlayerSetup = false
        VLCMediaPlayerManager.shared.cleanupPlayer()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.setupVLCPlayer(for: url)
        }
    }
    
    func cleanup() {
        isPlayerSetup = false
        currentURL = nil
        setupRetryCount = 0
        TabPersistenceManager.debugMessages.append("📡 VLC 컨테이너 정리")
    }
}

// MARK: - 📡 **RTSP 플레이어 관찰자 (NSObject 기반)**
private class RTSPPlayerObserver: NSObject {
    weak var rtspManager: RTSPStreamManager?
    
    init(rtspManager: RTSPStreamManager) {
        self.rtspManager = rtspManager
        super.init()
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status", let playerItem = object as? AVPlayerItem {
            rtspManager?.handlePlayerItemStatus(playerItem.status)
        } else if keyPath == "timeControlStatus", let player = object as? AVPlayer {
            rtspManager?.handlePlayerTimeControlStatus(player.timeControlStatus)
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
