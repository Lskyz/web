//
//  BFCacheSnapshotManager.swift
//  📸 **우선순위 기반 BFCache 복원 시스템**
//  🎯 1순위: 요소 id/URL 해시
//  🎯 2순위: 안정적 속성 기반 CSS
//  🎯 3순위: 구조+역할 보강 CSS
//  🎯 4순위: 로딩 트리거 후 재탐색
//  🎯 5순위: 상대좌표 풀백
//  ⚡ 비동기 처리 + 렌더링 안정 대기
//  🔒 타입 안전성: Swift 호환 기본 타입만 사용
//  🐛 JavaScript 타입 에러 수정 - 콜백 구조 유지
//

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 **단순화된 BFCache 페이지 스냅샷**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    let scrollPosition: CGPoint
    let scrollPositionPercent: CGPoint
    let contentSize: CGSize
    let viewportSize: CGSize
    let actualScrollableSize: CGSize
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    enum CaptureStatus: String, Codable {
        case complete
        case partial
        case visualOnly
        case failed
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
    
    // 직접 초기화용 init
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
    
    // MARK: - 🎯 **우선순위 기반 복원 시스템**
    
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        TabPersistenceManager.debugMessages.append("🎯 우선순위 기반 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        
        let js = generatePriorityBasedRestoreScript()
        
        webView.evaluateJavaScript(js) { result, error in
            var success = false
            
            if let error = error {
                TabPersistenceManager.debugMessages.append("❌ 복원 JavaScript 오류: \(error.localizedDescription)")
            } else if let resultDict = result as? [String: Any] {
                success = (resultDict["success"] as? Bool) ?? false
                
                if let method = resultDict["method"] as? String {
                    TabPersistenceManager.debugMessages.append("✅ 복원 방법: \(method)")
                }
                
                if let finalPosition = resultDict["finalPosition"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("📍 최종 위치: X=\(String(format: "%.1f", finalPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
                }
                
                if let difference = resultDict["difference"] as? [String: Double] {
                    TabPersistenceManager.debugMessages.append("📏 위치 차이: X=\(String(format: "%.1f", difference["x"] ?? 0))px, Y=\(String(format: "%.1f", difference["y"] ?? 0))px")
                }
                
                if let logs = resultDict["logs"] as? [String] {
                    for log in logs.prefix(10) {
                        TabPersistenceManager.debugMessages.append("   \(log)")
                    }
                }
            }
            
            TabPersistenceManager.debugMessages.append("🎯 BFCache 복원 완료: \(success ? "성공" : "실패")")
            completion(success)
        }
    }
    
    // MARK: - 🎯 **타입 에러 수정된 우선순위 기반 복원 스크립트**
    
    private func generatePriorityBasedRestoreScript() -> String {
        let targetX = scrollPosition.x
        let targetY = scrollPosition.y
        let targetPercentX = scrollPositionPercent.x
        let targetPercentY = scrollPositionPercent.y
        let urlFragment = pageRecord.url.fragment ?? ""
        
        // jsState에서 앵커 정보 추출
        var anchorDataJSON = "null"
        if let jsState = self.jsState,
           let infiniteScrollAnchorData = jsState["infiniteScrollAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(infiniteScrollAnchorData) {
            anchorDataJSON = dataJSON
        }
        
        return """
        (async function() {
            try {
                const logs = [];
                const targetX = parseFloat('\(targetX)') || 0;
                const targetY = parseFloat('\(targetY)') || 0;
                const targetPercentX = parseFloat('\(targetPercentX)') || 0;
                const targetPercentY = parseFloat('\(targetPercentY)') || 0;
                const urlFragment = '\(urlFragment)';
                const anchorData = \(anchorDataJSON);
                
                logs.push('🎯 우선순위 기반 복원 시작');
                logs.push('목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                logs.push('백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                
                // 🎯 **타입 안전 유틸리티**
                function safeGetNumber(value, fallback) {
                    if (typeof value !== 'number' || isNaN(value) || !isFinite(value)) {
                        return fallback || 0;
                    }
                    return value;
                }
                
                function safeGetElement(selector) {
                    try {
                        if (!selector || typeof selector !== 'string') return null;
                        return document.querySelector(selector);
                    } catch (e) {
                        return null;
                    }
                }
                
                // 🎯 **공통 유틸리티**
                function getROOT() { 
                    return document.scrollingElement || document.documentElement || document.body; 
                }
                
                function getMaxScroll() { 
                    const r = getROOT();
                    if (!r) return { x: 0, y: 0 };
                    
                    const maxX = Math.max(0, (r.scrollWidth || 0) - (window.innerWidth || 0));
                    const maxY = Math.max(0, (r.scrollHeight || 0) - (window.innerHeight || 0));
                    
                    return { 
                        x: safeGetNumber(maxX, 0),
                        y: safeGetNumber(maxY, 0)
                    }; 
                }
                
                // 🎯 **렌더링 안정 대기 (타입 안전 콜백)**
                function waitForStableLayout(options, callback) {
                    const frames = safeGetNumber(options.frames, 6);
                    const timeout = safeGetNumber(options.timeout, 2000);
                    const threshold = safeGetNumber(options.threshold, 2);
                    
                    const ROOT = getROOT();
                    if (!ROOT) {
                        callback(false);
                        return;
                    }
                    
                    let last = safeGetNumber(ROOT.scrollHeight, 0);
                    let stable = 0;
                    let rafCount = 0;
                    const maxRaf = Math.ceil(timeout / 16);
                    
                    const checkStability = function() {
                        const h = safeGetNumber(ROOT.scrollHeight, 0);
                        if (Math.abs(h - last) <= threshold) {
                            stable++;
                        } else {
                            stable = 0;
                        }
                        last = h;
                        
                        rafCount++;
                        
                        if (stable >= frames || rafCount >= maxRaf) {
                            callback(stable >= frames);
                        } else {
                            requestAnimationFrame(checkStability);
                        }
                    };
                    
                    requestAnimationFrame(checkStability);
                }
                
                // 🎯 **MutationObserver 안정 대기 (타입 안전 콜백)**
                function waitForDOMStable(options, callback) {
                    const timeout = safeGetNumber(options.timeout, 1000);
                    const stableTime = safeGetNumber(options.stableTime, 300);
                    
                    let timer = null;
                    let timeoutTimer = null;
                    let mutationObs = null;
                    let resizeObs = null;
                    
                    const cleanup = function() {
                        if (timer) clearTimeout(timer);
                        if (timeoutTimer) clearTimeout(timeoutTimer);
                        if (mutationObs) mutationObs.disconnect();
                        if (resizeObs) resizeObs.disconnect();
                    };
                    
                    const markStable = function() {
                        cleanup();
                        callback(true);
                    };
                    
                    const resetTimer = function() {
                        if (timer) clearTimeout(timer);
                        timer = setTimeout(markStable, stableTime);
                    };
                    
                    const ROOT = getROOT();
                    if (!ROOT) {
                        callback(false);
                        return;
                    }
                    
                    try {
                        mutationObs = new MutationObserver(resetTimer);
                        mutationObs.observe(ROOT, { 
                            childList: true, 
                            subtree: true,
                            attributes: false,
                            characterData: false 
                        });
                        
                        resizeObs = new ResizeObserver(resetTimer);
                        resizeObs.observe(ROOT);
                        
                        resetTimer();
                        
                        timeoutTimer = setTimeout(function() {
                            cleanup();
                            callback(false);
                        }, timeout);
                    } catch (e) {
                        cleanup();
                        callback(false);
                    }
                }
                
                // 🎯 **정밀 스크롤 함수 (타입 안전)**
                function preciseScrollTo(x, y) {
                    const ROOT = getROOT();
                    if (!ROOT) {
                        return { x: 0, y: 0, headerAdjustment: 0 };
                    }
                    
                    const safeX = safeGetNumber(x, 0);
                    const safeY = safeGetNumber(y, 0);
                    
                    // scroll-behavior 강제 비활성화
                    const originalBehavior = ROOT.style.scrollBehavior;
                    ROOT.style.scrollBehavior = 'auto';
                    if (document.documentElement) document.documentElement.style.scrollBehavior = 'auto';
                    if (document.body) document.body.style.scrollBehavior = 'auto';
                    
                    // 고정 헤더 높이 보정
                    const headerHeight = fixedHeaderHeight();
                    const adjustedY = Math.max(0, safeY - headerHeight);
                    
                    ROOT.scrollLeft = safeX;
                    ROOT.scrollTop = adjustedY;
                    
                    // 원래 상태로 복원
                    if (originalBehavior) {
                        ROOT.style.scrollBehavior = originalBehavior;
                    }
                    
                    return { 
                        x: safeGetNumber(ROOT.scrollLeft, 0), 
                        y: safeGetNumber(ROOT.scrollTop, 0),
                        headerAdjustment: headerHeight
                    };
                }
                
                function fixedHeaderHeight() {
                    try {
                        const cands = document.querySelectorAll('header, [class*="header"], [class*="gnb"], [class*="navbar"], [class*="nav-bar"]');
                        let h = 0;
                        for (let i = 0; i < cands.length; i++) {
                            const el = cands[i];
                            if (!el) continue;
                            const cs = getComputedStyle(el);
                            if (cs && (cs.position === 'fixed' || cs.position === 'sticky')) {
                                const rect = el.getBoundingClientRect();
                                if (rect) {
                                    h = Math.max(h, safeGetNumber(rect.height, 0));
                                }
                            }
                        }
                        return safeGetNumber(h, 0);
                    } catch (e) {
                        return 0;
                    }
                }
                
                // 🎯 **1순위: 요소 id/URL 해시 (타입 안전 콜백)**
                function tryPriority1_IdHash(callback) {
                    logs.push('🎯 [1순위] 요소 id/URL 해시 시도');
                    
                    if (urlFragment && typeof urlFragment === 'string' && urlFragment.length > 0) {
                        logs.push('URL Fragment: #' + urlFragment);
                        
                        // id로 찾기
                        let targetElement = document.getElementById(urlFragment);
                        
                        // data-anchor로 찾기
                        if (!targetElement) {
                            targetElement = safeGetElement('[data-anchor="' + urlFragment + '"]');
                        }
                        
                        if (targetElement) {
                            const ROOT = getROOT();
                            if (!ROOT) {
                                callback({ success: false });
                                return;
                            }
                            
                            const rect = targetElement.getBoundingClientRect();
                            if (!rect) {
                                callback({ success: false });
                                return;
                            }
                            
                            const absoluteY = safeGetNumber(ROOT.scrollTop, 0) + safeGetNumber(rect.top, 0);
                            
                            const result = preciseScrollTo(0, absoluteY);
                            logs.push('✅ [1순위] 성공: id/해시로 요소 찾음');
                            logs.push('요소 위치: Y=' + absoluteY.toFixed(1) + 'px');
                            
                            callback({
                                success: true,
                                method: 'priority1_id_hash',
                                element: targetElement.tagName + (targetElement.id ? '#' + targetElement.id : ''),
                                result: result
                            });
                            return;
                        }
                        
                        logs.push('❌ [1순위] 실패: id/해시 요소 없음');
                    } else {
                        logs.push('⏭️ [1순위] 스킵: URL Fragment 없음');
                    }
                    
                    callback({ success: false });
                }
                
                // 🎯 **2순위: 안정적 속성 기반 CSS (타입 안전 콜백)**
                function tryPriority2_StableAttributes(callback) {
                    logs.push('🎯 [2순위] 안정적 속성 기반 CSS 시도');
                    
                    if (!anchorData || !anchorData.anchors || !Array.isArray(anchorData.anchors) || anchorData.anchors.length === 0) {
                        logs.push('⏭️ [2순위] 스킵: 앵커 데이터 없음');
                        callback({ success: false });
                        return;
                    }
                    
                    const anchors = anchorData.anchors;
                    logs.push('앵커 데이터: ' + anchors.length + '개');
                    
                    // 안정적 속성을 가진 앵커 우선 탐색
                    for (let i = 0; i < anchors.length; i++) {
                        const anchor = anchors[i];
                        if (!anchor || !anchor.element) continue;
                        
                        let targetElement = null;
                        let matchMethod = '';
                        
                        // data-id로 찾기
                        if (anchor.element.dataset && anchor.element.dataset.id) {
                            targetElement = safeGetElement('[data-id="' + anchor.element.dataset.id + '"]');
                            matchMethod = 'data-id';
                        }
                        
                        // data-anchor로 찾기
                        if (!targetElement && anchor.element.dataset && anchor.element.dataset.anchor) {
                            targetElement = safeGetElement('[data-anchor="' + anchor.element.dataset.anchor + '"]');
                            matchMethod = 'data-anchor';
                        }
                        
                        // data-test-id로 찾기
                        if (!targetElement && anchor.element.dataset && anchor.element.dataset.testId) {
                            targetElement = safeGetElement('[data-test-id="' + anchor.element.dataset.testId + '"]');
                            matchMethod = 'data-test-id';
                        }
                        
                        // itemid로 찾기
                        if (!targetElement && anchor.element.itemId) {
                            targetElement = safeGetElement('[itemid="' + anchor.element.itemId + '"]');
                            matchMethod = 'itemid';
                        }
                        
                        if (targetElement) {
                            const ROOT = getROOT();
                            if (!ROOT) continue;
                            
                            const rect = targetElement.getBoundingClientRect();
                            if (!rect) continue;
                            
                            const absoluteY = safeGetNumber(ROOT.scrollTop, 0) + safeGetNumber(rect.top, 0);
                            
                            const result = preciseScrollTo(0, absoluteY);
                            logs.push('✅ [2순위] 성공: ' + matchMethod + '로 요소 찾음');
                            
                            callback({
                                success: true,
                                method: 'priority2_stable_attr_' + matchMethod,
                                result: result
                            });
                            return;
                        }
                    }
                    
                    logs.push('❌ [2순위] 실패: 안정적 속성 매칭 없음');
                    callback({ success: false });
                }
                
                // 🎯 **3순위: 구조+역할 보강 CSS (타입 안전 콜백)**
                function tryPriority3_StructuralRole(callback) {
                    logs.push('🎯 [3순위] 구조+역할 보강 CSS 시도');
                    
                    if (!anchorData || !anchorData.anchors || !Array.isArray(anchorData.anchors) || anchorData.anchors.length === 0) {
                        logs.push('⏭️ [3순위] 스킵: 앵커 데이터 없음');
                        callback({ success: false });
                        return;
                    }
                    
                    const anchors = anchorData.anchors;
                    
                    // role, ARIA 속성을 가진 앵커 탐색
                    for (let i = 0; i < anchors.length; i++) {
                        const anchor = anchors[i];
                        if (!anchor || !anchor.element) continue;
                        
                        let targetElement = null;
                        let matchMethod = '';
                        
                        // role로 찾기
                        if (anchor.element.role) {
                            try {
                                const roleElements = document.querySelectorAll('[role="' + anchor.element.role + '"]');
                                if (roleElements && roleElements.length > 0) {
                                    // 텍스트 내용으로 추가 매칭
                                    for (let j = 0; j < roleElements.length; j++) {
                                        const elem = roleElements[j];
                                        if (elem && anchor.textContent && elem.textContent && 
                                            elem.textContent.includes(anchor.textContent.substring(0, 50))) {
                                            targetElement = elem;
                                            matchMethod = 'role_with_text';
                                            break;
                                        }
                                    }
                                    if (!targetElement) {
                                        targetElement = roleElements[0];
                                        matchMethod = 'role';
                                    }
                                }
                            } catch (e) {
                                // 쿼리 실패 시 계속 진행
                            }
                        }
                        
                        // aria-labelledby로 찾기
                        if (!targetElement && anchor.element.ariaLabelledBy) {
                            targetElement = safeGetElement('[aria-labelledby="' + anchor.element.ariaLabelledBy + '"]');
                            matchMethod = 'aria-labelledby';
                        }
                        
                        if (targetElement) {
                            const ROOT = getROOT();
                            if (!ROOT) continue;
                            
                            const rect = targetElement.getBoundingClientRect();
                            if (!rect) continue;
                            
                            const absoluteY = safeGetNumber(ROOT.scrollTop, 0) + safeGetNumber(rect.top, 0);
                            
                            const result = preciseScrollTo(0, absoluteY);
                            logs.push('✅ [3순위] 성공: ' + matchMethod + '로 요소 찾음');
                            
                            callback({
                                success: true,
                                method: 'priority3_structural_' + matchMethod,
                                result: result
                            });
                            return;
                        }
                    }
                    
                    logs.push('❌ [3순위] 실패: 구조+역할 매칭 없음');
                    callback({ success: false });
                }
                
                // 🎯 **4순위: 로딩 트리거 후 재탐색 (타입 안전 콜백)**
                function tryPriority4_LoadingTrigger(callback) {
                    logs.push('🎯 [4순위] 로딩 트리거 후 재탐색 시도');
                    
                    try {
                        // 더보기 버튼 찾기
                        const loadMoreButtons = document.querySelectorAll(
                            '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                            'button[class*="more"], .load-more, .show-more, ' +
                            '[aria-label*="more"], [aria-label*="load"]'
                        );
                        
                        if (loadMoreButtons && loadMoreButtons.length > 0) {
                            logs.push('더보기 버튼 발견: ' + loadMoreButtons.length + '개');
                            
                            // 버튼 클릭
                            let clicked = 0;
                            for (let i = 0; i < Math.min(3, loadMoreButtons.length); i++) {
                                const btn = loadMoreButtons[i];
                                if (btn && typeof btn.click === 'function') {
                                    btn.click();
                                    clicked++;
                                }
                            }
                            
                            if (clicked > 0) {
                                logs.push('더보기 버튼 클릭: ' + clicked + '개');
                                
                                // 렌더링 안정 대기
                                waitForStableLayout({ frames: 4, timeout: 1500 }, function(stable1) {
                                    waitForDOMStable({ timeout: 800, stableTime: 200 }, function(stable2) {
                                        logs.push('렌더링 안정 대기 완료');
                                        
                                        // 재탐색: 2순위 재시도
                                        tryPriority2_StableAttributes(function(retry2) {
                                            if (retry2.success) {
                                                logs.push('✅ [4순위] 성공: 로딩 후 2순위 재탐색');
                                                callback({
                                                    success: true,
                                                    method: 'priority4_loading_retry2',
                                                    result: retry2.result
                                                });
                                                return;
                                            }
                                            
                                            // 3순위 재시도
                                            tryPriority3_StructuralRole(function(retry3) {
                                                if (retry3.success) {
                                                    logs.push('✅ [4순위] 성공: 로딩 후 3순위 재탐색');
                                                    callback({
                                                        success: true,
                                                        method: 'priority4_loading_retry3',
                                                        result: retry3.result
                                                    });
                                                    return;
                                                }
                                                
                                                logs.push('❌ [4순위] 실패: 로딩 트리거 후에도 매칭 없음');
                                                callback({ success: false });
                                            });
                                        });
                                    });
                                });
                                return;
                            }
                        }
                    } catch (e) {
                        logs.push('❌ [4순위] 오류: ' + e.message);
                    }
                    
                    logs.push('❌ [4순위] 실패: 로딩 트리거 없음');
                    callback({ success: false });
                }
                
                // 🎯 **5순위: 상대좌표 풀백 (타입 안전 콜백)**
                function tryPriority5_RelativePosition(callback) {
                    logs.push('🎯 [5순위] 상대좌표 풀백 시도');
                    
                    // 렌더링 안정 대기
                    waitForStableLayout({ frames: 3, timeout: 1000 }, function(stable) {
                        const max = getMaxScroll();
                        
                        // 백분율 기반 복원
                        const calcX = (targetPercentX / 100) * max.x;
                        const calcY = (targetPercentY / 100) * max.y;
                        
                        logs.push('백분율 계산: X=' + calcX.toFixed(1) + 'px, Y=' + calcY.toFixed(1) + 'px');
                        
                        const result = preciseScrollTo(calcX, calcY);
                        
                        logs.push('✅ [5순위] 상대좌표 풀백 적용');
                        
                        callback({
                            success: true,
                            method: 'priority5_relative_position',
                            result: result
                        });
                    });
                }
                
                // 🎯 **메인 실행 로직 - 콜백 체인**
                
                // 1순위 시도
                tryPriority1_IdHash(function(result1) {
                    if (result1.success) {
                        const diffX = Math.abs(safeGetNumber(result1.result.x, 0) - targetX);
                        const diffY = Math.abs(safeGetNumber(result1.result.y, 0) - targetY);
                        
                        return {
                            success: true,
                            method: result1.method,
                            finalPosition: { x: result1.result.x, y: result1.result.y },
                            difference: { x: diffX, y: diffY },
                            headerAdjustment: result1.result.headerAdjustment || 0,
                            logs: logs
                        };
                    }
                    
                    // 2순위 시도
                    tryPriority2_StableAttributes(function(result2) {
                        if (result2.success) {
                            const diffX = Math.abs(safeGetNumber(result2.result.x, 0) - targetX);
                            const diffY = Math.abs(safeGetNumber(result2.result.y, 0) - targetY);
                            
                            return {
                                success: true,
                                method: result2.method,
                                finalPosition: { x: result2.result.x, y: result2.result.y },
                                difference: { x: diffX, y: diffY },
                                headerAdjustment: result2.result.headerAdjustment || 0,
                                logs: logs
                            };
                        }
                        
                        // 3순위 시도
                        tryPriority3_StructuralRole(function(result3) {
                            if (result3.success) {
                                const diffX = Math.abs(safeGetNumber(result3.result.x, 0) - targetX);
                                const diffY = Math.abs(safeGetNumber(result3.result.y, 0) - targetY);
                                
                                return {
                                    success: true,
                                    method: result3.method,
                                    finalPosition: { x: result3.result.x, y: result3.result.y },
                                    difference: { x: diffX, y: diffY },
                                    headerAdjustment: result3.result.headerAdjustment || 0,
                                    logs: logs
                                };
                            }
                            
                            // 4순위 시도
                            tryPriority4_LoadingTrigger(function(result4) {
                                if (result4.success) {
                                    const diffX = Math.abs(safeGetNumber(result4.result.x, 0) - targetX);
                                    const diffY = Math.abs(safeGetNumber(result4.result.y, 0) - targetY);
                                    
                                    return {
                                        success: true,
                                        method: result4.method,
                                        finalPosition: { x: result4.result.x, y: result4.result.y },
                                        difference: { x: diffX, y: diffY },
                                        headerAdjustment: result4.result.headerAdjustment || 0,
                                        logs: logs
                                    };
                                }
                                
                                // 5순위 시도 (최종 풀백)
                                tryPriority5_RelativePosition(function(result5) {
                                    const diffX = Math.abs(safeGetNumber(result5.result.x, 0) - targetX);
                                    const diffY = Math.abs(safeGetNumber(result5.result.y, 0) - targetY);
                                    
                                    return {
                                        success: diffY <= 50, // 50px 허용 오차
                                        method: result5.method,
                                        finalPosition: { x: result5.result.x, y: result5.result.y },
                                        difference: { x: diffX, y: diffY },
                                        headerAdjustment: result5.result.headerAdjustment || 0,
                                        logs: logs
                                    };
                                });
                            });
                        });
                    });
                });
                
            } catch(e) {
                return {
                    success: false,
                    error: e.message || 'Unknown error',
                    logs: ['우선순위 기반 복원 실패: ' + (e.message || 'Unknown error')]
                };
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

// MARK: - BFCacheTransitionSystem 캐처/복원 확장 (기존 코드 유지)
extension BFCacheTransitionSystem {
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업**
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        TabPersistenceManager.debugMessages.append("📸 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        guard let webView = task.webView else {
            TabPersistenceManager.debugMessages.append("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        TabPersistenceManager.debugMessages.append("📸 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                contentSize: webView.scrollView.contentSize,
                viewportSize: webView.bounds.size,
                actualScrollableSize: CGSize(
                    width: max(webView.scrollView.contentSize.width, webView.scrollView.bounds.width),
                    height: max(webView.scrollView.contentSize.height, webView.scrollView.bounds.height)
                ),
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            return
        }
        
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        TabPersistenceManager.debugMessages.append("✅ 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let viewportSize: CGSize
        let actualScrollableSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var jsState: [String: Any]? = nil
        let semaphore = DispatchSemaphore(value: 0)
        
        TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 시도: \(pageRecord.title)")
        
        // 1. 비주얼 스냅샷
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 성공")
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            TabPersistenceManager.debugMessages.append("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처
        let domSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 시작")
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    document.querySelectorAll('[class*="active"], [class*="pressed"], [class*="hover"], [class*="focus"]').forEach(function(el) {
                        var classList = Array.from(el.classList);
                        var classesToRemove = classList.filter(function(c) {
                            return c.includes('active') || c.includes('pressed') || c.includes('hover') || c.includes('focus');
                        });
                        for (var i = 0; i < classesToRemove.length; i++) {
                            el.classList.remove(classesToRemove[i]);
                        }
                    });
                    
                    document.querySelectorAll('input:focus, textarea:focus, select:focus, button:focus').forEach(function(el) {
                        el.blur();
                    });
                    
                    var html = document.documentElement.outerHTML;
                    return html.length > 500000 ? html.substring(0, 500000) : html;
                } catch(e) { return null; }
            })()
            """
            
            webView.evaluateJavaScript(domScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 실패: \(error.localizedDescription)")
                } else if let dom = result as? String {
                    domSnapshot = dom
                    TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 성공: \(dom.count)문자")
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 5.0)
        
        // 3. JS 상태 캡처
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 시작")
        
        DispatchQueue.main.sync {
            let jsScript = generateAnchorCaptureScript()
            
            webView.evaluateJavaScript(jsScript) { result, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                } else {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 결과 타입 오류: \(type(of: result))")
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 3.0)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && jsState != nil {
            captureStatus = .complete
            TabPersistenceManager.debugMessages.append("✅ 완전 캡처 성공")
        } else if visualSnapshot != nil {
            captureStatus = jsState != nil ? .partial : .visualOnly
            TabPersistenceManager.debugMessages.append("⚡ 부분 캡처 성공: visual=\(visualSnapshot != nil), dom=\(domSnapshot != nil), js=\(jsState != nil)")
        } else {
            captureStatus = .failed
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패")
        }
        
        // 버전 증가
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.height > captureData.viewportSize.height || captureData.actualScrollableSize.width > captureData.viewportSize.width {
            let maxScrollX = max(0, captureData.actualScrollableSize.width - captureData.viewportSize.width)
            let maxScrollY = max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height)
            
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        TabPersistenceManager.debugMessages.append("📊 캡처 완료: 위치=(\(String(format: "%.1f", captureData.scrollPosition.x)), \(String(format: "%.1f", captureData.scrollPosition.y))), 백분율=(\(String(format: "%.2f", scrollPercent.x))%, \(String(format: "%.2f", scrollPercent.y))%)")
        
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
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🔥 **앵커 캡처 스크립트**
    private func generateAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('📸 앵커 캡처 시작');
                
                function getROOT() { 
                    return document.scrollingElement || document.documentElement; 
                }
                
                const ROOT = getROOT();
                const scrollY = parseFloat(ROOT.scrollTop) || 0;
                const scrollX = parseFloat(ROOT.scrollLeft) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                
                // 보이는 영역의 요소들만 수집
                const anchors = [];
                const viewportRect = {
                    top: scrollY,
                    left: scrollX,
                    bottom: scrollY + viewportHeight,
                    right: scrollX + viewportWidth
                };
                
                // 안정적 속성을 가진 요소들 우선 수집
                const stableSelectors = [
                    '[data-id]', '[data-anchor]', '[data-test-id]', '[itemid]',
                    '[role="listitem"]', '[role="article"]', '[role="main"]',
                    'article', 'section', 'main'
                ];
                
                for (let i = 0; i < stableSelectors.length; i++) {
                    const elements = document.querySelectorAll(stableSelectors[i]);
                    for (let j = 0; j < elements.length && anchors.length < 20; j++) {
                        const el = elements[j];
                        const rect = el.getBoundingClientRect();
                        const elementTop = scrollY + rect.top;
                        
                        // 뷰포트 내에 있는지 확인
                        if (elementTop >= viewportRect.top && elementTop <= viewportRect.bottom) {
                            const anchorData = {
                                absolutePosition: { top: elementTop, left: scrollX + rect.left },
                                element: {
                                    tagName: el.tagName,
                                    id: el.id || null,
                                    dataset: {
                                        id: el.dataset.id || null,
                                        anchor: el.dataset.anchor || null,
                                        testId: el.dataset.testId || null
                                    },
                                    role: el.getAttribute('role') || null,
                                    ariaLabelledBy: el.getAttribute('aria-labelledby') || null,
                                    itemId: el.getAttribute('itemid') || null
                                },
                                textContent: (el.textContent || '').trim().substring(0, 100)
                            };
                            anchors.push(anchorData);
                        }
                    }
                }
                
                console.log('📸 앵커 캡처 완료:', anchors.length, '개');
                
                return {
                    infiniteScrollAnchors: {
                        anchors: anchors,
                        stats: { totalAnchors: anchors.length }
                    },
                    scroll: { x: scrollX, y: scrollY },
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now()
                };
            } catch(e) { 
                console.error('📸 앵커 캡처 실패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], stats: {} },
                    scroll: { x: 0, y: 0 },
                    href: window.location.href,
                    error: e.message
                };
            }
        })()
        """
    }
    
    internal func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 🌐 JavaScript 스크립트
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🎯 BFCache 페이지 복원');
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 BFCache 페이지 저장');
            }
        });
        
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
