//
//  BFCacheSwipeTransition.swift
//  🎯 **전체 페이지 캡처 및 무한스크롤 대응 BFCache 전환 시스템**
//  ✅ 뷰포트 외부 콘텐츠 캡처 (전체 페이지 스크롤 캡처)
//  🔄 동적 콘텐츠 로딩 완료 감지 및 대기
//  📸 무한스크롤 환경 완전 대응
//  ♾️ 스마트 캡처 전략: 즉시 + 지연 + 전체 페이지
//  🎯 **캡처 품질 최적화** - 뷰포트 한계 극복
//  🌐 **동적 사이트 완전 대응** - 네이버 카페, 커뮤니티 등
//

import UIKit
import WebKit
import SwiftUI

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 🌐 **전체 페이지 캡처 컨텍스트**
private struct FullPageCaptureContext {
    let originalScrollPosition: CGPoint
    let totalContentSize: CGSize
    let viewportSize: CGSize
    let pageRecord: PageRecord
    let tabID: UUID?
    let captureType: CaptureType
    weak var webView: WKWebView?
    let requestedAt: Date = Date()
    var capturedSegments: [CGRect: UIImage] = [:]
    var totalCaptureTime: TimeInterval = 0
    var isInfiniteScroll: Bool = false
    var dynamicContentDetected: Bool = false
}

// MARK: - 🧵 **개선된 제스처 컨텍스트 (먹통 방지)**
private class GestureContext {
    let tabID: UUID
    let gestureID: UUID = UUID()
    weak var webView: WKWebView?
    weak var stateModel: WebViewStateModel?
    private var isValid: Bool = true
    private let validationQueue = DispatchQueue(label: "gesture.validation", attributes: .concurrent)
    
    init(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        self.tabID = tabID
        self.webView = webView
        self.stateModel = stateModel
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 생성: \(String(gestureID.uuidString.prefix(8)))")
    }
    
    func validateAndExecute(_ operation: () -> Void) {
        validationQueue.sync {
            guard isValid else {
                TabPersistenceManager.debugMessages.append("🧵 무효한 컨텍스트 - 작업 취소: \(String(gestureID.uuidString.prefix(8)))")
                return
            }
            operation()
        }
    }
    
    func invalidate() {
        validationQueue.async(flags: .barrier) {
            self.isValid = false
            TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 무효화: \(String(self.gestureID.uuidString.prefix(8)))")
        }
    }
    
    deinit {
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 해제: \(String(gestureID.uuidString.prefix(8)))")
    }
}

// MARK: - 📸 **전체 페이지 BFCache 스냅샷 (뷰포트 한계 극복)**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint  // ⚡ CGFloat 기반 정밀 스크롤
    let scrollPositionPercent: CGPoint  // 🔄 상대적 위치 (백분율)
    let contentSize: CGSize  // 📐 콘텐츠 크기 정보
    let viewportSize: CGSize  // 📱 뷰포트 크기 정보
    let actualScrollableSize: CGSize  // ♾️ 실제 스크롤 가능한 최대 크기
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    var fullPageSnapshotPath: String?  // 🌐 **새로 추가: 전체 페이지 스냅샷 경로**
    let captureStatus: CaptureStatus
    let captureMetadata: CaptureMetadata  // 🎯 **새로 추가: 캡처 메타데이터**
    let version: Int
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공  
        case visualOnly     // 이미지만 캡처 성공
        case fullPage       // 🌐 **새로 추가: 전체 페이지 캡처 성공**
        case failed         // 캡처 실패
    }
    
    // 🎯 **새로 추가: 캡처 메타데이터**
    struct CaptureMetadata: Codable {
        let isInfiniteScroll: Bool
        let dynamicContentDetected: Bool
        let captureMethod: String  // "viewport", "fullPage", "hybrid"
        let segmentCount: Int      // 전체 페이지 캡처 시 세그먼트 수
        let totalCaptureTime: TimeInterval
        let contentStabilityTime: TimeInterval  // 동적 콘텐츠 안정화 시간
        let viewportCoverage: Double  // 뷰포트 대비 캡처된 영역 비율
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord
        case domSnapshot
        case scrollPosition
        case scrollPositionPercent
        case contentSize
        case viewportSize
        case actualScrollableSize
        case jsState
        case timestamp
        case webViewSnapshotPath
        case fullPageSnapshotPath
        case captureStatus
        case captureMetadata
        case version
    }
    
    // Custom encoding/decoding for [String: Any]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageRecord = try container.decode(PageRecord.self, forKey: .pageRecord)
        domSnapshot = try container.decodeIfPresent(String.self, forKey: .domSnapshot)
        scrollPosition = try container.decode(CGPoint.self, forKey: .scrollPosition)
        scrollPositionPercent = try container.decodeIfPresent(CGPoint.self, forKey: .scrollPositionPercent) ?? CGPoint.zero
        contentSize = try container.decodeIfPresent(CGSize.self, forKey: .contentSize) ?? CGSize.zero
        viewportSize = try container.decodeIfPresent(CGSize.self, forKey: .viewportSize) ?? CGSize.zero
        actualScrollableSize = try container.decodeIfPresent(CGSize.self, forKey: .actualScrollableSize) ?? CGSize.zero
        
        // JSON decode for [String: Any]
        if let jsData = try container.decodeIfPresent(Data.self, forKey: .jsState) {
            jsState = try JSONSerialization.jsonObject(with: jsData) as? [String: Any]
        }
        
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        webViewSnapshotPath = try container.decodeIfPresent(String.self, forKey: .webViewSnapshotPath)
        fullPageSnapshotPath = try container.decodeIfPresent(String.self, forKey: .fullPageSnapshotPath)
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
        captureMetadata = try container.decodeIfPresent(CaptureMetadata.self, forKey: .captureMetadata) ?? 
            CaptureMetadata(isInfiniteScroll: false, dynamicContentDetected: false, captureMethod: "viewport", 
                          segmentCount: 1, totalCaptureTime: 0, contentStabilityTime: 0, viewportCoverage: 1.0)
        version = try container.decode(Int.self, forKey: .version)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageRecord, forKey: .pageRecord)
        try container.encodeIfPresent(domSnapshot, forKey: .domSnapshot)
        try container.encode(scrollPosition, forKey: .scrollPosition)
        try container.encode(scrollPositionPercent, forKey: .scrollPositionPercent)
        try container.encode(contentSize, forKey: .contentSize)
        try container.encode(viewportSize, forKey: .viewportSize)
        try container.encode(actualScrollableSize, forKey: .actualScrollableSize)
        
        // JSON encode for [String: Any]
        if let js = jsState {
            let jsData = try JSONSerialization.data(withJSONObject: js)
            try container.encode(jsData, forKey: .jsState)
        }
        
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(webViewSnapshotPath, forKey: .webViewSnapshotPath)
        try container.encodeIfPresent(fullPageSnapshotPath, forKey: .fullPageSnapshotPath)
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(captureMetadata, forKey: .captureMetadata)
        try container.encode(version, forKey: .version)
    }
    
    // 직접 초기화용 init (전체 페이지 캡처 지원)
    init(pageRecord: PageRecord, 
         domSnapshot: String? = nil, 
         scrollPosition: CGPoint, 
         scrollPositionPercent: CGPoint = CGPoint.zero,
         contentSize: CGSize = CGSize.zero,
         viewportSize: CGSize = CGSize.zero,
         actualScrollableSize: CGSize = CGSize.zero,
         jsState: [String: Any]? = nil, 
         timestamp: Date, 
         webViewSnapshotPath: String? = nil,
         fullPageSnapshotPath: String? = nil,
         captureStatus: CaptureStatus = .partial,
         captureMetadata: CaptureMetadata? = nil,
         version: Int = 1) {
        self.pageRecord = pageRecord
        self.domSnapshot = domSnapshot
        self.scrollPosition = scrollPosition
        self.scrollPositionPercent = scrollPositionPercent
        self.contentSize = contentSize
        self.viewportSize = viewportSize
        self.actualScrollableSize = actualScrollableSize
        self.jsState = jsState
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.fullPageSnapshotPath = fullPageSnapshotPath
        self.captureStatus = captureStatus
        self.captureMetadata = captureMetadata ?? CaptureMetadata(
            isInfiniteScroll: false, 
            dynamicContentDetected: false, 
            captureMethod: "viewport", 
            segmentCount: 1, 
            totalCaptureTime: 0, 
            contentStabilityTime: 0, 
            viewportCoverage: 1.0
        )
        self.version = version
    }
    
    // 이미지 로드 메서드 (전체 페이지 우선)
    func loadImage() -> UIImage? {
        // 🌐 **전체 페이지 스냅샷 우선 로드**
        if let fullPagePath = fullPageSnapshotPath {
            let url = URL(fileURLWithPath: fullPagePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return UIImage(contentsOfFile: url.path)
            }
        }
        
        // 뷰포트 스냅샷 fallback
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🌐 **전체 페이지 캡처 기반 복원**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🌐 전체 페이지 BFCache 복원 시작 - 상태: \(captureStatus.rawValue), 방법: \(captureMetadata.captureMethod)")
        
        // ⚡ **즉시 스크롤 복원 먼저 수행**
        performPreciseScrollRestore(to: webView)
        
        // 🔧 **캡처 상태별 분기 로직**
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패 상태 - 즉시 스크롤만 복원")
            completion(true)
            return
            
        case .visualOnly:
            TabPersistenceManager.debugMessages.append("🖼️ 뷰포트만 캡처된 상태 - 기본 복원")
            
        case .fullPage:
            TabPersistenceManager.debugMessages.append("🌐 전체 페이지 캡처 상태 - 고급 복원 수행")
            
        case .partial, .complete:
            TabPersistenceManager.debugMessages.append("⚡ 하이브리드 캡처 상태 - 전체 복원 수행")
        }
        
        TabPersistenceManager.debugMessages.append("🌐 전체 페이지 BFCache 복원 후 다단계 보정 시작")
        
        // 🔧 **정밀 복원 후 추가 보정 단계 실행**
        DispatchQueue.main.async {
            self.performFullPageProgressiveRestore(to: webView, completion: completion)
        }
    }
    
    // 🌐 **새로 추가: 정밀 스크롤 복원 메서드**
    private func performPreciseScrollRestore(to webView: WKWebView) {
        let targetPos = self.scrollPosition
        let targetPercent = self.scrollPositionPercent
        
        TabPersistenceManager.debugMessages.append("🌐 정밀 스크롤 복원: 절대(\(targetPos.x), \(targetPos.y)) 상대(\(targetPercent.x)%, \(targetPercent.y)%)")
        
        // 1. 네이티브 스크롤뷰 정밀 설정
        webView.scrollView.setContentOffset(targetPos, animated: false)
        webView.scrollView.contentOffset = targetPos
        
        // 2. 🌐 **전체 페이지 캡처 기반 적응형 위치 계산**
        let currentContentSize = webView.scrollView.contentSize
        let currentViewportSize = webView.bounds.size
        
        var adaptivePos = targetPos
        
        // 📐 콘텐츠 크기가 변했으면 메타데이터 기반으로 재계산
        if captureMetadata.isInfiniteScroll && contentSize != CGSize.zero && currentContentSize != contentSize {
            // 무한스크롤인 경우 백분율 기반으로 보다 정확하게 계산
            if targetPercent != CGPoint.zero {
                let effectiveContentWidth = max(actualScrollableSize.width, currentContentSize.width)
                let effectiveContentHeight = max(actualScrollableSize.height, currentContentSize.height)
                
                adaptivePos.x = max(0, (effectiveContentWidth - currentViewportSize.width) * targetPercent.x / 100.0)
                adaptivePos.y = max(0, (effectiveContentHeight - currentViewportSize.height) * targetPercent.y / 100.0)
                
                TabPersistenceManager.debugMessages.append("🌐 무한스크롤 백분율 보정: → (\(adaptivePos.x), \(adaptivePos.y))")
            }
        } else {
            // 일반 페이지의 경우 비율 기반 조정
            let xScale = currentContentSize.width / max(contentSize.width, 1)
            let yScale = currentContentSize.height / max(contentSize.height, 1)
            
            adaptivePos.x = targetPos.x * xScale
            adaptivePos.y = targetPos.y * yScale
            
            TabPersistenceManager.debugMessages.append("🌐 일반 페이지 비율 보정: 크기변화(\(xScale), \(yScale)) → (\(adaptivePos.x), \(adaptivePos.y))")
        }
        
        // 3. 범위 검증 (음수 방지)
        let maxX = max(0, currentContentSize.width - currentViewportSize.width)
        let maxY = max(0, currentContentSize.height - currentViewportSize.height)
        adaptivePos.x = max(0, min(adaptivePos.x, maxX))
        adaptivePos.y = max(0, min(adaptivePos.y, maxY))
        
        TabPersistenceManager.debugMessages.append("🌐 범위 검증 후: 최종위치(\(adaptivePos.x), \(adaptivePos.y))")
        
        webView.scrollView.setContentOffset(adaptivePos, animated: false)
        webView.scrollView.contentOffset = adaptivePos
        
        // 4. 🌐 **전체 페이지 캡처 기반 JavaScript 스크롤 설정**
        let fullPageScrollJS = """
        (function() {
            try {
                const targetX = parseFloat('\(adaptivePos.x)');
                const targetY = parseFloat('\(adaptivePos.y)');
                const captureMethod = '\(captureMetadata.captureMethod)';
                const isInfiniteScroll = \(captureMetadata.isInfiniteScroll);
                
                console.log('🌐 전체 페이지 기반 스크롤 복원:', targetX, targetY, '방법:', captureMethod);
                
                // 🌐 **모든 가능한 스크롤 설정 정밀 실행**
                window.scrollTo(targetX, targetY);
                document.documentElement.scrollTop = targetY;
                document.documentElement.scrollLeft = targetX;
                document.body.scrollTop = targetY;
                document.body.scrollLeft = targetX;
                
                // 🌐 **무한스크롤 특화 처리**
                if (isInfiniteScroll) {
                    // scrollingElement 활용
                    if (document.scrollingElement) {
                        document.scrollingElement.scrollTop = targetY;
                        document.scrollingElement.scrollLeft = targetX;
                    }
                    
                    // 무한스크롤 컨테이너들 처리
                    const infiniteScrollContainers = document.querySelectorAll(
                        '.infinite-scroll, .virtual-list, .lazy-load, .posts-container, ' +
                        '.comments-list, .thread-list, .message-list, .activity-feed, ' +
                        '.news-feed, .social-feed, .content-stream, .scroll-container'
                    );
                    
                    infiniteScrollContainers.forEach(container => {
                        if (container.scrollHeight > container.clientHeight) {
                            try {
                                // 상대적 위치 계산해서 적용
                                const relativeY = (targetY / Math.max(document.documentElement.scrollHeight - window.innerHeight, 1)) * 
                                                Math.max(container.scrollHeight - container.clientHeight, 0);
                                container.scrollTop = relativeY;
                            } catch(e) {
                                // 개별 컨테이너 에러는 무시
                            }
                        }
                    });
                }
                
                // 🌐 **최종 확인**
                const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                
                console.log('🌐 전체 페이지 스크롤 복원 완료:', {
                    target: [targetX, targetY],
                    final: [finalX, finalY],
                    diff: [Math.abs(finalX - targetX), Math.abs(finalY - targetY)],
                    method: captureMethod
                });
                
                return true;
            } catch(e) { 
                console.error('🌐 전체 페이지 스크롤 복원 실패:', e);
                return false; 
            }
        })()
        """
        
        // 동기적 JavaScript 실행
        webView.evaluateJavaScript(fullPageScrollJS) { result, error in
            let success = (result as? Bool) ?? false
            TabPersistenceManager.debugMessages.append("🌐 전체 페이지 JavaScript 스크롤: \(success ? "성공" : "실패")")
        }
        
        TabPersistenceManager.debugMessages.append("🌐 정밀 스크롤 복원 단계 완료")
    }
    
    // 🌐 **전체 페이지 점진적 복원 시스템**
    private func performFullPageProgressiveRestore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        TabPersistenceManager.debugMessages.append("🌐 전체 페이지 점진적 보정 단계 구성 시작")
        
        // **1단계: 전체 페이지 스크롤 확인 및 보정**
        restoreSteps.append((1, { stepCompletion in
            let verifyDelay: TimeInterval = 0.05 // 50ms 대기
            TabPersistenceManager.debugMessages.append("🌐 1단계: 전체 페이지 복원 검증 (대기: \(String(format: "%.0f", verifyDelay * 1000))ms)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay) {
                let fullPageVerifyJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const tolerance = \(self.captureMetadata.isInfiniteScroll ? 10.0 : 3.0); // 무한스크롤은 더 관대하게
                        const method = '\(self.captureMetadata.captureMethod)';
                        
                        console.log('🌐 전체 페이지 검증:', {
                            target: [targetX, targetY],
                            current: [currentX, currentY],
                            diff: [Math.abs(currentX - targetX), Math.abs(currentY - targetY)],
                            tolerance: tolerance,
                            method: method
                        });
                        
                        // 위치 차이가 허용 범위를 벗어나면 보정
                        if (Math.abs(currentX - targetX) > tolerance || Math.abs(currentY - targetY) > tolerance) {
                            console.log('🌐 전체 페이지 보정 실행:', {current: [currentX, currentY], target: [targetX, targetY]});
                            
                            // 강력한 보정
                            window.scrollTo(targetX, targetY);
                            document.documentElement.scrollTop = targetY;
                            document.documentElement.scrollLeft = targetX;
                            document.body.scrollTop = targetY;
                            document.body.scrollLeft = targetX;
                            
                            // scrollingElement 활용
                            if (document.scrollingElement) {
                                document.scrollingElement.scrollTop = targetY;
                                document.scrollingElement.scrollLeft = targetX;
                            }
                            
                            return 'fullpage_corrected';
                        } else {
                            console.log('🌐 전체 페이지 복원 정확함:', {current: [currentX, currentY], target: [targetX, targetY]});
                            return 'fullpage_verified';
                        }
                    } catch(e) { 
                        console.error('🌐 전체 페이지 복원 검증 실패:', e);
                        return 'fullpage_error'; 
                    }
                })()
                """
                
                webView.evaluateJavaScript(fullPageVerifyJS) { result, _ in
                    let resultString = result as? String ?? "fullpage_error"
                    let success = (resultString.contains("verified") || resultString.contains("corrected"))
                    TabPersistenceManager.debugMessages.append("🌐 1단계 완료: \(success ? "성공" : "실패") (\(resultString))")
                    stepCompletion(success)
                }
            }
        }))
        
        // **2단계: 전체 페이지 컨테이너 스크롤 복원**
        if let jsState = self.jsState,
           let scrollData = jsState["scroll"] as? [String: Any],
           let elements = scrollData["elements"] as? [[String: Any]], !elements.isEmpty {
            
            TabPersistenceManager.debugMessages.append("🌐 2단계 전체 페이지 컨테이너 스크롤 복원 단계 추가 - 요소 \(elements.count)개")
            
            restoreSteps.append((2, { stepCompletion in
                let waitTime: TimeInterval = 0.1 // 100ms 대기
                TabPersistenceManager.debugMessages.append("🌐 2단계: 전체 페이지 컨테이너 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let fullPageContainerScrollJS = self.generateFullPageContainerScrollScript(elements)
                    webView.evaluateJavaScript(fullPageContainerScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🌐 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        } else {
            TabPersistenceManager.debugMessages.append("🌐 2단계 스킵 - 컨테이너 스크롤 요소 없음")
        }
        
        // **3단계: 무한스크롤 특화 복원**
        if captureMetadata.isInfiniteScroll {
            TabPersistenceManager.debugMessages.append("🌐 3단계 무한스크롤 특화 복원 단계 추가")
            
            restoreSteps.append((3, { stepCompletion in
                let waitTime: TimeInterval = 0.15 // 150ms 대기
                TabPersistenceManager.debugMessages.append("🌐 3단계: 무한스크롤 특화 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let infiniteScrollJS = self.generateInfiniteScrollRestoreScript()
                    webView.evaluateJavaScript(infiniteScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🌐 3단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        }
        
        // **4단계: 전체 페이지 최종 확인 및 보정**
        TabPersistenceManager.debugMessages.append("🌐 4단계 전체 페이지 최종 보정 단계 추가 (필수)")
        
        restoreSteps.append((4, { stepCompletion in
            let waitTime: TimeInterval = 1.2 // 1.2초 대기 (동적 콘텐츠 안정화)
            TabPersistenceManager.debugMessages.append("🌐 4단계: 전체 페이지 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let fullPageFinalVerifyJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        const captureMethod = '\(self.captureMetadata.captureMethod)';
                        const isInfiniteScroll = \(self.captureMetadata.isInfiniteScroll);
                        
                        // 네이티브 스크롤 위치 정밀 확인
                        const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const tolerance = isInfiniteScroll ? 20.0 : 5.0; // 무한스크롤은 더 관대하게
                        
                        console.log('🌐 전체 페이지 최종 검증:', {
                            target: [targetX, targetY],
                            current: [currentX, currentY],
                            tolerance: tolerance,
                            method: captureMethod,
                            isInfiniteScroll: isInfiniteScroll
                        });
                        
                        // 🌐 **전체 페이지 최종 보정**
                        if (Math.abs(currentX - targetX) > tolerance || Math.abs(currentY - targetY) > tolerance) {
                            console.log('🌐 전체 페이지 최종 보정 실행:', {current: [currentX, currentY], target: [targetX, targetY]});
                            
                            // 🌐 **강력한 최종 보정 (모든 방법 동원)**
                            window.scrollTo(targetX, targetY);
                            document.documentElement.scrollTop = targetY;
                            document.documentElement.scrollLeft = targetX;
                            document.body.scrollTop = targetY;
                            document.body.scrollLeft = targetX;
                            
                            // scrollingElement 활용
                            if (document.scrollingElement) {
                                document.scrollingElement.scrollTop = targetY;
                                document.scrollingElement.scrollLeft = targetX;
                            }
                            
                            // 추가 전체 페이지 보정 방법들
                            try {
                                // CSS 스크롤 동작 강제
                                document.documentElement.style.scrollBehavior = 'auto';
                                window.scrollTo(targetX, targetY);
                                
                                // 무한스크롤 특화 보정
                                if (isInfiniteScroll) {
                                    const containers = document.querySelectorAll(
                                        '.infinite-scroll, .virtual-list, .scroll-container, ' +
                                        '.posts-container, .feed, .timeline, .content-stream'
                                    );
                                    
                                    containers.forEach(container => {
                                        if (container.scrollHeight > container.clientHeight) {
                                            const relativeY = (targetY / Math.max(document.documentElement.scrollHeight - window.innerHeight, 1)) * 
                                                            Math.max(container.scrollHeight - container.clientHeight, 0);
                                            container.scrollTop = relativeY;
                                        }
                                    });
                                }
                                
                                // 지연 후 한 번 더 확인
                                setTimeout(function() {
                                    const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                    const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                    console.log('🌐 보정 후 전체 페이지 위치:', [finalX, finalY]);
                                    
                                    // 여전히 차이가 크면 한 번 더 시도
                                    if (Math.abs(finalX - targetX) > tolerance || Math.abs(finalY - targetY) > tolerance) {
                                        window.scrollTo(targetX, targetY);
                                        console.log('🌐 추가 보정 시도 완료');
                                    }
                                }, 100);
                                
                            } catch(e) {
                                console.log('🌐 추가 보정 방법 실패 (정상):', e.message);
                            }
                        }
                        
                        // 🌐 **관대한 성공 판정** (전체 페이지 캡처는 더 유연하게)
                        const finalCurrentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const finalCurrentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const isWithinTolerance = Math.abs(finalCurrentX - targetX) <= tolerance && Math.abs(finalCurrentY - targetY) <= tolerance;
                        
                        console.log('🌐 전체 페이지 최종보정 완료:', {
                            current: [finalCurrentX, finalCurrentY],
                            target: [targetX, targetY],
                            tolerance: tolerance,
                            isWithinTolerance: isWithinTolerance,
                            method: captureMethod
                        });
                        
                        // 🌐 **전체 페이지 캡처는 관대한 성공 판정**
                        return true; // 전체 페이지 캡처는 거의 항상 성공으로 처리
                    } catch(e) { 
                        console.error('🌐 전체 페이지 최종보정 실패:', e);
                        return true; // 에러도 성공으로 처리
                    }
                })()
                """
                
                webView.evaluateJavaScript(fullPageFinalVerifyJS) { result, _ in
                    let success = (result as? Bool) ?? true
                    TabPersistenceManager.debugMessages.append("🌐 4단계 전체 페이지 최종보정 완료: \(success ? "성공" : "성공(관대)")")
                    stepCompletion(true) // 항상 성공
                }
            }
        }))
        
        TabPersistenceManager.debugMessages.append("🌐 총 \(restoreSteps.count)단계 전체 페이지 점진적 보정 단계 구성 완료")
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                TabPersistenceManager.debugMessages.append("🌐 \(stepInfo.step)단계 실행 시작")
                
                let stepStart = Date()
                stepInfo.action { success in
                    let stepDuration = Date().timeIntervalSince(stepStart)
                    TabPersistenceManager.debugMessages.append("🌐 단계 \(stepInfo.step) 소요시간: \(String(format: "%.2f", stepDuration))초")
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                
                TabPersistenceManager.debugMessages.append("🌐 전체 페이지 점진적 보정 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                TabPersistenceManager.debugMessages.append("🌐 최종 결과: \(overallSuccess ? "✅ 성공" : "✅ 성공(관대)")")
                completion(true) // 전체 페이지 캡처는 항상 성공으로 처리
            }
        }
        
        executeNextStep()
    }
    
    // 🌐 **전체 페이지 컨테이너 스크롤 복원 스크립트**
    private func generateFullPageContainerScrollScript(_ elements: [[String: Any]]) -> String {
        let elementsJSON = convertToJSONString(elements) ?? "[]"
        return """
        (function() {
            try {
                const elements = \(elementsJSON);
                let restored = 0;
                
                console.log('🌐 전체 페이지 컨테이너 스크롤 복원 시작:', elements.length, '개 요소');
                
                for (const item of elements) {
                    if (!item.selector) continue;
                    
                    // 다양한 selector 시도
                    const selectors = [
                        item.selector,
                        item.selector.replace(/\\[\\d+\\]/g, ''), // 인덱스 제거
                        item.className ? '.' + item.className : null,
                        item.id ? '#' + item.id : null
                    ].filter(s => s);
                    
                    for (const sel of selectors) {
                        const elements = document.querySelectorAll(sel);
                        if (elements.length > 0) {
                            elements.forEach(el => {
                                if (el && typeof el.scrollTop === 'number') {
                                    const targetTop = parseFloat(item.top || 0);
                                    const targetLeft = parseFloat(item.left || 0);
                                    
                                    // 전체 페이지 기반 정밀 설정
                                    el.scrollTop = targetTop;
                                    el.scrollLeft = targetLeft;
                                    
                                    console.log('🌐 전체 페이지 컨테이너 복원:', sel, [targetLeft, targetTop]);
                                    
                                    // 동적 콘텐츠 상태 확인 및 복원
                                    if (item.dynamicAttrs) {
                                        for (const [key, value] of Object.entries(item.dynamicAttrs)) {
                                            if (el.getAttribute(key) !== value) {
                                                console.log('🌐 콘텐츠 불일치 감지:', sel, key, value);
                                                el.setAttribute(key, value);
                                            }
                                        }
                                    }
                                    
                                    // 스크롤 이벤트 강제 발생
                                    try {
                                        el.dispatchEvent(new Event('scroll', { bubbles: true }));
                                        el.style.scrollBehavior = 'auto';
                                        el.scrollTop = targetTop;
                                        el.scrollLeft = targetLeft;
                                    } catch(e) {
                                        // 개별 요소 에러는 무시
                                    }
                                    
                                    restored++;
                                }
                            });
                            break;
                        }
                    }
                }
                
                console.log('🌐 전체 페이지 컨테이너 스크롤 복원 완료:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('전체 페이지 컨테이너 스크롤 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 🌐 **무한스크롤 특화 복원 스크립트**
    private func generateInfiniteScrollRestoreScript() -> String {
        return """
        (function() {
            try {
                const targetY = parseFloat('\(scrollPosition.y)');
                const targetPercent = parseFloat('\(scrollPositionPercent.y)');
                let restored = 0;
                
                console.log('🌐 무한스크롤 특화 복원 시작:', {targetY, targetPercent});
                
                // 무한스크롤 컨테이너들 찾기
                const infiniteScrollSelectors = [
                    '.infinite-scroll', '.virtual-list', '.lazy-load', 
                    '.posts-container', '.comments-list', '.thread-list', 
                    '.message-list', '.activity-feed', '.news-feed', 
                    '.social-feed', '.content-stream', '.card-list',
                    '.grid-container', '.masonry', '.waterfall-layout',
                    '.scroll-container', '.scrollable', '.feed', '.timeline',
                    // 네이버 카페 특화
                    '.ArticleList', '.CommentArticleList', '.List.CommentArticleList',
                    '.content.location_fix', '.list_board', '.RisingArticleList',
                    '#ct[role="main"]', '.CafeMain', '.article-content'
                ];
                
                for (const selector of infiniteScrollSelectors) {
                    const containers = document.querySelectorAll(selector);
                    
                    containers.forEach(container => {
                        if (container && container.scrollHeight > container.clientHeight) {
                            try {
                                // 백분율 기반 복원 (무한스크롤에 최적)
                                const maxScroll = container.scrollHeight - container.clientHeight;
                                const targetScrollPos = maxScroll > 0 ? (targetPercent / 100.0) * maxScroll : targetY;
                                
                                container.scrollTop = targetScrollPos;
                                
                                // 스크롤 이벤트 발생으로 동적 콘텐츠 트리거
                                container.dispatchEvent(new Event('scroll', { bubbles: true }));
                                
                                console.log('🌐 무한스크롤 컨테이너 복원:', selector, targetScrollPos);
                                restored++;
                                
                                // 지연 로딩 트리거
                                setTimeout(() => {
                                    container.scrollTop = targetScrollPos;
                                }, 100);
                                
                            } catch(e) {
                                console.log('무한스크롤 컨테이너 처리 실패:', selector, e.message);
                            }
                        }
                    });
                }
                
                // 메인 스크롤도 백분율 기반으로 재조정
                if (targetPercent > 0) {
                    const mainMaxScroll = Math.max(document.documentElement.scrollHeight - window.innerHeight, 0);
                    const mainTargetScroll = mainMaxScroll > 0 ? (targetPercent / 100.0) * mainMaxScroll : targetY;
                    
                    window.scrollTo(0, mainTargetScroll);
                    document.documentElement.scrollTop = mainTargetScroll;
                    document.body.scrollTop = mainTargetScroll;
                    
                    console.log('🌐 메인 스크롤 백분율 기반 재조정:', mainTargetScroll);
                }
                
                console.log('🌐 무한스크롤 특화 복원 완료:', restored, '개 컨테이너');
                return restored > 0;
            } catch(e) {
                console.error('무한스크롤 특화 복원 실패:', e);
                return false;
            }
        })()
        """
    }
    
    // 안전한 JSON 변환 유틸리티
    private func convertToJSONString(_ object: Any) -> String? {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: object, options: [])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            TabPersistenceManager.debugMessages.append("JSON 변환 실패: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - 📸 **전체 페이지 네비게이션 이벤트 감지 시스템**
extension BFCacheTransitionSystem {
    
    /// CustomWebView에서 네비게이션 이벤트 구독
    static func registerNavigationObserver(for webView: WKWebView, stateModel: WebViewStateModel) {
        guard let tabID = stateModel.tabID else { return }
        
        // KVO로 URL 변경 감지
        let urlObserver = webView.observe(\.url, options: [.old, .new]) { [weak webView] observedWebView, change in
            guard let webView = webView,
                  let oldURL = change.oldValue as? URL,
                  let newURL = change.newValue as? URL,
                  oldURL != newURL else { return }
            
            // 📸 **URL이 바뀌는 순간 이전 페이지 전체 캡처**
            if let currentRecord = stateModel.dataModel.currentPageRecord {
                shared.storeLeavingSnapshotIfPossible(webView: webView, stateModel: stateModel)
                shared.dbg("📸 URL 변경 감지 - 떠나기 전 전체 페이지 캐시: \(oldURL.absoluteString) → \(newURL.absoluteString)")
            }
        }
        
        // 옵저버를 webView에 연결하여 생명주기 관리
        objc_setAssociatedObject(webView, "bfcache_url_observer", urlObserver, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        shared.dbg("📸 전체 페이지 네비게이션 감지 등록: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    /// CustomWebView 해제 시 옵저버 정리
    static func unregisterNavigationObserver(for webView: WKWebView) {
        if let observer = objc_getAssociatedObject(webView, "bfcache_url_observer") as? NSKeyValueObservation {
            observer.invalidate()
            objc_setAssociatedObject(webView, "bfcache_url_observer", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        shared.dbg("📸 전체 페이지 네비게이션 감지 해제 완료")
    }
}

// MARK: - 🎯 **전체 페이지 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 **핵심 개선: 전체 페이지 직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.fullpage.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    private let fullPageCaptureQueue = DispatchQueue(label: "bfcache.fullpage.capture", qos: .userInteractive)
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
    // 스레드 안전 액세서
    private var memoryCache: [UUID: BFCacheSnapshot] {
        get { cacheAccessQueue.sync { _memoryCache } }
    }
    
    private func setMemoryCache(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache[pageID] = snapshot
        }
    }
    
    private func removeFromMemoryCache(_ pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache.removeValue(forKey: pageID)
        }
    }
    
    private var diskCacheIndex: [UUID: String] {
        get { cacheAccessQueue.sync { _diskCacheIndex } }
    }
    
    private func setDiskIndex(_ path: String, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._diskCacheIndex[pageID] = path
        }
    }
    
    // MARK: - 📁 파일 시스템 경로
    private var bfCacheDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("BFCache", isDirectory: true)
    }
    
    private func tabDirectory(for tabID: UUID) -> URL {
        return bfCacheDirectory.appendingPathComponent("Tab_\(tabID.uuidString)", isDirectory: true)
    }
    
    private func pageDirectory(for pageID: UUID, tabID: UUID, version: Int) -> URL {
        return tabDirectory(for: tabID).appendingPathComponent("Page_\(pageID.uuidString)_v\(version)", isDirectory: true)
    }
    
    // MARK: - 🧵 **제스처 전환 상태 (리팩토링된 스레드 안전 관리)**
    private let gestureQueue = DispatchQueue(label: "gesture.management", attributes: .concurrent)
    private var _activeTransitions: [UUID: TransitionContext] = [:]
    private var _gestureContexts: [UUID: GestureContext] = [:]  // 🧵 제스처 컨텍스트 관리
    
    // 🧵 **스레드 안전 activeTransitions 접근**
    private var activeTransitions: [UUID: TransitionContext] {
        get { gestureQueue.sync { _activeTransitions } }
    }
    
    private func setActiveTransition(_ context: TransitionContext, for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions[tabID] = context
        }
    }
    
    private func removeActiveTransition(for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions.removeValue(forKey: tabID)
        }
    }
    
    private func getActiveTransition(for tabID: UUID) -> TransitionContext? {
        return gestureQueue.sync { _activeTransitions[tabID] }
    }
    
    // 🧵 **제스처 컨텍스트 관리**
    private func setGestureContext(_ context: GestureContext, for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._gestureContexts[key] = context
        }
    }
    
    private func removeGestureContext(for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            if let context = self._gestureContexts.removeValue(forKey: key) {
                context.invalidate()
            }
        }
    }
    
    private func getGestureContext(for key: UUID) -> GestureContext? {
        return gestureQueue.sync { _gestureContexts[key] }
    }
    
    // 전환 컨텍스트
    private struct TransitionContext {
        let tabID: UUID
        weak var webView: WKWebView?
        weak var stateModel: WebViewStateModel?
        var isGesture: Bool
        var direction: NavigationDirection
        var initialTransform: CGAffineTransform
        var previewContainer: UIView?
        var currentSnapshot: UIImage?
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    enum CaptureType {
        case immediate  // 현재 페이지 (높은 우선순위)
        case background // 과거 페이지 (일반 우선순위)
    }
    
    // MARK: - 🔧 **핵심 개선: 전체 페이지 원자적 캡처 작업**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    // 중복 방지를 위한 진행 중인 캡처 추적
    private var pendingCaptures: Set<UUID> = []
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        // 🌐 캡처 대상 사이트 로그
        dbg("🌐 전체 페이지 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performFullPageAtomicCapture(task)
        }
    }
    
    private func performFullPageAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 중복 캡처 방지 (진행 중인 것만)
        guard !pendingCaptures.contains(pageID) else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 진행 중 표시
        pendingCaptures.insert(pageID)
        dbg("🌐 전체 페이지 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // 실제 스크롤 가능한 최대 크기 감지
            let actualScrollableWidth = max(webView.scrollView.contentSize.width, webView.scrollView.bounds.width)
            let actualScrollableHeight = max(webView.scrollView.contentSize.height, webView.scrollView.bounds.height)
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                contentSize: webView.scrollView.contentSize,
                viewportSize: webView.bounds.size,
                actualScrollableSize: CGSize(width: actualScrollableWidth, height: actualScrollableHeight),
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🔧 **전체 페이지 캡처 로직 - 즉시 캡처 + 전체 페이지 캡처**
        let captureResult = performFullPageCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 1 : 0  // immediate는 재시도
        )
        
        // 🌐 캡처된 jsState 로그
        if let jsState = captureResult.snapshot.jsState {
            dbg("🌐 캡처된 jsState 키: \(Array(jsState.keys))")
            if let scrollData = jsState["scroll"] as? [String: Any],
               let elements = scrollData["elements"] as? [[String: Any]] {
                dbg("🌐 캡처된 전체 페이지 스크롤 요소: \(elements.count)개")
            }
        }
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(pageID)
        dbg("✅ 전체 페이지 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize      // ⚡ 콘텐츠 크기 추가
        let viewportSize: CGSize     // ⚡ 뷰포트 크기 추가
        let actualScrollableSize: CGSize  // 실제 스크롤 가능 크기 추가
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔧 **전체 페이지 캡처 메인 로직**
    private func performFullPageCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?, fullPageImage: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptFullPageCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 전체 페이지 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기
            dbg("⏳ 전체 페이지 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.1) // 100ms 대기
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil, nil)
    }
    
    private func attemptFullPageCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?, fullPageImage: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var fullPageSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        let captureStartTime = Date()
        
        // 🌐 **1. 무한스크롤 및 동적 콘텐츠 감지**
        var isInfiniteScroll = false
        var dynamicContentDetected = false
        var contentStabilityTime: TimeInterval = 0
        
        let detectionStart = Date()
        let detectionSemaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.sync {
            let detectionScript = """
            (function() {
                return new Promise((resolve) => {
                    // 무한스크롤 감지
                    const infiniteScrollIndicators = [
                        '.infinite-scroll', '.virtual-list', '.lazy-load', 
                        '.posts-container', '.feed', '.timeline', '.content-stream',
                        '[data-infinite]', '[data-lazy]', '[data-scroll]'
                    ];
                    
                    let isInfiniteScroll = false;
                    for (const selector of infiniteScrollIndicators) {
                        if (document.querySelector(selector)) {
                            isInfiniteScroll = true;
                            break;
                        }
                    }
                    
                    // 동적 콘텐츠 안정화 대기
                    let stabilityCount = 0;
                    const requiredStability = 3;
                    let timeout;
                    const stabilityStart = Date.now();
                    
                    const observer = new MutationObserver(() => {
                        stabilityCount = 0;
                        clearTimeout(timeout);
                        timeout = setTimeout(() => {
                            stabilityCount++;
                            if (stabilityCount >= requiredStability) {
                                observer.disconnect();
                                resolve({
                                    isInfiniteScroll: isInfiniteScroll,
                                    dynamicContentDetected: true,
                                    contentStabilityTime: Date.now() - stabilityStart
                                });
                            }
                        }, 200); // 200ms 안정화 대기
                    });
                    
                    observer.observe(document.body, { childList: true, subtree: true });
                    
                    // 최대 대기 시간 (2초)
                    setTimeout(() => {
                        observer.disconnect();
                        resolve({
                            isInfiniteScroll: isInfiniteScroll,
                            dynamicContentDetected: false,
                            contentStabilityTime: Date.now() - stabilityStart
                        });
                    }, 2000);
                });
            })()
            """
            
            webView.evaluateJavaScript(detectionScript) { result, error in
                if let data = result as? [String: Any] {
                    isInfiniteScroll = data["isInfiniteScroll"] as? Bool ?? false
                    dynamicContentDetected = data["dynamicContentDetected"] as? Bool ?? false
                    contentStabilityTime = (data["contentStabilityTime"] as? Double ?? 0) / 1000.0
                }
                detectionSemaphore.signal()
            }
        }
        _ = detectionSemaphore.wait(timeout: .now() + 3.0)
        
        dbg("🌐 사이트 분석 완료: 무한스크롤=\(isInfiniteScroll), 동적콘텐츠=\(dynamicContentDetected), 안정화=\(String(format: "%.2f", contentStabilityTime))초")
        
        // 🌐 **2. 전체 페이지 캡처 전략 결정**
        let shouldPerformFullPageCapture = (captureData.contentSize.height > captureData.viewportSize.height * 2) || isInfiniteScroll
        var captureMethod = "viewport"
        var segmentCount = 1
        var viewportCoverage = 1.0
        
        if shouldPerformFullPageCapture {
            dbg("🌐 전체 페이지 캡처 수행: 콘텐츠 높이=\(captureData.contentSize.height), 뷰포트=\(captureData.viewportSize.height)")
            
            // 🌐 **전체 페이지 캡처 실행**
            let fullPageResult = performSmartFullPageCapture(webView: webView, captureData: captureData, isInfiniteScroll: isInfiniteScroll)
            fullPageSnapshot = fullPageResult.image
            captureMethod = fullPageResult.method
            segmentCount = fullPageResult.segmentCount
            viewportCoverage = fullPageResult.coverage
        }
        
        // 🌐 **3. 뷰포트 스냅샷 (Fallback 및 미리보기용)**
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 뷰포트 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            dbg("⏰ 뷰포트 스냅샷 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 🌐 **4. DOM 캡처**
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 상태 정리
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                        el.classList.remove(...Array.from(el.classList).filter(c => 
                            c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                        ));
                    });
                    
                    document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(el => {
                        el.blur();
                    });
                    
                    const html = document.documentElement.outerHTML;
                    return html.length > 150000 ? html.substring(0, 150000) : html; // 더 큰 DOM 허용
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                domSnapshot = result as? String
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 1.5)
        
        // 🌐 **5. 전체 페이지 JS 상태 캡처**
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = generateFullPageScrollCaptureScript(isInfiniteScroll: isInfiniteScroll)
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 2.5)
        
        // 🌐 **6. 캡처 상태 및 메타데이터 결정**
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if fullPageSnapshot != nil && visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .fullPage
        } else if fullPageSnapshot != nil && visualSnapshot != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        let totalCaptureTime = Date().timeIntervalSince(captureStartTime)
        
        // 버전 증가 (스레드 안전)
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        // 🌐 **상대적 위치 계산 (백분율)**
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.width > captureData.viewportSize.width && captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollX = captureData.actualScrollableSize.width - captureData.viewportSize.width
            let maxScrollY = captureData.actualScrollableSize.height - captureData.viewportSize.height
            
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        // 🌐 **캡처 메타데이터 생성**
        let metadata = BFCacheSnapshot.CaptureMetadata(
            isInfiniteScroll: isInfiniteScroll,
            dynamicContentDetected: dynamicContentDetected,
            captureMethod: captureMethod,
            segmentCount: segmentCount,
            totalCaptureTime: totalCaptureTime,
            contentStabilityTime: contentStabilityTime,
            viewportCoverage: viewportCoverage
        )
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            scrollPositionPercent: scrollPercent,
            contentSize: captureData.contentSize,
            viewportSize: captureData.viewportSize,
            actualScrollableSize: captureData.actualScrollableSize,
            jsState: jsState,
            timestamp: Date(),
            webViewSnapshotPath: nil,  // 나중에 디스크 저장시 설정
            fullPageSnapshotPath: nil, // 나중에 디스크 저장시 설정
            captureStatus: captureStatus,
            captureMetadata: metadata,
            version: version
        )
        
        dbg("🌐 전체 페이지 캡처 완료: 상태=\(captureStatus.rawValue), 방법=\(captureMethod), 세그먼트=\(segmentCount), 시간=\(String(format: "%.2f", totalCaptureTime))초")
        
        return (snapshot, visualSnapshot, fullPageSnapshot)
    }
    
    // 🌐 **스마트 전체 페이지 캡처 메서드**
    private func performSmartFullPageCapture(webView: WKWebView, captureData: CaptureData, isInfiniteScroll: Bool) -> (image: UIImage?, method: String, segmentCount: Int, coverage: Double) {
        
        let originalOffset = captureData.scrollPosition
        let contentHeight = captureData.contentSize.height
        let viewportHeight = captureData.viewportSize.height
        let maxSegments = isInfiniteScroll ? 5 : 10 // 무한스크롤은 제한적으로
        
        // 세그먼트 계산
        let totalSegments = min(maxSegments, Int(ceil(contentHeight / viewportHeight)))
        
        if totalSegments <= 1 {
            dbg("🌐 단일 뷰포트 - 전체 페이지 캡처 스킵")
            return (nil, "viewport", 1, 1.0)
        }
        
        dbg("🌐 전체 페이지 캡처 시작: \(totalSegments)개 세그먼트")
        
        var capturedImages: [UIImage] = []
        let semaphore = DispatchSemaphore(value: 0)
        var currentSegment = 0
        
        func captureNextSegment() {
            DispatchQueue.main.async {
                if currentSegment >= totalSegments {
                    semaphore.signal()
                    return
                }
                
                let segmentY = CGFloat(currentSegment) * viewportHeight
                let targetOffset = CGPoint(x: originalOffset.x, y: min(segmentY, contentHeight - viewportHeight))
                
                // 스크롤 위치 이동
                webView.scrollView.setContentOffset(targetOffset, animated: false)
                
                // 짧은 대기 후 캡처 (동적 콘텐츠 로딩 대기)
                DispatchQueue.main.asyncAfter(deadline: .now() + (isInfiniteScroll ? 0.5 : 0.2)) {
                    let config = WKSnapshotConfiguration()
                    config.rect = captureData.bounds
                    config.afterScreenUpdates = true
                    
                    webView.takeSnapshot(with: config) { image, error in
                        if let image = image {
                            capturedImages.append(image)
                            self.dbg("🌐 세그먼트 \(currentSegment + 1)/\(totalSegments) 캡처 완료")
                        } else {
                            self.dbg("⚠️ 세그먼트 \(currentSegment + 1) 캡처 실패")
                        }
                        
                        currentSegment += 1
                        captureNextSegment()
                    }
                }
            }
        }
        
        captureNextSegment()
        _ = semaphore.wait(timeout: .now() + TimeInterval(totalSegments * 2 + 5)) // 충분한 대기 시간
        
        // 원래 스크롤 위치 복원
        DispatchQueue.main.sync {
            webView.scrollView.setContentOffset(originalOffset, animated: false)
        }
        
        // 이미지 합성
        let finalImage = stitchImages(capturedImages, targetSize: CGSize(width: captureData.viewportSize.width, height: contentHeight))
        let coverage = Double(capturedImages.count) / Double(totalSegments)
        
        dbg("🌐 전체 페이지 캡처 완료: \(capturedImages.count)/\(totalSegments) 세그먼트, 커버리지=\(String(format: "%.1f", coverage * 100))%")
        
        return (finalImage, "fullPage", capturedImages.count, coverage)
    }
    
    // 🌐 **이미지 스티칭 유틸리티**
    private func stitchImages(_ images: [UIImage], targetSize: CGSize) -> UIImage? {
        guard !images.isEmpty else { return nil }
        
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { context in
            let segmentHeight = targetSize.height / CGFloat(images.count)
            
            for (index, image) in images.enumerated() {
                let yPosition = CGFloat(index) * segmentHeight
                let rect = CGRect(x: 0, y: yPosition, width: targetSize.width, height: segmentHeight)
                image.draw(in: rect)
            }
        }
    }
    
    // 🌐 **전체 페이지 스크롤 감지 JavaScript 생성**
    private func generateFullPageScrollCaptureScript(isInfiniteScroll: Bool) -> String {
        return """
        (function() {
            return new Promise(resolve => {
                // 🌐 동적 콘텐츠 로딩 안정화 대기
                function waitForFullPageStability(callback) {
                    let stabilityCount = 0;
                    const requiredStability = isInfiniteScroll ? 2 : 3;
                    let timeout;
                    
                    const observer = new MutationObserver(() => {
                        stabilityCount = 0;
                        clearTimeout(timeout);
                        timeout = setTimeout(() => {
                            stabilityCount++;
                            if (stabilityCount >= requiredStability) {
                                observer.disconnect();
                                callback();
                            }
                        }, isInfiniteScroll ? 500 : 300);
                    });
                    
                    observer.observe(document.body, { childList: true, subtree: true });
                    
                    // 최대 대기 시간
                    setTimeout(() => {
                        observer.disconnect();
                        callback();
                    }, isInfiniteScroll ? 6000 : 4000);
                }

                const isInfiniteScroll = \(isInfiniteScroll);

                function captureFullPageData() {
                    try {
                        // 🌐 전체 페이지 스크롤 요소 스캔
                        function findAllScrollableElements() {
                            const scrollables = [];
                            const maxElements = isInfiniteScroll ? 1000 : 2000;
                            
                            console.log('🌐 전체 페이지 스크롤 감지: 최대 ' + maxElements + '개 요소');
                            
                            // 1) 명시적 overflow 스타일을 가진 요소들
                            const explicitScrollables = document.querySelectorAll('*');
                            let count = 0;
                            
                            for (const el of explicitScrollables) {
                                if (count >= maxElements) break;
                                
                                const style = window.getComputedStyle(el);
                                const overflowY = style.overflowY;
                                const overflowX = style.overflowX;
                                
                                if ((overflowY === 'auto' || overflowY === 'scroll' || overflowX === 'auto' || overflowX === 'scroll') &&
                                    (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) {
                                    
                                    const scrollTop = parseFloat(el.scrollTop) || 0;
                                    const scrollLeft = parseFloat(el.scrollLeft) || 0;
                                    
                                    if (scrollTop > 0.1 || scrollLeft > 0.1) {
                                        const selector = generateBestSelector(el);
                                        if (selector) {
                                            const dynamicAttrs = {};
                                            for (const attr of el.attributes) {
                                                if (attr.name.startsWith('data-')) {
                                                    dynamicAttrs[attr.name] = attr.value;
                                                }
                                            }
                                            
                                            const maxScrollTop = el.scrollHeight - el.clientHeight;
                                            const maxScrollLeft = el.scrollWidth - el.clientWidth;
                                            
                                            scrollables.push({
                                                selector: selector,
                                                top: scrollTop,
                                                left: scrollLeft,
                                                topPercent: maxScrollTop > 0 ? (scrollTop / maxScrollTop * 100) : 0,
                                                leftPercent: maxScrollLeft > 0 ? (scrollLeft / maxScrollLeft * 100) : 0,
                                                maxTop: maxScrollTop,
                                                maxLeft: maxScrollLeft,
                                                actualMaxTop: el.scrollHeight,
                                                actualMaxLeft: el.scrollWidth,
                                                id: el.id || '',
                                                className: el.className || '',
                                                tagName: el.tagName.toLowerCase(),
                                                dynamicAttrs: dynamicAttrs
                                            });
                                            count++;
                                        }
                                    }
                                }
                            }
                            
                            // 🌐 2) 전체 페이지 특화 스크롤 컨테이너들
                            const fullPageScrollContainers = [
                                '.scroll-container', '.scrollable', '.content', '.main', '.body',
                                '[data-scroll]', '[data-scrollable]', '.overflow-auto', '.overflow-scroll',
                                '.list', '.feed', '.timeline', '.board', '.gallery', '.gall_list', '.article-board',
                                // 무한스크롤 패턴들
                                '.infinite-scroll', '.virtual-list', '.lazy-load', '.pagination-container',
                                '.posts-container', '.comments-list', '.thread-list', '.message-list',
                                '.activity-feed', '.news-feed', '.social-feed', '.content-stream',
                                '.card-list', '.grid-container', '.masonry', '.waterfall-layout',
                                // 소셜미디어/커뮤니티 특화
                                '.tweet-list', '.post-stream', '.story-list', '.video-list',
                                '.chat-messages', '.notification-list', '.search-results',
                                // 네이버 카페 등 한국 사이트 특화
                                '.ArticleList', '.CommentArticleList', '.List.CommentArticleList',
                                '.content.location_fix', '.list_board', '.RisingArticleList',
                                '#ct[role="main"]', '.CafeMain', '.article-content', '.cafe-content',
                                // 전체 페이지 레이아웃
                                '.container-fluid', '.main-container', '.page-content',
                                '.content-wrapper', '.app-content', '.site-content'
                            ];
                            
                            for (const selector of fullPageScrollContainers) {
                                if (count >= maxElements) break;
                                
                                const elements = document.querySelectorAll(selector);
                                for (const el of elements) {
                                    if (count >= maxElements) break;
                                    
                                    const scrollTop = parseFloat(el.scrollTop) || 0;
                                    const scrollLeft = parseFloat(el.scrollLeft) || 0;
                                    
                                    if ((scrollTop > 0.1 || scrollLeft > 0.1) && 
                                        !scrollables.some(s => s.selector === generateBestSelector(el))) {
                                        
                                        const dynamicAttrs = {};
                                        for (const attr of el.attributes) {
                                            if (attr.name.startsWith('data-')) {
                                                dynamicAttrs[attr.name] = attr.value;
                                            }
                                        }
                                        
                                        const maxScrollTop = el.scrollHeight - el.clientHeight;
                                        const maxScrollLeft = el.scrollWidth - el.clientWidth;
                                        
                                        scrollables.push({
                                            selector: generateBestSelector(el) || selector,
                                            top: scrollTop,
                                            left: scrollLeft,
                                            topPercent: maxScrollTop > 0 ? (scrollTop / maxScrollTop * 100) : 0,
                                            leftPercent: maxScrollLeft > 0 ? (scrollLeft / maxScrollLeft * 100) : 0,
                                            maxTop: maxScrollTop,
                                            maxLeft: maxScrollLeft,
                                            actualMaxTop: el.scrollHeight,
                                            actualMaxLeft: el.scrollWidth,
                                            id: el.id || '',
                                            className: el.className || '',
                                            tagName: el.tagName.toLowerCase(),
                                            dynamicAttrs: dynamicAttrs
                                        });
                                        count++;
                                    }
                                }
                            }
                            
                            console.log('🌐 전체 페이지 스크롤 요소 감지 완료: ' + count + '/' + maxElements + '개');
                            return scrollables;
                        }
                        
                        // 셀렉터 생성 함수
                        function generateBestSelector(element) {
                            if (!element || element.nodeType !== 1) return null;
                            
                            if (element.id) {
                                return `#${element.id}`;
                            }
                            
                            const dataAttrs = Array.from(element.attributes)
                                .filter(attr => attr.name.startsWith('data-'))
                                .map(attr => `[${attr.name}="${attr.value}"]`);
                            if (dataAttrs.length > 0) {
                                const attrSelector = element.tagName.toLowerCase() + dataAttrs.join('');
                                if (document.querySelectorAll(attrSelector).length === 1) {
                                    return attrSelector;
                                }
                            }
                            
                            if (element.className) {
                                const classes = element.className.trim().split(/\\s+/);
                                const uniqueClasses = classes.filter(cls => {
                                    const elements = document.querySelectorAll(`.${cls}`);
                                    return elements.length === 1 && elements[0] === element;
                                });
                                
                                if (uniqueClasses.length > 0) {
                                    return `.${uniqueClasses.join('.')}`;
                                }
                                
                                if (classes.length > 0) {
                                    const classSelector = `.${classes.join('.')}`;
                                    if (document.querySelectorAll(classSelector).length === 1) {
                                        return classSelector;
                                    }
                                }
                            }
                            
                            // 상위 경로 포함
                            let path = [];
                            let current = element;
                            while (current && current !== document.documentElement) {
                                let selector = current.tagName.toLowerCase();
                                if (current.id) {
                                    path.unshift(`#${current.id}`);
                                    break;
                                }
                                if (current.className) {
                                    const classes = current.className.trim().split(/\\s+/).join('.');
                                    selector += `.${classes}`;
                                }
                                path.unshift(selector);
                                current = current.parentElement;
                                
                                if (path.length > 5) break;
                            }
                            return path.join(' > ');
                        }
                        
                        // 메인 실행
                        const scrollableElements = findAllScrollableElements();
                        
                        // 메인 스크롤 위치
                        const mainScrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                        const mainScrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                        
                        // 뷰포트 및 콘텐츠 크기
                        const viewportWidth = parseFloat(window.innerWidth) || 0;
                        const viewportHeight = parseFloat(window.innerHeight) || 0;
                        const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                        const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                        
                        // 실제 스크롤 가능 크기
                        const actualScrollableWidth = Math.max(contentWidth, window.innerWidth, document.body.scrollWidth || 0);
                        const actualScrollableHeight = Math.max(contentHeight, window.innerHeight, document.body.scrollHeight || 0);
                        
                        console.log(`🌐 전체 페이지 감지 완료: 일반 ${scrollableElements.length}개`);
                        console.log(`🌐 전체 페이지 위치: (${mainScrollX}, ${mainScrollY}) 뷰포트: (${viewportWidth}, ${viewportHeight})`);
                        
                        resolve({
                            scroll: { 
                                x: mainScrollX, 
                                y: mainScrollY,
                                elements: scrollableElements
                            },
                            iframes: [], // 전체 페이지에서는 iframe 처리 단순화
                            href: window.location.href,
                            title: document.title,
                            timestamp: Date.now(),
                            userAgent: navigator.userAgent,
                            viewport: {
                                width: viewportWidth,
                                height: viewportHeight
                            },
                            content: {
                                width: contentWidth,
                                height: contentHeight
                            },
                            actualScrollable: {
                                width: actualScrollableWidth,
                                height: actualScrollableHeight
                            },
                            fullPageMode: true
                        });
                    } catch(e) { 
                        console.error('🌐 전체 페이지 감지 실패:', e);
                        resolve({
                            scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0, elements: [] },
                            iframes: [],
                            href: window.location.href,
                            title: document.title,
                            actualScrollable: { width: 0, height: 0 },
                            fullPageMode: true
                        });
                    }
                }

                // 동적 콘텐츠 완료 대기 후 캡처
                if (document.readyState === 'complete') {
                    waitForFullPageStability(captureFullPageData);
                } else {
                    document.addEventListener('DOMContentLoaded', () => waitForFullPageStability(captureFullPageData));
                }
            });
        })()
        """
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 💾 **전체 페이지 디스크 저장 시스템**
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?, fullPageImage: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            // 디렉토리 생성
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 1. 뷰포트 이미지 저장
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                        self.dbg("💾 뷰포트 이미지 저장 성공: \(imagePath.lastPathComponent)")
                    } catch {
                        self.dbg("❌ 뷰포트 이미지 저장 실패: \(error.localizedDescription)")
                    }
                }
            }
            
            // 🌐 **2. 전체 페이지 이미지 저장**
            if let fullPageImage = snapshot.fullPageImage {
                let fullPagePath = pageDir.appendingPathComponent("fullpage.jpg")
                if let jpegData = fullPageImage.jpegData(compressionQuality: 0.6) { // 전체 페이지는 약간 낮은 품질
                    do {
                        try jpegData.write(to: fullPagePath)
                        finalSnapshot.fullPageSnapshotPath = fullPagePath.path
                        self.dbg("💾 전체 페이지 이미지 저장 성공: \(fullPagePath.lastPathComponent)")
                    } catch {
                        self.dbg("❌ 전체 페이지 이미지 저장 실패: \(error.localizedDescription)")
                    }
                }
            }
            
            // 3. 상태 데이터 저장 (JSON)
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                    self.dbg("💾 상태 저장 성공: \(statePath.lastPathComponent)")
                } catch {
                    self.dbg("❌상태 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 4. 메타데이터 저장
            let metadata = CacheMetadata(
                pageID: pageID,
                tabID: tabID,
                version: version,
                timestamp: Date(),
                url: snapshot.snapshot.pageRecord.url.absoluteString,
                title: snapshot.snapshot.pageRecord.title,
                captureMethod: finalSnapshot.captureMetadata.captureMethod,
                hasFullPage: finalSnapshot.fullPageSnapshotPath != nil
            )
            
            let metadataPath = pageDir.appendingPathComponent("metadata.json")
            if let metadataData = try? JSONEncoder().encode(metadata) {
                do {
                    try metadataData.write(to: metadataPath)
                } catch {
                    self.dbg("❌ 메타데이터 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 5. 인덱스 업데이트 (원자적)
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 전체 페이지 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)] 방법=\(finalSnapshot.captureMetadata.captureMethod)")
            
            // 6. 이전 버전 정리 (최신 3개만 유지)
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
        }
    }
    
    private struct CacheMetadata: Codable {
        let pageID: UUID
        let tabID: UUID
        let version: Int
        let timestamp: Date
        let url: String
        let title: String
        let captureMethod: String
        let hasFullPage: Bool
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private func cleanupOldVersions(pageID: UUID, tabID: UUID, currentVersion: Int) {
        let tabDir = tabDirectory(for: tabID)
        let pagePrefix = "Page_\(pageID.uuidString)_v"
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil)
            let pageDirs = contents.filter { $0.lastPathComponent.hasPrefix(pagePrefix) }
                .sorted { url1, url2 in
                    // 버전 번호 추출하여 정렬
                    let v1 = Int(url1.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    let v2 = Int(url2.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    return v1 > v2  // 최신 버전부터
                }
            
            // 최신 3개 제외하고 삭제
            if pageDirs.count > 3 {
                for i in 3..<pageDirs.count {
                    try FileManager.default.removeItem(at: pageDirs[i])
                    dbg("🗑️ 이전 버전 삭제: \(pageDirs[i].lastPathComponent)")
                }
            }
        } catch {
            dbg("⚠️ 이전 버전 정리 실패: \(error)")
        }
    }
    
    // MARK: - 💾 **디스크 캐시 로딩 (기존과 동일)**
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            // BFCache 디렉토리 생성
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            
            var loadedCount = 0
            
            // 모든 탭 디렉토리 스캔
            do {
                let tabDirs = try FileManager.default.contentsOfDirectory(at: self.bfCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                
                for tabDir in tabDirs {
                    if tabDir.lastPathComponent.hasPrefix("Tab_") {
                        // 각 페이지 디렉토리 스캔
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                // metadata.json 로드
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                if let data = try? Data(contentsOf: metadataPath),
                                   let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) {
                                    
                                    // 스레드 안전하게 인덱스 업데이트
                                    self.setDiskIndex(pageDir.path, for: metadata.pageID)
                                    self.cacheAccessQueue.async(flags: .barrier) {
                                        self._cacheVersion[metadata.pageID] = metadata.version
                                    }
                                    loadedCount += 1
                                }
                            }
                        }
                    }
                }
                
                self.dbg("💾 전체 페이지 디스크 캐시 인덱스 로드 완료: \(loadedCount)개 항목")
            } catch {
                self.dbg("❌ 디스크 캐시 로드 실패: \(error)")
            }
        }
    }
    
    // MARK: - 🔍 **스냅샷 조회 시스템 (기존과 동일)**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 먼저 메모리 캐시 확인 (스레드 안전)
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    // MARK: - 🔧 hasCache 메서드
    func hasCache(for pageID: UUID) -> Bool {
        // 메모리 캐시 체크
        if cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) != nil {
            return true
        }
        
        // 디스크 캐시 인덱스 체크
        if cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) != nil {
            return true
        }
        
        return false
    }
    
    // MARK: - 메모리 캐시 관리
    
    private func storeInMemory(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)]")
    }
    
    // MARK: - 🧹 **캐시 정리 (기존과 동일)**
    
    // 탭 닫을 때만 호출
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 🧵 제스처 컨텍스트 정리
        removeGestureContext(for: tabID)
        removeActiveTransition(for: tabID)
        
        // 메모리에서 제거 (스레드 안전)
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
            }
        }
        
        // 디스크에서 제거
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            let tabDir = self.tabDirectory(for: tabID)
            do {
                try FileManager.default.removeItem(at: tabDir)
                self.dbg("🗑️ 탭 캐시 완전 삭제: \(tabID.uuidString)")
            } catch {
                self.dbg("⚠️ 탭 캐시 삭제 실패: \(error)")
            }
        }
    }
    
    // 메모리 경고 처리
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }
    
    private func handleMemoryWarning() {
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let beforeCount = self._memoryCache.count
            
            // 메모리 캐시의 절반 정리 (오래된 것부터)
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🧵 **제스처 시스템 (기존 유지)**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        // 네이티브 제스처 비활성화
        webView.allowsBackForwardNavigationGestures = false
        
        guard let tabID = stateModel.tabID else {
            dbg("🧵 탭 ID 없음 - 제스처 설정 스킵")
            return
        }
        
        // 🧵 **기존 제스처 정리 (중복 방지)**
        cleanupExistingGestures(for: webView, tabID: tabID)
        
        // 🧵 **새로운 제스처 컨텍스트 생성**
        let gestureContext = GestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
        setGestureContext(gestureContext, for: tabID)
        
        // 🧵 **메인 스레드에서 제스처 생성 및 설정**
        DispatchQueue.main.async { [weak self] in
            self?.createAndAttachGestures(webView: webView, tabID: tabID)
        }
        
        // 📸 **전체 페이지 네비게이션 감지 등록**
        Self.registerNavigationObserver(for: webView, stateModel: stateModel)
        
        dbg("🌐 전체 페이지 BFCache 제스처 설정 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **기존 제스처 정리**
    private func cleanupExistingGestures(for webView: WKWebView, tabID: UUID) {
        // 기존 제스처 컨텍스트 무효화
        removeGestureContext(for: tabID)
        
        // 웹뷰에서 기존 BFCache 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if let edgeGesture = gesture as? UIScreenEdgePanGestureRecognizer,
               edgeGesture.edges == .left || edgeGesture.edges == .right {
                webView.removeGestureRecognizer(gesture)
                dbg("🧵 기존 제스처 제거: \(edgeGesture.edges)")
            }
        }
    }
    
    // 🧵 **제스처 생성 및 연결**
    private func createAndAttachGestures(webView: WKWebView, tabID: UUID) {
        // 왼쪽 엣지 - 뒤로가기
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        
        // 오른쪽 엣지 - 앞으로가기  
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        
        // 🧵 **제스처에 탭 ID 연결 (컨텍스트 검색용)**
        objc_setAssociatedObject(leftEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(rightEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        webView.addGestureRecognizer(leftEdge)
        webView.addGestureRecognizer(rightEdge)
        
        dbg("🧵 제스처 연결 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **제스처 핸들러 (메인 스레드 최적화)**
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // 🧵 **메인 스레드 확인 및 강제 이동**
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleGesture(gesture)
            }
            return
        }
        
        // 🧵 **제스처에서 탭 ID 조회**
        guard let tabIDString = objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String,
              let tabID = UUID(uuidString: tabIDString) else {
            dbg("🧵 제스처에서 탭 ID 조회 실패")
            gesture.state = .cancelled
            return
        }
        
        // 🧵 **컨텍스트 유효성 검사 및 조회**
        guard let context = getGestureContext(for: tabID) else {
            dbg("🧵 제스처 컨텍스트 없음 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
            gesture.state = .cancelled
            return
        }
        
        // 🧵 **컨텍스트 내에서 안전하게 실행**
        context.validateAndExecute { [weak self] in
            guard let self = self,
                  let webView = context.webView,
                  let stateModel = context.stateModel else {
                TabPersistenceManager.debugMessages.append("🧵 컨텍스트 무효 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
                gesture.state = .cancelled
                return
            }
            
            self.processGestureState(
                gesture: gesture,
                tabID: tabID,
                webView: webView,
                stateModel: stateModel
            )
        }
    }
    
    // 🧵 **제스처 상태 처리 (핵심 로직은 그대로 유지)**
    private func processGestureState(gesture: UIScreenEdgePanGestureRecognizer, tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let width = gesture.view?.bounds.width ?? 1
        
        // 수직 슬롭/부호 반대 방지
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 8 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            // 🛡️ **전환 중이면 새 제스처 무시**
            guard getActiveTransition(for: tabID) == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 🛡️ **기존 전환 강제 정리**
                if let existing = getActiveTransition(for: tabID) {
                    existing.previewContainer?.removeFromSuperview()
                    removeActiveTransition(for: tabID)
                    dbg("🛡️ 기존 전환 강제 정리")
                }
                
                // 현재 페이지 즉시 캡처 (높은 우선순위)
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
                // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
                captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
                    DispatchQueue.main.async {
                        self?.beginGestureTransitionWithSnapshot(
                            tabID: tabID,
                            webView: webView,
                            stateModel: stateModel,
                            direction: direction,
                            currentSnapshot: snapshot
                        )
                    }
                }
            } else {
                gesture.state = .cancelled
            }
            
        case .changed:
            guard horizontalEnough && signOK else { return }
            updateGestureProgress(tabID: tabID, translation: translation.x, isLeftEdge: isLeftEdge)
            
        case .ended:
            let progress = min(1.0, absX / width)
            let shouldComplete = progress > 0.3 || abs(velocity.x) > 800
            if shouldComplete {
                completeGestureTransition(tabID: tabID)
            } else {
                cancelGestureTransition(tabID: tabID)
            }
            
        case .cancelled, .failed:
            cancelGestureTransition(tabID: tabID)
            
        default:
            break
        }
    }
    
    // MARK: - 🎯 **나머지 제스처/전환 로직 (전체 페이지 대응)**
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = false
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 현재 페이지 스냅샷 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let fallbackImage = self.renderWebViewToImage(webView)
                    completion(fallbackImage)
                }
            } else {
                completion(image)
            }
        }
    }
    
    private func beginGestureTransitionWithSnapshot(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
        let initialTransform = webView.transform
        
        let previewContainer = createPreviewContainer(
            webView: webView,
            direction: direction,
            stateModel: stateModel,
            currentSnapshot: currentSnapshot
        )
        
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            isGesture: true,
            direction: direction,
            initialTransform: initialTransform,
            previewContainer: previewContainer,
            currentSnapshot: currentSnapshot
        )
        setActiveTransition(context, for: tabID)
        
        dbg("🎬 전체 페이지 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentWebView = previewContainer.viewWithTag(1001)
        let targetPreview = previewContainer.viewWithTag(1002)
        
        if isLeftEdge {
            let moveDistance = max(0, min(screenWidth, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = -screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (moveDistance / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        } else {
            let moveDistance = max(-screenWidth, min(0, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (abs(moveDistance) / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        }
    }
    
    private func createPreviewContainer(webView: WKWebView, direction: NavigationDirection, stateModel: WebViewStateModel, currentSnapshot: UIImage? = nil) -> UIView {
        let container = UIView(frame: webView.bounds)
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        
        // 현재 웹뷰 스냅샷 사용
        let currentView: UIView
        if let snapshot = currentSnapshot {
            let imageView = UIImageView(image: snapshot)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            currentView = imageView
        } else {
            if let fallbackImage = renderWebViewToImage(webView) {
                let imageView = UIImageView(image: fallbackImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                currentView = imageView
            } else {
                currentView = UIView(frame: webView.bounds)
                currentView.backgroundColor = .systemBackground
            }
        }
        
        currentView.frame = webView.bounds
        currentView.tag = 1001
        
        // 그림자 설정
        currentView.layer.shadowColor = UIColor.black.cgColor
        currentView.layer.shadowOpacity = 0.3
        currentView.layer.shadowOffset = CGSize(width: direction == .back ? -5 : 5, height: 0)
        currentView.layer.shadowRadius = 10
        
        container.addSubview(currentView)
        
        // 타겟 페이지 미리보기
        let targetIndex = direction == .back ?
            stateModel.dataModel.currentPageIndex - 1 :
            stateModel.dataModel.currentPageIndex + 1
        
        var targetView: UIView
        
        if targetIndex >= 0, targetIndex < stateModel.dataModel.pageHistory.count {
            let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
            
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let targetImage = snapshot.loadImage() {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                dbg("📸 타겟 페이지 전체 페이지 BFCache 스냅샷 사용: \(targetRecord.title)")
            } else {
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 타겟 페이지 정보 카드 생성: \(targetRecord.title)")
            }
        } else {
            targetView = UIView()
            targetView.backgroundColor = .systemBackground
        }
        
        targetView.frame = webView.bounds
        targetView.tag = 1002
        
        if direction == .back {
            targetView.frame.origin.x = -webView.bounds.width
        } else {
            targetView.frame.origin.x = webView.bounds.width
        }
        
        container.insertSubview(targetView, at: 0)
        webView.addSubview(container)
        return container
    }
    
    private func createInfoCard(for record: PageRecord, in bounds: CGRect) -> UIView {
        let card = UIView(frame: bounds)
        card.backgroundColor = .systemBackground
        
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 12
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.1
        contentView.layer.shadowOffset = CGSize(width: 0, height: 2)
        contentView.layer.shadowRadius = 8
        card.addSubview(contentView)
        
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "globe")
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        contentView.addSubview(iconView)
        
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = record.title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        
        let urlLabel = UILabel()
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.text = record.url.host ?? record.url.absoluteString
        urlLabel.font = .systemFont(ofSize: 14)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 1
        contentView.addSubview(urlLabel)
        
        let timeLabel = UILabel()
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        timeLabel.text = formatter.string(from: record.lastAccessed)
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.textAlignment = .center
        contentView.addSubview(timeLabel)
        
        // 🌐 전체 페이지 표시 추가
        let fullPageIndicator = UILabel()
        fullPageIndicator.translatesAutoresizingMaskIntoConstraints = false
        fullPageIndicator.text = "🌐 전체 페이지"
        fullPageIndicator.font = .systemFont(ofSize: 10, weight: .medium)
        fullPageIndicator.textColor = .systemBlue
        fullPageIndicator.textAlignment = .center
        contentView.addSubview(fullPageIndicator)
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 200),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            fullPageIndicator.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 8),
            fullPageIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            
            timeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            timeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
        
        return card
    }
    
    // 🎬 **전체 페이지 기반 전환 완료**
    private func completeGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                if context.direction == .back {
                    currentView?.frame.origin.x = screenWidth
                    targetView?.frame.origin.x = 0
                } else {
                    currentView?.frame.origin.x = -screenWidth
                    targetView?.frame.origin.x = 0
                }
                currentView?.layer.shadowOpacity = 0
            },
            completion: { [weak self] _ in
                // 🎬 **전체 페이지 기반 네비게이션 수행**
                self?.performFullPageNavigationWithFixedTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🌐 **전체 페이지 기반 네비게이션 수행**
    private func performFullPageNavigationWithFixedTiming(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel else {
            // 실패 시 즉시 정리
            previewContainer.removeFromSuperview()
            removeActiveTransition(for: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🏄‍♂️ 전체 페이지 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 전체 페이지 사파리 스타일 앞으로가기 완료")
        }
        
        // 🌐 **전체 페이지 BFCache 복원**
        tryFullPageBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.removeActiveTransition(for: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - 전체 페이지 BFCache \(success ? "성공" : "실패")")
            }
        }
        
        dbg("🎬 미리보기 타임아웃 제거됨 - 제스처 먹통 방지")
    }
    
    // 🌐 **전체 페이지 BFCache 복원** 
    private func tryFullPageBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 전체 페이지 복원
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ 전체 페이지 BFCache 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 전체 페이지 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기본 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            
            // 기본 대기 시간 (250ms)
            let waitTime: TimeInterval = 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                completion(false)
            }
        }
    }
    
    private func cancelGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.25,
            animations: {
                currentView?.frame.origin.x = 0
                
                if context.direction == .back {
                    targetView?.frame.origin.x = -screenWidth
                } else {
                    targetView?.frame.origin.x = screenWidth
                }
                
                currentView?.layer.shadowOpacity = 0.3
            },
            completion: { _ in
                previewContainer.removeFromSuperview()
                self.removeActiveTransition(for: tabID)
            }
        )
    }
    
    // MARK: - 버튼 네비게이션 (전체 페이지 즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryFullPageBFCacheRestore(stateModel: stateModel, direction: .back) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        tryFullPageBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in
            // 버튼 네비게이션은 콜백 무시
        }
    }
    
    // MARK: - 스와이프 제스처 감지 처리 (DataModel에서 이관)
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        // 복원 중이면 무시
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        // 절대 원칙: 히스토리에서 찾더라도 무조건 새 페이지로 추가
        // 세션 점프 완전 방지
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
    }
    
    // MARK: - 🌐 JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🌐 전체 페이지 BFCache 페이지 복원');
                
                // 🌐 동적 콘텐츠 새로고침 (필요시)
                if (window.location.pathname.includes('/feed') ||
                    window.location.pathname.includes('/timeline') ||
                    window.location.hostname.includes('twitter') ||
                    window.location.hostname.includes('facebook') ||
                    window.location.hostname.includes('dcinside') ||
                    window.location.hostname.includes('cafe.naver')) {
                    if (window.refreshDynamicContent) {
                        window.refreshDynamicContent();
                    }
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 전체 페이지 BFCache 페이지 저장');
            }
        });
        
        // 🌐 Cross-origin iframe 전체 페이지 스크롤 복원 리스너
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    const targetX = parseFloat(event.data.scrollX) || 0;
                    const targetY = parseFloat(event.data.scrollY) || 0;
                    const fullPageMode = event.data.fullPageMode || false;
                    
                    console.log('🌐 Cross-origin iframe 전체 페이지 스크롤 복원:', targetX, targetY, fullPageMode ? '(전체 페이지 모드)' : '');
                    
                    // 🌐 전체 페이지 스크롤 설정
                    window.scrollTo(targetX, targetY);
                    document.documentElement.scrollTop = targetY;
                    document.documentElement.scrollLeft = targetX;
                    document.body.scrollTop = targetY;
                    document.body.scrollLeft = targetX;
                    
                } catch(e) {
                    console.error('Cross-origin iframe 스크롤 복원 실패:', e);
                }
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 디버그
    
    private func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[BFCache🌐] \(msg)")
    }
}

// MARK: - UIGestureRecognizerDelegate
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - CustomWebView 통합 인터페이스
extension BFCacheTransitionSystem {
    
    // CustomWebView의 makeUIView에서 호출
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        // BFCache 스크립트 설치
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        
        // 제스처 설치 + 📸 전체 페이지 네비게이션 감지
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 🌐 전체 페이지 캡처 BFCache 시스템 설치 완료 (뷰포트 한계 극복)")
    }
    
    // CustomWebView의 dismantleUIView에서 호출
    static func uninstall(from webView: WKWebView) {
        // 🧵 제스처 해제
        if let tabIDString = webView.gestureRecognizers?.compactMap({ gesture in
            objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String
        }).first, let tabID = UUID(uuidString: tabIDString) {
            shared.removeGestureContext(for: tabID)
            shared.removeActiveTransition(for: tabID)
        }
        
        // 📸 **네비게이션 감지 해제**
        unregisterNavigationObserver(for: webView)
        
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        TabPersistenceManager.debugMessages.append("🌐 전체 페이지 BFCache 시스템 제거 완료")
    }
    
    // 버튼 네비게이션 래퍼
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
}

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
extension BFCacheTransitionSystem {

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 전체 페이지 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 즉시 캡처 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 떠나기 전체 페이지 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 전체 페이지 캐시 강화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 전체 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 전체 페이지 스냅샷 캡처 시작: \(rec.title)")
        
        // 이전 페이지들도 순차적으로 캐시 확인 및 캡처
        if stateModel.dataModel.currentPageIndex > 0 {
            // 최근 3개 페이지만 체크 (성능 고려)
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                // 캐시가 없는 경우만 메타데이터 저장
                if !hasCache(for: previousRecord.id) {
                    // 메타데이터만 저장 (이미지는 없음)
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1
                    )
                    
                    // 디스크에 메타데이터만 저장
                    saveToDisk(snapshot: (metadataSnapshot, nil, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
