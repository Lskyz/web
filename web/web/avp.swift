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
    
    // 📡 **VLC 전용 상태 처리 추가**
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
            default:
                break
            }
        }
    }
}

// MARK: - 📡 **VLC 미디어 플레이어 매니저 (올바른 사용법 적용)**
class VLCMediaPlayerManager: ObservableObject {
    static let shared = VLCMediaPlayerManager()
    
    @Published var mediaPlayer: VLCMediaPlayer?
    @Published var isPlaying: Bool = false
    
    private init() {
        TabPersistenceManager.debugMessages.append("📡 VLC 미디어 플레이어 매니저 초기화")
    }
    
    // 🎯 **핵심: 올바른 VLC 초기화 순서**
    func setupPlayer(for url: URL, drawable: Any) {
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 설정 시작: \(url.absoluteString)")
        
        // 기존 플레이어 정리
        cleanupPlayer()
        
        // 🎯 **1단계: VLC 플레이어 생성 (기본 생성자 사용)**
        mediaPlayer = VLCMediaPlayer()
        
        guard let player = mediaPlayer else {
            TabPersistenceManager.debugMessages.append("❌ VLC 플레이어 생성 실패")
            return
        }
        
        TabPersistenceManager.debugMessages.append("✅ VLC 플레이어 생성 성공")
        
        // 🎯 **2단계: drawable 설정 (가장 중요!)**
        player.drawable = drawable
        TabPersistenceManager.debugMessages.append("✅ VLC drawable 설정 완료")
        
        // 🎯 **3단계: 델리게이트 설정**
        player.delegate = VLCPlayerDelegate.shared
        TabPersistenceManager.debugMessages.append("✅ VLC delegate 설정 완료")
        
        // 🎯 **4단계: 미디어 생성 및 옵션 설정**
        let media = VLCMedia(url: url)
        
        // 🎯 **RTSP 최적화 옵션 추가**
        media?.addOption("--rtsp-tcp")  // TCP 강제 사용 (UDP 대신)
        media?.addOption("--network-caching=1000")  // 1초 캐싱
        media?.addOption("--rtsp-timeout=30")  // 30초 타임아웃
        media?.addOption("--no-audio")  // 오디오 비활성화 (필요시 제거)
        
        player.media = media
        TabPersistenceManager.debugMessages.append("✅ VLC 미디어 및 옵션 설정 완료")
        
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 설정 완료, 재생 준비됨")
    }
    
    func play() {
        guard let player = mediaPlayer else {
            TabPersistenceManager.debugMessages.append("❌ VLC 플레이어가 없어서 재생 불가")
            return
        }
        
        player.play()
        isPlaying = true
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 재생 시작")
    }
    
    func pause() {
        guard let player = mediaPlayer else {
            TabPersistenceManager.debugMessages.append("❌ VLC 플레이어가 없어서 일시정지 불가")
            return
        }
        
        player.pause()
        isPlaying = false
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 일시정지")
    }
    
    func stop() {
        guard let player = mediaPlayer else {
            TabPersistenceManager.debugMessages.append("❌ VLC 플레이어가 없어서 정지 불가")
            return
        }
        
        player.stop()
        isPlaying = false
        TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 정지")
    }
    
    func cleanupPlayer() {
        if let player = mediaPlayer {
            player.stop()
            player.delegate = nil
            player.drawable = nil  // drawable도 해제
            mediaPlayer = nil
            isPlaying = false
            TabPersistenceManager.debugMessages.append("📡 VLC 플레이어 정리 완료")
        }
    }
}

// MARK: - 📡 **VLC 플레이어 델리게이트 (올바른 구현)**
private class VLCPlayerDelegate: NSObject, VLCMediaPlayerDelegate {
    static let shared = VLCPlayerDelegate()
    
    private override init() {
        super.init()
    }
    
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        let state = player.state
        TabPersistenceManager.debugMessages.append("📡 VLC 상태 변경: \(state.rawValue)")
        
        // RTSP 매니저에 상태 전달
        RTSPStreamManager.shared.handleVLCPlayerState(state)
        
        // 재생 상태 업데이트
        DispatchQueue.main.async {
            VLCMediaPlayerManager.shared.isPlaying = (state == .playing)
            
            // 상태별 로깅
            switch state {
            case .stopped:
                TabPersistenceManager.debugMessages.append("📡 VLC 정지됨")
            case .opening:
                TabPersistenceManager.debugMessages.append("📡 VLC 연결 중...")
            case .buffering:
                TabPersistenceManager.debugMessages.append("📡 VLC 버퍼링 중...")
            case .playing:
                TabPersistenceManager.debugMessages.append("📡 VLC 재생 중 ✅")
            case .paused:
                TabPersistenceManager.debugMessages.append("📡 VLC 일시정지")
            case .ended:
                TabPersistenceManager.debugMessages.append("📡 VLC 재생 완료")
            case .error:
                TabPersistenceManager.debugMessages.append("❌ VLC 오류 발생")
            @unknown default:
                TabPersistenceManager.debugMessages.append("📡 VLC 알 수 없는 상태: \(state.rawValue)")
            }
        }
    }
    
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // 시간 변경 이벤트 (선택사항)
    }
    
    func mediaPlayerMediaChanged(_ aNotification: Notification) {
        TabPersistenceManager.debugMessages.append("📡 VLC 미디어 변경됨")
    }
}

// MARK: - AVPlayerView: 비디오 재생 UI (VLC RTSP 지원 + PIP 관리자 완전 연동)
struct AVPlayerView: View {
    let url: URL // 재생할 비디오 URL
    @State private var showPIPControls = true // PIP 버튼 표시 여부
    @State private var player: AVPlayer?
    @State private var rtspObserver: RTSPPlayerObserver? // KVO 관찰자
    
    // 🎬 **PIP 관리자 상태 감지**
    @StateObject private var pipManager = PIPManager.shared
    
    // 📡 **RTSP 스트림 관리자**
    @StateObject private var rtspManager = RTSPStreamManager.shared
    
    // 📡 **VLC 플레이어 관리자**
    @StateObject private var vlcManager = VLCMediaPlayerManager.shared
    
    // 📡 **RTSP 스트림 여부 감지**
    private var isRTSPStream: Bool {
        url.scheme?.lowercased() == "rtsp"
    }
    
    var body: some View {
        ZStack {
            // 플레이어 컨테이너 - RTSP인지에 따라 VLC 또는 AVPlayer 사용
            if isRTSPStream {
                VLCPlayerView(url: url)
                    .onAppear {
                        setupRTSPPlayer()
                    }
                    .onDisappear {
                        cleanupRTSPPlayer()
                    }
            } else if let player = player {
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

            // MARK: - PIP 토글 버튼 + RTSP 상태 표시
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        // 📡 **RTSP 연결 상태 표시**
                        if isRTSPStream {
                            rtspStatusView
                        }
                        
                        // PIP 시작/중지 버튼 (현재는 일반 비디오만 지원)
                        if !isRTSPStream {
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
                
                // 📡 **RTSP 정보 오버레이 (하단)**
                if isRTSPStream {
                    rtspInfoOverlay
                }
            }
            .opacity(showPIPControls ? 1.0 : 0.0)
        }
        .onAppear {
            _ = SilentAudioPlayer.shared // 오디오 세션 유지
            
            if isRTSPStream {
                setupRTSPPlayer()
            } else {
                setupAVPlayer()
            }
            
            // 🎬 **핵심**: PIP 관련 알림 옵저버 등록 (일반 비디오만)
            if !isRTSPStream {
                setupPIPNotificationObservers()
            }
            
            // 📡 **RTSP 스트림 시작**
            if isRTSPStream {
                rtspManager.startRTSPStream(url)
            }
            
            TabPersistenceManager.debugMessages.append("🎬 AVPlayerView 등장: \(url)")
        }
        .onDisappear {
            if isRTSPStream {
                cleanupRTSPPlayer()
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
                        
                        // VLC 재생 상태 표시
                        if vlcManager.isPlaying {
                            Image(systemName: "play.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
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
                        vlcManager.play()
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
    
    // MARK: - 📡 **RTSP 플레이어 설정 (올바른 VLC 사용법)**
    private func setupRTSPPlayer() {
        TabPersistenceManager.debugMessages.append("📡 RTSP VLC 플레이어 설정 시작: \(url)")
        // drawable은 VLCPlayerView에서 설정됨
    }
    
    // MARK: - 📡 **RTSP 플레이어 정리**
    private func cleanupRTSPPlayer() {
        vlcManager.cleanupPlayer()
        TabPersistenceManager.debugMessages.append("📡 RTSP VLC 플레이어 정리 완료")
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
}

// MARK: - 📡 **VLC 플레이어 뷰 (올바른 구현 - 핵심!)**
struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> UIView {
        TabPersistenceManager.debugMessages.append("📡 VLC UIView 생성 시작")
        
        let containerView = UIView()
        containerView.backgroundColor = .black
        
        TabPersistenceManager.debugMessages.append("📡 VLC 컨테이너 뷰 생성 완료")
        return containerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        TabPersistenceManager.debugMessages.append("📡 VLC UIView 업데이트 시작")
        
        // 🎯 **핵심: 뷰 크기가 잡힌 후에 VLC 설정**
        if uiView.bounds.size != .zero {
            let vlcManager = VLCMediaPlayerManager.shared
            
            // 🎯 **올바른 VLC 설정: drawable과 함께 전달**
            vlcManager.setupPlayer(for: url, drawable: uiView)
            
            // 🎯 **자동 재생 시작**
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                vlcManager.play()
                TabPersistenceManager.debugMessages.append("📡 VLC 자동 재생 시작")
            }
        } else {
            TabPersistenceManager.debugMessages.append("⚠️ VLC UIView 크기가 0 - 아직 설정하지 않음")
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

// MARK: - RTSP 플레이어 관찰자 (NSObject 기반)
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
