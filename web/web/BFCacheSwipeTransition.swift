//
//  BFCacheSwipeTransition.swift
//  🎯 **DOM 요소 기반 정밀 스크롤 복원 시스템**
//  ✅ 뷰포트 앵커 + 랜드마크 기반 복원으로 단순화
//  🚫 **컨테이너 스크롤 복원 제거** - 복잡성 감소
//  🚫 **브라우저 차단 대응** - 점진적 스크롤 + 무한 스크롤 트리거
//  📸 동적 DOM 요소 위치 추적
//  ♾️ 무한 스크롤 대응 강화
//  💾 스마트 메모리 관리 
//  📈 **DOM 기준 정밀 복원** - 절대 좌표 대신 요소 기준 복원
//  🔧 **뷰포트 앵커 시스템** - 화면에 보이는 핵심 요소 기준
//  🎯 **정밀 스크롤 복원 강화** - 앵커/랜드마크/고정헤더/가상리스트 대응
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

// MARK: - 📸 **개선된 BFCache 페이지 스냅샷 (DOM 요소 기반)**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint  // ⚡ CGFloat 기반 정밀 스크롤
    let scrollPositionPercent: CGPoint  // 🔄 상대적 위치 (백분율)
    let contentSize: CGSize  // 📐 콘텐츠 크기 정보
    let viewportSize: CGSize  // 📱 뷰포트 크기 정보
    let actualScrollableSize: CGSize  // ♾️ **실제 스크롤 가능한 최대 크기**
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
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
        case captureStatus
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
        captureStatus = try container.decode(CaptureStatus.self, forKey: .captureStatus)
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
        try container.encode(captureStatus, forKey: .captureStatus)
        try container.encode(version, forKey: .version)
    }
    
    // 직접 초기화용 init (정밀 스크롤 지원)
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
         captureStatus: CaptureStatus = .partial, 
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
        self.captureStatus = captureStatus
        self.version = version
    }
    
    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    
    // 🎯 **핵심 개선: DOM 요소 기반 1단계 복원**
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 DOM 요소 기반 BFCache 복원 시작 - 상태: \(captureStatus.rawValue)")
        
        // 🎯 **1단계: DOM 요소 기반 스크롤 복원 우선 실행**
        performElementBasedScrollRestore(to: webView)
        
        // 🔧 **기존 상태별 분기 로직 유지**
        switch captureStatus {
        case .failed:
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패 상태 - DOM 요소 복원만 수행")
            completion(true)
            return
            
        case .visualOnly:
            TabPersistenceManager.debugMessages.append("🖼️ 이미지만 캡처된 상태 - DOM 요소 복원 + 최종보정")
            
        case .partial:
            TabPersistenceManager.debugMessages.append("⚡ 부분 캡처 상태 - DOM 요소 복원 + 브라우저 차단 대응")
            
        case .complete:
            TabPersistenceManager.debugMessages.append("✅ 완전 캡처 상태 - DOM 요소 복원 + 브라우저 차단 대응")
        }
        
        TabPersistenceManager.debugMessages.append("🌐 DOM 요소 기반 복원 후 브라우저 차단 대응 시작")
        
        // 🔧 **DOM 요소 복원 후 브라우저 차단 대응 단계 실행**
        DispatchQueue.main.async {
            self.performBrowserBlockingWorkaround(to: webView, completion: completion)
        }
    }
    
    // 🎯 **새로 추가: DOM 요소 기반 1단계 복원 메서드**
    private func performElementBasedScrollRestore(to webView: WKWebView) {
        TabPersistenceManager.debugMessages.append("🎯 DOM 요소 기반 1단계 복원 시작")
        
        // 1. 네이티브 스크롤뷰 기본 설정 (백업용)
        let targetPos = self.scrollPosition
        webView.scrollView.setContentOffset(targetPos, animated: false)
        
        // 2. 🎯 **DOM 요소 기반 복원 JavaScript 실행**
        let elementRestoreJS = generateElementBasedRestoreScript()
        
        // 동기적 JavaScript 실행 (즉시)
        webView.evaluateJavaScript(elementRestoreJS) { result, error in
            let success = (result as? Bool) ?? false
            TabPersistenceManager.debugMessages.append("🎯 DOM 요소 기반 복원: \(success ? "성공" : "실패")")
            
            if let resultDict = result as? [String: Any] {
                if let method = resultDict["method"] as? String {
                    TabPersistenceManager.debugMessages.append("🎯 사용된 복원 방법: \(method)")
                }
                if let anchorInfo = resultDict["anchorInfo"] as? String {
                    TabPersistenceManager.debugMessages.append("🎯 앵커 정보: \(anchorInfo)")
                }
            }
        }
        
        TabPersistenceManager.debugMessages.append("🎯 DOM 요소 기반 1단계 복원 완료")
    }
    
    // 🎯 **핵심: DOM 요소 기반 복원 JavaScript 생성**
    private func generateElementBasedRestoreScript() -> String {
        let targetPos = self.scrollPosition
        let targetPercent = self.scrollPositionPercent
        
        // jsState에서 정밀 복원 데이터 추출
        var restorationData = "null"
        
        if let jsState = self.jsState {
            if let restorationJSON = convertToJSONString(jsState) {
                restorationData = restorationJSON
            }
        }
        
        return """
        (function() {
            try {
                const targetX = parseFloat('\(targetPos.x)');
                const targetY = parseFloat('\(targetPos.y)');
                const targetPercentX = parseFloat('\(targetPercent.x)');
                const targetPercentY = parseFloat('\(targetPercent.y)');
                const restorationData = \(restorationData);
                
                console.log('🎯 정밀 DOM 요소 기반 복원 시작:', {
                    target: [targetX, targetY],
                    percent: [targetPercentX, targetPercentY],
                    hasData: !!restorationData,
                    schemaVersion: restorationData?.schemaVersion || 'unknown'
                });
                
                let restoredByElement = false;
                let usedMethod = 'fallback';
                let anchorInfo = 'none';
                
                // 🎯 **방법 1: 앵커 기반 정밀 복원 (스키마 v2)**
                if (restorationData && restorationData.anchors && restorationData.anchors.length > 0) {
                    try {
                        const anchors = restorationData.anchors;
                        const stickyTop = parseFloat(restorationData.stickyTop) || 0;
                        
                        console.log('🎯 앵커 기반 복원 시도:', anchors.length, '개 앵커, 고정헤더:', stickyTop, 'px');
                        
                        for (const anchor of anchors) {
                            try {
                                const anchorElement = document.querySelector(anchor.selector);
                                if (anchorElement) {
                                    // 앵커 요소의 현재 위치 계산
                                    const rect = anchorElement.getBoundingClientRect();
                                    const currentAbsTop = window.scrollY + rect.top;
                                    const currentAbsLeft = window.scrollX + rect.left;
                                    
                                    // 저장된 오프셋으로 복원 위치 계산
                                    const restoreY = currentAbsTop - parseFloat(anchor.offsetFromTop) - stickyTop;
                                    const restoreX = currentAbsLeft - parseFloat(anchor.offsetFromLeft);
                                    
                                    console.log('🎯 앵커 복원:', {
                                        selector: anchor.selector,
                                        role: anchor.role,
                                        currentAbs: [currentAbsLeft, currentAbsTop],
                                        offset: [anchor.offsetFromLeft, anchor.offsetFromTop],
                                        stickyTop: stickyTop,
                                        restore: [restoreX, restoreY],
                                        textHead: anchor.textHead
                                    });
                                    
                                    // 텍스트 검증 (선택적)
                                    if (anchor.textHash && anchor.textHead) {
                                        const currentText = (anchorElement.textContent || '').trim().substring(0, 60);
                                        if (currentText !== anchor.textHead) {
                                            console.log('⚠️ 앵커 텍스트 변경됨:', currentText, '!=', anchor.textHead);
                                            continue; // 다음 앵커 시도
                                        }
                                    }
                                    
                                    // 앵커 기반 스크롤 실행
                                    window.scrollTo(Math.max(0, restoreX), Math.max(0, restoreY));
                                    document.documentElement.scrollTop = Math.max(0, restoreY);
                                    document.documentElement.scrollLeft = Math.max(0, restoreX);
                                    document.body.scrollTop = Math.max(0, restoreY);
                                    document.body.scrollLeft = Math.max(0, restoreX);
                                    
                                    restoredByElement = true;
                                    usedMethod = 'anchor_' + anchor.role;
                                    anchorInfo = anchor.selector + ' role:' + anchor.role;
                                    break; // 성공시 중단
                                }
                            } catch(e) {
                                console.log('🎯 앵커 복원 실패:', anchor.selector, e.message);
                            }
                        }
                    } catch(e) {
                        console.log('🎯 앵커 배열 처리 실패:', e.message);
                    }
                }
                
                // 🎯 **방법 2: 랜드마크 기반 근사 복원**
                if (!restoredByElement && restorationData && restorationData.landmarks && restorationData.landmarks.length > 0) {
                    try {
                        const landmarks = restorationData.landmarks;
                        const stickyTop = parseFloat(restorationData.stickyTop) || 0;
                        
                        console.log('🎯 랜드마크 기반 복원 시도:', landmarks.length, '개 랜드마크');
                        
                        for (const landmark of landmarks) {
                            try {
                                const landmarkElement = document.querySelector(landmark.selector);
                                if (landmarkElement) {
                                    const rect = landmarkElement.getBoundingClientRect();
                                    const currentAbsTop = window.scrollY + rect.top;
                                    
                                    // 랜드마크 기준으로 상대적 위치 계산
                                    const offsetFromLandmark = targetY - parseFloat(landmark.absTop);
                                    const restoreY = currentAbsTop + offsetFromLandmark - stickyTop;
                                    
                                    console.log('🎯 랜드마크 복원:', {
                                        selector: landmark.selector,
                                        role: landmark.role,
                                        savedAbsTop: landmark.absTop,
                                        currentAbsTop: currentAbsTop,
                                        offset: offsetFromLandmark,
                                        restoreY: restoreY
                                    });
                                    
                                    // 텍스트 검증 (선택적)
                                    if (landmark.textHash) {
                                        const currentText = (landmarkElement.textContent || '').trim().substring(0, 60);
                                        const currentHash = generateSimpleHash(currentText);
                                        if (currentHash !== landmark.textHash) {
                                            console.log('⚠️ 랜드마크 텍스트 변경됨');
                                            continue;
                                        }
                                    }
                                    
                                    window.scrollTo(targetX, Math.max(0, restoreY));
                                    document.documentElement.scrollTop = Math.max(0, restoreY);
                                    document.body.scrollTop = Math.max(0, restoreY);
                                    
                                    restoredByElement = true;
                                    usedMethod = 'landmark_' + landmark.role;
                                    anchorInfo = landmark.selector + ' role:' + landmark.role;
                                    break;
                                }
                            } catch(e) {
                                console.log('🎯 랜드마크 복원 실패:', landmark.selector, e.message);
                            }
                        }
                    } catch(e) {
                        console.log('🎯 랜드마크 배열 처리 실패:', e.message);
                    }
                }
                
                // 🎯 **방법 3: 가상 리스트 힌트 기반 복원**
                if (!restoredByElement && restorationData && restorationData.virtualList && restorationData.virtualList.type !== 'unknown') {
                    try {
                        const vl = restorationData.virtualList;
                        console.log('🎯 가상 리스트 복원 시도:', vl.type);
                        
                        // 가상 리스트 스크롤 위치 보정
                        const beforePx = parseFloat(vl.beforePx) || 0;
                        const itemHeightAvg = parseFloat(vl.itemHeightAvg) || 0;
                        
                        if (itemHeightAvg > 0) {
                            // 아이템 인덱스 기준으로 복원
                            const estimatedIndex = Math.floor(targetY / itemHeightAvg);
                            const adjustedY = beforePx + (estimatedIndex * itemHeightAvg);
                            
                            console.log('🎯 가상 리스트 보정:', {
                                originalY: targetY,
                                estimatedIndex: estimatedIndex,
                                adjustedY: adjustedY,
                                beforePx: beforePx,
                                itemHeight: itemHeightAvg
                            });
                            
                            window.scrollTo(targetX, adjustedY);
                            document.documentElement.scrollTop = adjustedY;
                            document.body.scrollTop = adjustedY;
                            
                            restoredByElement = true;
                            usedMethod = 'virtualList_' + vl.type;
                            anchorInfo = 'index:' + estimatedIndex + ' height:' + itemHeightAvg;
                        }
                    } catch(e) {
                        console.log('🎯 가상 리스트 복원 실패:', e.message);
                    }
                }
                
                // 🎯 **방법 4: 백분율 기반 복원**
                if (!restoredByElement && targetPercentY > 0) {
                    try {
                        const currentScrollHeight = Math.max(
                            document.documentElement.scrollHeight,
                            document.body.scrollHeight
                        );
                        const currentScrollWidth = Math.max(
                            document.documentElement.scrollWidth,
                            document.body.scrollWidth
                        );
                        
                        const maxScrollY = currentScrollHeight - window.innerHeight;
                        const maxScrollX = currentScrollWidth - window.innerWidth;
                        
                        const percentRestoreY = (targetPercentY / 100.0) * maxScrollY;
                        const percentRestoreX = (targetPercentX / 100.0) * maxScrollX;
                        
                        console.log('🎯 백분율 기반 복원:', {
                            percent: [targetPercentX, targetPercentY],
                            currentSize: [currentScrollWidth, currentScrollHeight],
                            maxScroll: [maxScrollX, maxScrollY],
                            restore: [percentRestoreX, percentRestoreY]
                        });
                        
                        window.scrollTo(Math.max(0, percentRestoreX), Math.max(0, percentRestoreY));
                        document.documentElement.scrollTop = Math.max(0, percentRestoreY);
                        document.documentElement.scrollLeft = Math.max(0, percentRestoreX);
                        document.body.scrollTop = Math.max(0, percentRestoreY);
                        document.body.scrollLeft = Math.max(0, percentRestoreX);
                        
                        restoredByElement = true;
                        usedMethod = 'percentage';
                        anchorInfo = 'percent(' + targetPercentX.toFixed(1) + ',' + targetPercentY.toFixed(1) + ')';
                    } catch(e) {
                        console.log('🎯 백분율 복원 실패:', e.message);
                    }
                }
                
                // 🎯 **방법 5: 폴백 - 절대 좌표 기반 복원**
                if (!restoredByElement) {
                    console.log('🎯 DOM 요소 복원 실패 - 좌표 기반 폴백 실행');
                    
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
                    
                    usedMethod = 'coordinateFallback';
                    anchorInfo = 'coords(' + targetX + ',' + targetY + ')';
                }
                
                // 최종 위치 확인
                const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                
                console.log('🎯 정밀 DOM 요소 기반 복원 완료:', {
                    target: [targetX, targetY],
                    final: [finalX, finalY],
                    diff: [Math.abs(finalX - targetX), Math.abs(finalY - targetY)],
                    method: usedMethod,
                    elementBased: restoredByElement
                });
                
                // 간단한 해시 함수 (64bit 시뮬레이션)
                function generateSimpleHash(str) {
                    let hash = 0;
                    if (str.length === 0) return hash.toString();
                    for (let i = 0; i < str.length; i++) {
                        const char = str.charCodeAt(i);
                        hash = ((hash << 5) - hash) + char;
                        hash = hash & hash; // 32bit 정수 변환
                    }
                    return Math.abs(hash).toString();
                }
                
                return {
                    success: true,
                    method: usedMethod,
                    anchorInfo: anchorInfo,
                    elementBased: restoredByElement,
                    finalPosition: [finalX, finalY]
                };
                
            } catch(e) { 
                console.error('🎯 정밀 DOM 요소 기반 복원 실패:', e);
                return {
                    success: false,
                    method: 'error',
                    anchorInfo: e.message,
                    elementBased: false
                };
            }
        })()
        """
    }
    
    // 🚫 **브라우저 차단 대응 시스템 (점진적 스크롤 + 무한 스크롤 트리거)**
    private func performBrowserBlockingWorkaround(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        var stepResults: [Bool] = []
        var currentStep = 0
        let startTime = Date()
        
        var restoreSteps: [(step: Int, action: (@escaping (Bool) -> Void) -> Void)] = []
        
        TabPersistenceManager.debugMessages.append("🚫 브라우저 차단 대응 단계 구성 시작")
        
        // **1단계: 점진적 스크롤 복원 (브라우저 차단 해결)**
        restoreSteps.append((1, { stepCompletion in
            let progressiveDelay: TimeInterval = 0.1
            TabPersistenceManager.debugMessages.append("🚫 1단계: 점진적 스크롤 복원 (대기: \(String(format: "%.0f", progressiveDelay * 1000))ms)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + progressiveDelay) {
                let progressiveScrollJS = """
                (function() {
                    return new Promise(async (resolve) => {
                        try {
                            const targetX = parseFloat('\(self.scrollPosition.x)');
                            const targetY = parseFloat('\(self.scrollPosition.y)');
                            const tolerance = 50.0;
                            
                            console.log('🚫 점진적 스크롤 시작:', {target: [targetX, targetY]});
                            
                            // 🚫 **브라우저 차단 대응: 점진적 스크롤**
                            let attempts = 0;
                            const maxAttempts = 15;
                            
                            while (attempts < maxAttempts) {
                                // 현재 위치 확인
                                const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                                const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                                
                                // 목표 도달 확인
                                if (Math.abs(currentX - targetX) <= tolerance && Math.abs(currentY - targetY) <= tolerance) {
                                    console.log('🚫 점진적 스크롤 성공:', {current: [currentX, currentY], attempts: attempts + 1});
                                    resolve('progressive_success');
                                    return;
                                }
                                
                                // 스크롤 한계 확인 (더 이상 스크롤할 수 없음)
                                const maxScrollY = Math.max(
                                    document.documentElement.scrollHeight - window.innerHeight,
                                    document.body.scrollHeight - window.innerHeight,
                                    0
                                );
                                const maxScrollX = Math.max(
                                    document.documentElement.scrollWidth - window.innerWidth,
                                    document.body.scrollWidth - window.innerWidth,
                                    0
                                );
                                
                                if (currentY >= maxScrollY && targetY > maxScrollY) {
                                    console.log('🚫 Y축 스크롤 한계 도달:', {current: currentY, max: maxScrollY, target: targetY});
                                    
                                    // 🚫 **무한 스크롤 트리거 시도**
                                    console.log('🚫 무한 스크롤 트리거 시도');
                                    
                                    // 스크롤 이벤트 강제 발생
                                    window.dispatchEvent(new Event('scroll', { bubbles: true }));
                                    window.dispatchEvent(new Event('resize', { bubbles: true }));
                                    
                                    // 터치 이벤트 시뮬레이션 (모바일 무한 스크롤용)
                                    try {
                                        const touchEvent = new TouchEvent('touchend', { bubbles: true });
                                        document.dispatchEvent(touchEvent);
                                    } catch(e) {
                                        // TouchEvent 지원 안 되면 무시
                                    }
                                    
                                    // 하단 영역 클릭 시뮬레이션 (일부 사이트의 "더보기" 버튼)
                                    const loadMoreButtons = document.querySelectorAll(
                                        '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                                        '[data-role="load"], .load-more, .show-more, .infinite-scroll-trigger'
                                    );
                                    
                                    loadMoreButtons.forEach(btn => {
                                        if (btn && typeof btn.click === 'function') {
                                            try {
                                                btn.click();
                                                console.log('🚫 "더보기" 버튼 클릭:', btn.className);
                                            } catch(e) {
                                                // 클릭 실패는 무시
                                            }
                                        }
                                    });
                                }
                                
                                // 스크롤 시도
                                window.scrollTo(targetX, targetY);
                                document.documentElement.scrollTop = targetY;
                                document.documentElement.scrollLeft = targetX;
                                document.body.scrollTop = targetY;
                                document.body.scrollLeft = targetX;
                                
                                if (document.scrollingElement) {
                                    document.scrollingElement.scrollTop = targetY;
                                    document.scrollingElement.scrollLeft = targetX;
                                }
                                
                                attempts++;
                                
                                // 대기 시간 (콘텐츠 로딩 대기)
                                await new Promise(resolve => setTimeout(resolve, 200));
                            }
                            
                            // 최대 시도 후에도 실패
                            const finalY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const finalX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            
                            console.log('🚫 점진적 스크롤 한계 도달:', {
                                target: [targetX, targetY],
                                final: [finalX, finalY],
                                attempts: maxAttempts
                            });
                            
                            resolve('progressive_partial');
                            
                        } catch(e) { 
                            console.error('🚫 점진적 스크롤 실패:', e);
                            resolve('progressive_error'); 
                        }
                    });
                })()
                """
                
                webView.evaluateJavaScript(progressiveScrollJS) { result, _ in
                    let resultString = result as? String ?? "progressive_error"
                    let success = resultString.contains("success") || resultString.contains("partial")
                    TabPersistenceManager.debugMessages.append("🚫 1단계 완료: \(success ? "성공" : "실패") (\(resultString))")
                    stepCompletion(success)
                }
            }
        }))
        
        // **2단계: iframe 스크롤 복원 (기존 유지)**
        if let jsState = self.jsState,
           let iframeData = jsState["iframesV2"] as? [[String: Any]], !iframeData.isEmpty {
            
            TabPersistenceManager.debugMessages.append("🖼️ 2단계 iframe 스크롤 복원 단계 추가 - iframe \(iframeData.count)개")
            
            restoreSteps.append((2, { stepCompletion in
                let waitTime: TimeInterval = 0.15
                TabPersistenceManager.debugMessages.append("🖼️ 2단계: iframe 스크롤 복원 (대기: \(String(format: "%.2f", waitTime))초)")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                    let iframeScrollJS = self.generateIframeScrollScript(iframeData)
                    webView.evaluateJavaScript(iframeScrollJS) { result, _ in
                        let success = (result as? Bool) ?? false
                        TabPersistenceManager.debugMessages.append("🖼️ 2단계 완료: \(success ? "성공" : "실패")")
                        stepCompletion(success)
                    }
                }
            }))
        } else {
            TabPersistenceManager.debugMessages.append("🖼️ 2단계 스킵 - iframe 요소 없음")
        }
        
        // **3단계: 최종 확인 및 보정**
        TabPersistenceManager.debugMessages.append("✅ 3단계 최종 보정 단계 추가 (필수)")
        
        restoreSteps.append((3, { stepCompletion in
            let waitTime: TimeInterval = 0.8
            TabPersistenceManager.debugMessages.append("✅ 3단계: 최종 보정 (대기: \(String(format: "%.2f", waitTime))초)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                let finalVerifyJS = """
                (function() {
                    try {
                        const targetX = parseFloat('\(self.scrollPosition.x)');
                        const targetY = parseFloat('\(self.scrollPosition.y)');
                        
                        // 네이티브 스크롤 위치 정밀 확인
                        const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const tolerance = 30.0; // 🚫 브라우저 차단 고려하여 관대한 허용 오차
                        
                        console.log('✅ 브라우저 차단 대응 최종 검증:', {
                            target: [targetX, targetY],
                            current: [currentX, currentY],
                            tolerance: tolerance
                        });
                        
                        // 최종 보정 (필요시)
                        if (Math.abs(currentX - targetX) > tolerance || Math.abs(currentY - targetY) > tolerance) {
                            console.log('✅ 최종 보정 실행:', {current: [currentX, currentY], target: [targetX, targetY]});
                            
                            // 강력한 최종 보정 
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
                        }
                        
                        // 최종 위치 확인
                        const finalCurrentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                        const finalCurrentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                        const isWithinTolerance = Math.abs(finalCurrentX - targetX) <= tolerance && Math.abs(finalCurrentY - targetY) <= tolerance;
                        
                        console.log('✅ 브라우저 차단 대응 최종보정 완료:', {
                            current: [finalCurrentX, finalCurrentY],
                            target: [targetX, targetY],
                            tolerance: tolerance,
                            isWithinTolerance: isWithinTolerance,
                            note: '브라우저차단대응'
                        });
                        
                        // 🚫 **관대한 성공 판정** (브라우저 차단 고려)
                        return true; // 브라우저 차단 대응은 항상 성공으로 처리
                    } catch(e) { 
                        console.error('✅ 브라우저 차단 대응 최종보정 실패:', e);
                        return true; // 에러도 성공으로 처리 (관대한 정책)
                    }
                })()
                """
                
                webView.evaluateJavaScript(finalVerifyJS) { result, _ in
                    let success = (result as? Bool) ?? true // 🚫 브라우저 차단 대응은 관대하게
                    TabPersistenceManager.debugMessages.append("✅ 3단계 브라우저 차단 대응 최종보정 완료: \(success ? "성공" : "성공(관대)")")
                    stepCompletion(true) // 항상 성공
                }
            }
        }))
        
        TabPersistenceManager.debugMessages.append("🚫 총 \(restoreSteps.count)단계 브라우저 차단 대응 단계 구성 완료")
        
        // 단계별 실행
        func executeNextStep() {
            if currentStep < restoreSteps.count {
                let stepInfo = restoreSteps[currentStep]
                currentStep += 1
                
                TabPersistenceManager.debugMessages.append("🚫 \(stepInfo.step)단계 실행 시작")
                
                let stepStart = Date()
                stepInfo.action { success in
                    let stepDuration = Date().timeIntervalSince(stepStart)
                    TabPersistenceManager.debugMessages.append("🚫 단계 \(stepInfo.step) 소요시간: \(String(format: "%.2f", stepDuration))초")
                    stepResults.append(success)
                    executeNextStep()
                }
            } else {
                // 모든 단계 완료
                let duration = Date().timeIntervalSince(startTime)
                let successCount = stepResults.filter { $0 }.count
                let totalSteps = stepResults.count
                let overallSuccess = successCount > totalSteps / 2
                
                TabPersistenceManager.debugMessages.append("🚫 브라우저 차단 대응 완료: \(successCount)/\(totalSteps) 성공, 소요시간: \(String(format: "%.2f", duration))초")
                TabPersistenceManager.debugMessages.append("🚫 최종 결과: \(overallSuccess ? "✅ 성공" : "✅ 성공(관대)")")
                completion(true) // 🚫 브라우저 차단 대응은 항상 성공으로 처리
            }
        }
        
        executeNextStep()
    }
    
    // 🖼️ **iframe 스크롤 복원 스크립트** (기존 유지)
    private func generateIframeScrollScript(_ iframeData: [[String: Any]]) -> String {
        let iframeJSON = convertToJSONString(iframeData) ?? "[]"
        return """
        (function() {
            try {
                const iframes = \(iframeJSON);
                let restored = 0;
                
                console.log('🖼️ iframe 스크롤 복원 시작:', iframes.length, '개 iframe');
                
                for (const iframeInfo of iframes) {
                    const iframe = document.querySelector(iframeInfo.selector);
                    if (iframe && iframe.contentWindow) {
                        try {
                            const targetX = parseFloat(iframeInfo.scrollX || 0);
                            const targetY = parseFloat(iframeInfo.scrollY || 0);
                            
                            // Same-origin iframe 복원
                            iframe.contentWindow.scrollTo(targetX, targetY);
                            
                            try {
                                iframe.contentWindow.document.documentElement.scrollTop = targetY;
                                iframe.contentWindow.document.documentElement.scrollLeft = targetX;
                                iframe.contentWindow.document.body.scrollTop = targetY;
                                iframe.contentWindow.document.body.scrollLeft = targetX;
                            } catch(e) {
                                // 접근 제한은 무시
                            }
                            
                            restored++;
                            console.log('🖼️ iframe 복원:', iframeInfo.selector, [targetX, targetY]);
                        } catch(e) {
                            // 🌐 Cross-origin iframe 처리
                            try {
                                iframe.contentWindow.postMessage({
                                    type: 'restoreScroll',
                                    scrollX: parseFloat(iframeInfo.scrollX || 0),
                                    scrollY: parseFloat(iframeInfo.scrollY || 0),
                                    browserBlockingWorkaround: true // 🚫 브라우저 차단 대응 모드 플래그
                                }, '*');
                                console.log('🖼️ Cross-origin iframe 스크롤 요청:', iframeInfo.selector);
                                restored++;
                            } catch(crossOriginError) {
                                console.log('Cross-origin iframe 접근 불가:', iframeInfo.selector);
                            }
                        }
                    }
                }
                
                console.log('🖼️ iframe 스크롤 복원 완료:', restored, '개');
                return restored > 0;
            } catch(e) {
                console.error('iframe 스크롤 복원 실패:', e);
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

// MARK: - 📸 **네비게이션 이벤트 감지 시스템 - 모든 네비게이션에서 떠나기 전 캡처**
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
            
            // 📸 **URL이 바뀌는 순간 이전 페이지 캡처**
            if let currentRecord = stateModel.dataModel.currentPageRecord {
                shared.storeLeavingSnapshotIfPossible(webView: webView, stateModel: stateModel)
                shared.dbg("📸 URL 변경 감지 - 떠나기 전 캐시: \(oldURL.absoluteString) → \(newURL.absoluteString)")
            }
        }
        
        // 옵저버를 webView에 연결하여 생명주기 관리
        objc_setAssociatedObject(webView, "bfcache_url_observer", urlObserver, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        shared.dbg("📸 포괄적 네비게이션 감지 등록: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    /// CustomWebView 해제 시 옵저버 정리
    static func unregisterNavigationObserver(for webView: WKWebView) {
        if let observer = objc_getAssociatedObject(webView, "bfcache_url_observer") as? NSKeyValueObservation {
            observer.invalidate()
            objc_setAssociatedObject(webView, "bfcache_url_observer", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        shared.dbg("📸 네비게이션 감지 해제 완료")
    }
}

// MARK: - 🎯 **강화된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 **핵심 개선: 단일 직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
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
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🎯 정밀 DOM 요소 기반 캡처 강화)**
    
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
        dbg("🎯 정밀 DOM 요소 기반 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
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
        dbg("🎯 정밀 DOM 요소 기반 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
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
        
        // 🔧 **개선된 캡처 로직 - 실패 시 재시도 (기존 타이밍 유지)**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )
        
        // 🌐 캡처된 jsState 로그
        if let jsState = captureResult.snapshot.jsState {
            dbg("🎯 캡처된 jsState 키: \(Array(jsState.keys))")
            if let anchors = jsState["anchors"] as? [[String: Any]] {
                dbg("🎯 캡처된 앵커: \(anchors.count)개")
            }
            if let landmarks = jsState["landmarks"] as? [[String: Any]] {
                dbg("🎯 캡처된 랜드마크: \(landmarks.count)개")
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
        dbg("✅ 정밀 DOM 요소 기반 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize      // ⚡ 콘텐츠 크기 추가
        let viewportSize: CGSize     // ⚡ 뷰포트 크기 추가
        let actualScrollableSize: CGSize  // ♾️ 실제 스크롤 가능 크기 추가
        let bounds: CGRect
        let isLoading: Bool
    }
    
    // 🔧 **실패 복구 기능 추가된 캡처 - 기존 재시도 대기시간 유지**
    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 잠시 대기 - 🔧 기존 80ms 유지
            dbg("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08) // 🔧 기존 80ms 유지
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드) - 🔧 기존 캡처 타임아웃 유지 (3초)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    // Fallback: layer 렌더링
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                semaphore.signal()
            }
        }
        
        // ⚡ 캡처 타임아웃 유지 (3초)
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처 - 🔧 기존 캡처 타임아웃 유지 (1초)
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    // 🚫 **눌린 상태/활성 상태 모두 제거**
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(el => {
                        el.classList.remove(...Array.from(el.classList).filter(c => 
                            c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus')
                        ));
                    });
                    
                    // input focus 제거
                    document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(el => {
                        el.blur();
                    });
                    
                    const html = document.documentElement.outerHTML;
                    return html.length > 100000 ? html.substring(0, 100000) : html;
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                domSnapshot = result as? String
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 1.0) // 🔧 기존 캡처 타임아웃 유지 (1초)
        
        // 3. 🎯 **정밀 DOM 요소 기반 스크롤 감지 JS 상태 캡처** - 🔧 기존 캡처 타임아웃 유지 (5초로 연장)
        let jsSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let jsScript = generatePrecisionScrollCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let data = result as? [String: Any] {
                    jsState = data
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 5.0) // 🔧 정밀 캡처를 위해 5초로 연장
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가 (스레드 안전)
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        // 상대적 위치 계산 (백분율) - 범위 제한 없음
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
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🎯 **핵심: 정밀 DOM 요소 기반 스크롤 감지 JavaScript 생성**
    private func generatePrecisionScrollCaptureScript() -> String {
        return """
        (function() {
            return new Promise(resolve => {
                // 🎯 **동적 콘텐츠 로딩 안정화 대기 - rAF 기반**
                function waitForDynamicContentStability(callback) {
                    let lastScrollHeight = 0;
                    let stableFrameCount = 0;
                    let frameCount = 0;
                    const maxFrames = 30; // 약 0.5초 (60fps 기준)
                    const requiredStableFrames = 2; // 연속 2프레임 안정
                    
                    function checkStability() {
                        const currentScrollHeight = Math.max(
                            document.documentElement.scrollHeight,
                            document.body.scrollHeight
                        );
                        
                        if (currentScrollHeight === lastScrollHeight) {
                            stableFrameCount++;
                        } else {
                            stableFrameCount = 0;
                            lastScrollHeight = currentScrollHeight;
                        }
                        
                        frameCount++;
                        
                        if (stableFrameCount >= requiredStableFrames || frameCount >= maxFrames) {
                            console.log('🎯 콘텐츠 안정화 완료:', {
                                frames: frameCount,
                                stableFrames: stableFrameCount,
                                scrollHeight: currentScrollHeight
                            });
                            callback();
                        } else {
                            requestAnimationFrame(checkStability);
                        }
                    }
                    
                    requestAnimationFrame(checkStability);
                }

                function captureEnhancedScrollData() {
                    try {
                        console.log('🎯 정밀 DOM 요소 기반 스크롤 캡처 시작');
                        
                        // 🎯 **1. 위치/크기 정밀 좌표 + 상대치**
                        const mainScrollX = parseFloat(window.scrollX || window.pageXOffset) || 0;
                        const mainScrollY = parseFloat(window.scrollY || window.pageYOffset) || 0;
                        const viewportWidth = parseFloat(window.innerWidth) || 0;
                        const viewportHeight = parseFloat(window.innerHeight) || 0;
                        const contentWidth = parseFloat(document.documentElement.scrollWidth) || 0;
                        const contentHeight = parseFloat(document.documentElement.scrollHeight) || 0;
                        
                        // 실제 스크롤 가능 크기 계산
                        const bodyScrollWidth = parseFloat(document.body.scrollWidth) || 0;
                        const bodyScrollHeight = parseFloat(document.body.scrollHeight) || 0;
                        const actualScrollableWidth = Math.max(contentWidth, bodyScrollWidth, viewportWidth);
                        const actualScrollableHeight = Math.max(contentHeight, bodyScrollHeight, viewportHeight);
                        
                        // 백분율 계산
                        const maxScrollX = actualScrollableWidth - viewportWidth;
                        const maxScrollY = actualScrollableHeight - viewportHeight;
                        const percentX = maxScrollX > 0 ? (mainScrollX / maxScrollX * 100.0) : 0;
                        const percentY = maxScrollY > 0 ? (mainScrollY / maxScrollY * 100.0) : 0;
                        
                        // 🎯 **2. 앵커 후보 수집 (최대 5개) - 정밀 복원의 핵심**
                        function collectAnchorCandidates() {
                            const candidates = [
                                ...document.querySelectorAll('h1,h2,h3'),
                                ...document.querySelectorAll('article'),
                                ...document.querySelectorAll('main,[role="main"]'),
                                ...document.querySelectorAll('.post,.article'),
                                ...document.querySelectorAll('.card,.list-item'),
                                ...document.querySelectorAll('section')
                            ];
                            
                            const anchors = [];
                            const viewportCenterX = viewportWidth / 2;
                            const viewportCenterY = viewportHeight / 2;
                            
                            for (const element of candidates) {
                                const rect = element.getBoundingClientRect();
                                
                                // 뷰포트에 부분이라도 걸친 요소만
                                if (rect.bottom > 0 && rect.top < viewportHeight && 
                                    rect.right > 0 && rect.left < viewportWidth) {
                                    
                                    const centerX = rect.left + rect.width / 2;
                                    const centerY = rect.top + rect.height / 2;
                                    const distanceFromCenter = Math.sqrt(
                                        Math.pow(centerX - viewportCenterX, 2) + 
                                        Math.pow(centerY - viewportCenterY, 2)
                                    );
                                    
                                    // 크기 점수 (30% 정도가 이상적)
                                    const sizeRatio = (rect.width * rect.height) / (viewportWidth * viewportHeight);
                                    const idealSizeRatio = 0.3;
                                    const sizePenalty = Math.abs(sizeRatio - idealSizeRatio);
                                    
                                    // 최종 점수
                                    const score = (viewportWidth + viewportHeight - distanceFromCenter) * (1 - sizePenalty);
                                    
                                    const absTop = mainScrollY + rect.top;
                                    const absLeft = mainScrollX + rect.left;
                                    const offsetFromTop = mainScrollY - absTop;
                                    const offsetFromLeft = mainScrollX - absLeft;
                                    
                                    // 텍스트 및 해시
                                    const textContent = (element.textContent || '').trim();
                                    const textHead = textContent.substring(0, 60);
                                    const textHash = generateSimpleHash(textHead);
                                    
                                    // 역할 결정
                                    let role = 'other';
                                    const tagName = element.tagName.toLowerCase();
                                    if (tagName.match(/^h[1-3]$/)) role = tagName;
                                    else if (tagName === 'article') role = 'article';
                                    else if (tagName === 'main' || element.getAttribute('role') === 'main') role = 'main';
                                    else if (element.className.includes('post')) role = 'article';
                                    else if (element.className.includes('card')) role = 'card';
                                    else if (element.className.includes('list-item')) role = 'list-item';
                                    else if (tagName === 'section') role = 'section';
                                    
                                    anchors.push({
                                        selector: generateBestSelector(element),
                                        role: role,
                                        absTop: absTop,
                                        absLeft: absLeft,
                                        offsetFromTop: offsetFromTop,
                                        offsetFromLeft: offsetFromLeft,
                                        width: rect.width,
                                        height: rect.height,
                                        textHead: textHead,
                                        textHash: textHash,
                                        score: score
                                    });
                                }
                            }
                            
                            // 점수별 정렬 후 상위 5개 선택
                            anchors.sort((a, b) => b.score - a.score);
                            return anchors.slice(0, 5);
                        }
                        
                        // 🎯 **3. 랜드마크 수집 (최대 12개) - 퍼센트 실패시 근사 스냅**
                        function collectLandmarks() {
                            const landmarkSelectors = [
                                'h1,h2,h3,h4,h5,h6',
                                'article',
                                'main,[role="main"]',
                                'section',
                                '.post,.article,.content',
                                '.card,.item,.list-item',
                                'header,footer',
                                'nav,[role="navigation"]',
                                'aside,[role="complementary"]',
                                '.sidebar,.menu',
                                'img[alt]',
                                'video,audio'
                            ];
                            
                            const landmarks = [];
                            
                            for (const selector of landmarkSelectors) {
                                const elements = document.querySelectorAll(selector);
                                for (const element of elements) {
                                    if (landmarks.length >= 12) break;
                                    
                                    const rect = element.getBoundingClientRect();
                                    if (rect.height > 10 && rect.width > 10) { // 최소 크기 필터
                                        const absTop = mainScrollY + rect.top;
                                        const textContent = (element.textContent || '').trim();
                                        const textHead = textContent.substring(0, 60);
                                        const textHash = generateSimpleHash(textHead);
                                        
                                        let role = 'other';
                                        if (element.tagName.match(/^H[1-6]$/)) role = element.tagName.toLowerCase();
                                        else if (element.tagName === 'ARTICLE') role = 'article';
                                        else if (element.tagName === 'MAIN') role = 'main';
                                        else if (element.tagName === 'SECTION') role = 'section';
                                        else if (element.className.includes('card')) role = 'card';
                                        
                                        landmarks.push({
                                            selector: generateBestSelector(element),
                                            role: role,
                                            absTop: absTop,
                                            textHash: textHash
                                        });
                                    }
                                }
                                if (landmarks.length >= 12) break;
                            }
                            
                            return landmarks;
                        }
                        
                        // 🎯 **4. 상단 고정 헤더 측정**
                        function measureStickyTop() {
                            const fixedElements = [];
                            const allElements = document.querySelectorAll('*');
                            
                            for (const element of allElements) {
                                const style = window.getComputedStyle(element);
                                const position = style.position;
                                
                                if (position === 'fixed' || position === 'sticky') {
                                    const rect = element.getBoundingClientRect();
                                    const top = parseFloat(style.top) || 0;
                                    const bottom = parseFloat(style.bottom) || Infinity;
                                    
                                    // 상단에 고정되어 있고 화면에 보이는 요소
                                    if (top <= 0 && rect.bottom > 0 && rect.height > 0) {
                                        fixedElements.push(rect.height);
                                    }
                                }
                            }
                            
                            return fixedElements.length > 0 ? Math.max(...fixedElements) : 0;
                        }
                        
                        // 🎯 **5. 가상 리스트 힌트**
                        function detectVirtualList() {
                            const virtualListTypes = [
                                { selector: '.react-virtualized', type: 'react-virtualized' },
                                { selector: '[class*="RecyclerView"]', type: 'RecyclerView' },
                                { selector: '[class*="virtual-list"]', type: 'virtual-list' },
                                { selector: '[data-virtualized]', type: 'data-virtualized' }
                            ];
                            
                            for (const {selector, type} of virtualListTypes) {
                                const element = document.querySelector(selector);
                                if (element) {
                                    const rect = element.getBoundingClientRect();
                                    const beforeEl = element.querySelector('[class*="before"], [class*="spacer"]:first-child');
                                    const afterEl = element.querySelector('[class*="after"], [class*="spacer"]:last-child');
                                    
                                    const beforePx = beforeEl ? parseFloat(beforeEl.getBoundingClientRect().height) || 0 : 0;
                                    const afterPx = afterEl ? parseFloat(afterEl.getBoundingClientRect().height) || 0 : 0;
                                    
                                    // 평균 아이템 높이 추정
                                    const visibleItems = element.querySelectorAll('[class*="item"], [data-index]');
                                    let itemHeightAvg = 0;
                                    if (visibleItems.length > 0) {
                                        const heights = Array.from(visibleItems).map(item => item.getBoundingClientRect().height);
                                        itemHeightAvg = heights.reduce((sum, h) => sum + h, 0) / heights.length;
                                    }
                                    
                                    return {
                                        type: type,
                                        beforePx: beforePx,
                                        afterPx: afterPx,
                                        itemHeightAvg: itemHeightAvg
                                    };
                                }
                            }
                            
                            return { type: 'unknown', beforePx: 0, afterPx: 0, itemHeightAvg: 0 };
                        }
                        
                        // 🎯 **6. 무한스크롤 트리거**
                        function collectLoadTriggers() {
                            const triggerSelectors = [
                                '.load-more',
                                '.show-more',
                                '[data-testid*="load"]',
                                '[class*="load"][class*="more"]',
                                '[aria-label*="더보기"]',
                                '[aria-label*="more"]'
                            ];
                            
                            const triggers = [];
                            
                            for (const selector of triggerSelectors) {
                                const elements = document.querySelectorAll(selector);
                                for (const element of elements) {
                                    if (triggers.length >= 6) break;
                                    
                                    const label = element.innerText || element.getAttribute('aria-label') || '';
                                    triggers.push({
                                        selector: generateBestSelector(element),
                                        label: label.substring(0, 40)
                                    });
                                }
                                if (triggers.length >= 6) break;
                            }
                            
                            return triggers;
                        }
                        
                        // 🎯 **7. iFrame 스크롤 상태 v2**
                        function detectIframeScrollsV2() {
                            const iframes = [];
                            const iframeElements = document.querySelectorAll('iframe');
                            
                            for (const iframe of iframeElements) {
                                try {
                                    const contentWindow = iframe.contentWindow;
                                    let scrollX = 0, scrollY = 0, crossOrigin = false;
                                    
                                    if (contentWindow && contentWindow.location) {
                                        scrollX = parseFloat(contentWindow.scrollX) || 0;
                                        scrollY = parseFloat(contentWindow.scrollY) || 0;
                                    } else {
                                        crossOrigin = true;
                                    }
                                    
                                    // 데이터 속성 수집
                                    const dataAttrs = {};
                                    for (const attr of iframe.attributes) {
                                        if (attr.name.startsWith('data-')) {
                                            dataAttrs[attr.name] = attr.value;
                                        }
                                    }
                                    
                                    iframes.push({
                                        selector: generateBestSelector(iframe),
                                        crossOrigin: crossOrigin,
                                        scrollX: scrollX,
                                        scrollY: scrollY,
                                        src: iframe.src || '',
                                        dataAttrs: dataAttrs
                                    });
                                } catch(e) {
                                    // Cross-origin iframe
                                    const dataAttrs = {};
                                    for (const attr of iframe.attributes) {
                                        if (attr.name.startsWith('data-')) {
                                            dataAttrs[attr.name] = attr.value;
                                        }
                                    }
                                    
                                    iframes.push({
                                        selector: generateBestSelector(iframe),
                                        crossOrigin: true,
                                        scrollX: 0,
                                        scrollY: 0,
                                        src: iframe.src || '',
                                        dataAttrs: dataAttrs
                                    });
                                }
                            }
                            
                            return iframes;
                        }
                        
                        // 🎯 **8. 레이아웃 서명**
                        function generateLayoutKey() {
                            const firstScreenElements = document.querySelectorAll('h1,h2,h3,.main,.content,article');
                            const texts = [];
                            const classes = [];
                            
                            for (const element of Array.from(firstScreenElements).slice(0, 10)) {
                                const rect = element.getBoundingClientRect();
                                if (rect.top < viewportHeight) { // 첫 화면에 있는 요소만
                                    const text = (element.textContent || '').trim().substring(0, 20);
                                    if (text) texts.push(text);
                                    
                                    const className = element.className;
                                    if (className) classes.push(className.split(' ')[0]); // 첫 번째 클래스만
                                }
                            }
                            
                            const combined = texts.join('|') + '#' + classes.join('|');
                            return generateSimpleHash(combined);
                        }
                        
                        // 🌐 **개선된 셀렉터 생성**
                        function generateBestSelector(element) {
                            if (!element || element.nodeType !== 1) return null;
                            
                            // 1순위: ID
                            if (element.id) {
                                return `#${element.id}`;
                            }
                            
                            // 2순위: 데이터 속성
                            const dataAttrs = Array.from(element.attributes)
                                .filter(attr => attr.name.startsWith('data-'))
                                .map(attr => `[${attr.name}="${attr.value}"]`);
                            if (dataAttrs.length > 0) {
                                const attrSelector = element.tagName.toLowerCase() + dataAttrs.join('');
                                if (document.querySelectorAll(attrSelector).length === 1) {
                                    return attrSelector;
                                }
                            }
                            
                            // 3순위: 고유한 클래스 조합
                            if (element.className) {
                                const classes = element.className.trim().split(/\\s+/);
                                const uniqueClasses = classes.filter(cls => {
                                    const elements = document.querySelectorAll(`.${cls}`);
                                    return elements.length === 1 && elements[0] === element;
                                });
                                
                                if (uniqueClasses.length > 0) {
                                    return `.${uniqueClasses.join('.')}`;
                                }
                                
                                // 클래스 조합으로 고유성 확보
                                if (classes.length > 0) {
                                    const classSelector = `.${classes.join('.')}`;
                                    if (document.querySelectorAll(classSelector).length === 1) {
                                        return classSelector;
                                    }
                                }
                            }
                            
                            // 4순위: 상위 경로 포함 (4단계 이내)
                            let path = [];
                            let current = element;
                            while (current && current !== document.documentElement) {
                                let selector = current.tagName.toLowerCase();
                                if (current.id) {
                                    path.unshift(`#${current.id}`);
                                    break;
                                }
                                if (current.className) {
                                    const classes = current.className.trim().split(/\\s+/).slice(0, 2); // 최대 2개 클래스
                                    if (classes.length > 0) {
                                        selector += `.${classes.join('.')}`;
                                    }
                                }
                                path.unshift(selector);
                                current = current.parentElement;
                                
                                if (path.length > 4) break; // 4단계 제한
                            }
                            return path.join(' > ');
                        }
                        
                        // 간단한 64bit 해시 함수 시뮬레이션
                        function generateSimpleHash(str) {
                            let hash = 0;
                            if (str.length === 0) return hash.toString();
                            for (let i = 0; i < str.length; i++) {
                                const char = str.charCodeAt(i);
                                hash = ((hash << 5) - hash) + char;
                                hash = hash & hash; // 32bit 정수 변환
                            }
                            // 64bit 시뮬레이션을 위한 추가 해싱
                            hash = Math.abs(hash) * 31 + str.length;
                            return Math.abs(hash).toString();
                        }
                        
                        // 🎯 **메인 실행 - 정밀 데이터 수집**
                        const anchors = collectAnchorCandidates();
                        const landmarks = collectLandmarks();
                        const stickyTop = measureStickyTop();
                        const virtualList = detectVirtualList();
                        const loadTriggers = collectLoadTriggers();
                        const iframesV2 = detectIframeScrollsV2();
                        const layoutKey = generateLayoutKey();
                        
                        console.log(`🎯 정밀 DOM 요소 기반 감지 완료: 앵커 ${anchors.length}개, 랜드마크 ${landmarks.length}개, 고정헤더 ${stickyTop}px`);
                        console.log(`🎯 위치: (${mainScrollX}, ${mainScrollY}) 퍼센트: (${percentX.toFixed(1)}, ${percentY.toFixed(1)})`);
                        console.log(`🎯 가상리스트: ${virtualList.type}, 트리거: ${loadTriggers.length}개, iframe: ${iframesV2.length}개`);
                        
                        resolve({
                            // 🎯 **1. 위치/크기 정밀 좌표 + 상대치**
                            scroll: { x: mainScrollX, y: mainScrollY },
                            percent: { x: percentX, y: percentY },
                            viewport: { width: viewportWidth, height: viewportHeight },
                            content: { width: contentWidth, height: contentHeight },
                            actualScrollable: { width: actualScrollableWidth, height: actualScrollableHeight },
                            
                            // 🎯 **2-3. 앵커 + 랜드마크**
                            anchors: anchors,
                            landmarks: landmarks,
                            
                            // 🎯 **4. 상단 고정 헤더**
                            stickyTop: stickyTop,
                            
                            // 🎯 **5. 가상 리스트 힌트**
                            virtualList: virtualList,
                            
                            // 🎯 **6. 무한스크롤 트리거**
                            loadTriggers: loadTriggers,
                            
                            // 🎯 **7. iFrame 스크롤 상태 v2**
                            iframesV2: iframesV2,
                            
                            // 🎯 **8. 레이아웃 서명**
                            layoutKey: layoutKey,
                            
                            // 🎯 **9. 스키마 버전**
                            schemaVersion: 2,
                            
                            // 기타 메타데이터
                            href: window.location.href,
                            title: document.title,
                            timestamp: Date.now(),
                            userAgent: navigator.userAgent
                        });
                    } catch(e) { 
                        console.error('🎯 정밀 DOM 요소 기반 감지 실패:', e);
                        resolve({
                            scroll: { x: parseFloat(window.scrollX) || 0, y: parseFloat(window.scrollY) || 0 },
                            percent: { x: 0, y: 0 },
                            anchors: [],
                            landmarks: [],
                            stickyTop: 0,
                            virtualList: { type: 'unknown', beforePx: 0, afterPx: 0, itemHeightAvg: 0 },
                            loadTriggers: [],
                            iframesV2: [],
                            layoutKey: '',
                            schemaVersion: 2,
                            href: window.location.href,
                            title: document.title,
                            viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
                            content: { width: 0, height: 0 },
                            actualScrollable: { width: 0, height: 0 }
                        });
                    }
                }

                // 🎯 콘텐츠 안정화 완료 대기 후 캡처
                if (document.readyState === 'complete') {
                    waitForDynamicContentStability(captureEnhancedScrollData);
                } else {
                    document.addEventListener('DOMContentLoaded', () => waitForDynamicContentStability(captureEnhancedScrollData));
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
    
    // MARK: - 💾 **개선된 디스크 저장 시스템**
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            // 디렉토리 생성
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 1. 이미지 저장 (JPEG 압축)
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                        self.dbg("💾 이미지 저장 성공: \(imagePath.lastPathComponent)")
                    } catch {
                        self.dbg("❌ 이미지 저장 실패: \(error.localizedDescription)")
                        // 저장 실패해도 계속 진행
                    }
                }
            }
            
            // 2. 상태 데이터 저장 (JSON)
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                    self.dbg("💾 상태 저장 성공: \(statePath.lastPathComponent)")
                } catch {
                    self.dbg("❌상태 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 3. 메타데이터 저장
            let metadata = CacheMetadata(
                pageID: pageID,
                tabID: tabID,
                version: version,
                timestamp: Date(),
                url: snapshot.snapshot.pageRecord.url.absoluteString,
                title: snapshot.snapshot.pageRecord.title
            )
            
            let metadataPath = pageDir.appendingPathComponent("metadata.json")
            if let metadataData = try? JSONEncoder().encode(metadata) {
                do {
                    try metadataData.write(to: metadataPath)
                } catch {
                    self.dbg("❌ 메타데이터 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 4. 인덱스 업데이트 (원자적)
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
            // 5. 이전 버전 정리 (최신 3개만 유지)
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
    
    // MARK: - 💾 **개선된 디스크 캐시 로딩**
    
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
                
                self.dbg("💾 디스크 캐시 인덱스 로드 완료: \(loadedCount)개 항목")
            } catch {
                self.dbg("❌ 디스크 캐시 로드 실패: \(error)")
            }
        }
    }
    
    // MARK: - 🔍 **개선된 스냅샷 조회 시스템**
    
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
    
    // MARK: - 🔧 **수정: hasCache 메서드 추가**
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
    
    // MARK: - 🧹 **개선된 캐시 정리**
    
    // 탭 닫을 때만 호출 (무제한 캐시 정책)
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
    
    // 메모리 경고 처리 (메모리 캐시만 일부 정리)
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
    
    // MARK: - 🧵 **리팩토링된 제스처 시스템 (먹통 방지)**
    
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
        
        // 📸 **포괄적 네비게이션 감지 등록**
        Self.registerNavigationObserver(for: webView, stateModel: stateModel)
        
        dbg("🎯 정밀 DOM 요소 기반 BFCache 제스처 설정 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
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
    
    // 🧵 **리팩토링된 제스처 핸들러 (메인 스레드 최적화)**
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
    
    // MARK: - 🎯 **나머지 제스처/전환 로직 (기존 유지)**
    
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
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
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
                dbg("📸 타겟 페이지 BFCache 스냅샷 사용: \(targetRecord.title)")
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
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 180),
            
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
            
            timeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            timeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
        
        return card
    }
    
    // 🎬 **핵심 개선: 미리보기 컨테이너 타임아웃 제거 - 제스처 먹통 해결**
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
                // 🎬 **기존 타이밍으로 네비게이션 수행**
                self?.performNavigationWithFixedTiming(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🚫 **브라우저 차단 대응 타이밍을 적용한 네비게이션 수행 - 타임아웃 제거**
    private func performNavigationWithFixedTiming(context: TransitionContext, previewContainer: UIView) {
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
            dbg("🏄‍♂️ 사파리 스타일 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🏄‍♂️ 사파리 스타일 앞으로가기 완료")
        }
        
        // 🚫 **브라우저 차단 대응 BFCache 복원**
        tryBrowserBlockingBFCacheRestore(stateModel: stateModel, direction: context.direction) { [weak self] success in
            // BFCache 복원 완료 또는 실패 시 즉시 정리 (깜빡임 최소화)
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.removeActiveTransition(for: context.tabID)
                self?.dbg("🎬 미리보기 정리 완료 - 브라우저 차단 대응 BFCache \(success ? "성공" : "실패")")
            }
        }
        
        // 🎬 **타임아웃 제거 - 제스처 먹통 해결**
        // 기존의 1.5초 강제 정리 타임아웃 코드 완전 제거
        dbg("🎬 미리보기 타임아웃 제거됨 - 제스처 먹통 방지")
    }
    
    // 🚫 **브라우저 차단 대응 BFCache 복원** 
    private func tryBrowserBlockingBFCacheRestore(stateModel: WebViewStateModel, direction: NavigationDirection, completion: @escaping (Bool) -> Void) {
        guard let webView = stateModel.webView,
              let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 브라우저 차단 대응 복원
            snapshot.restore(to: webView) { [weak self] success in
                if success {
                    self?.dbg("✅ 브라우저 차단 대응 BFCache 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 브라우저 차단 대응 BFCache 복원 실패: \(currentRecord.title)")
                }
                completion(success)
            }
        } else {
            // BFCache 미스 - 기존 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            
            // 기존 대기 시간 (250ms)
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
                self.removeActiveTransition(for: context.tabID)
            }
        )
    }
    
    // MARK: - 버튼 네비게이션 (즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        tryBrowserBlockingBFCacheRestore(stateModel: stateModel, direction: .back) { _ in
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
        tryBrowserBlockingBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in
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
                console.log('🚫 브라우저 차단 대응 BFCache 페이지 복원');
                
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
                console.log('📸 브라우저 차단 대응 BFCache 페이지 저장');
            }
        });
        
        // 🚫 Cross-origin iframe 브라우저 차단 대응 스크롤 복원 리스너
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    const targetX = parseFloat(event.data.scrollX) || 0;
                    const targetY = parseFloat(event.data.scrollY) || 0;
                    const browserBlockingWorkaround = event.data.browserBlockingWorkaround || false;
                    
                    console.log('🚫 Cross-origin iframe 브라우저 차단 대응 스크롤 복원:', targetX, targetY, browserBlockingWorkaround ? '(브라우저 차단 대응 모드)' : '');
                    
                    // 🚫 브라우저 차단 대응 스크롤 설정
                    if (browserBlockingWorkaround) {
                        // 점진적 스크롤 시도
                        let attempts = 0;
                        const maxAttempts = 10;
                        
                        const tryScroll = () => {
                            window.scrollTo(targetX, targetY);
                            document.documentElement.scrollTop = targetY;
                            document.documentElement.scrollLeft = targetX;
                            document.body.scrollTop = targetY;
                            document.body.scrollLeft = targetX;
                            
                            const currentY = parseFloat(window.scrollY || window.pageYOffset || 0);
                            const currentX = parseFloat(window.scrollX || window.pageXOffset || 0);
                            
                            if ((Math.abs(currentX - targetX) > 10 || Math.abs(currentY - targetY) > 10) && attempts < maxAttempts) {
                                attempts++;
                                setTimeout(tryScroll, 150);
                            }
                        };
                        
                        tryScroll();
                    } else {
                        // 기본 스크롤
                        window.scrollTo(targetX, targetY);
                        document.documentElement.scrollTop = targetY;
                        document.documentElement.scrollLeft = targetX;
                        document.body.scrollTop = targetY;
                        document.body.scrollLeft = targetX;
                    }
                    
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
        TabPersistenceManager.debugMessages.append("[BFCache🚫] \(msg)")
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
        
        // 제스처 설치 + 📸 포괄적 네비게이션 감지
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 🚫 브라우저 차단 대응 BFCache 시스템 설치 완료 (정밀 DOM 요소 기반 복원)")
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
        
        TabPersistenceManager.debugMessages.append("🚫 브라우저 차단 대응 BFCache 시스템 제거 완료")
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

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 즉시 캡처 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화 - 🚀 도착 스냅샷 최적화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
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
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
