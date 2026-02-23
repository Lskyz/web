//  BFCacheCapture.swift
//  📸 BFCache 캡처 시스템

import UIKit
import WebKit
import SwiftUI

// MARK: - BFCacheTransitionSystem 캐처/복원 확장
extension BFCacheTransitionSystem {

    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업 (🚀 무한스크롤 전용 앵커 캡처)**

    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }

    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        // 🔒 **복원 중이면 캡처 스킵**
        if BFCacheTransitionSystem.shared.isRestoring {
            TabPersistenceManager.debugMessages.append("🔒 복원 중 - 캡처 스킵: \(pageRecord.title)")
            return
        }

        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }

        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)

        // 🌐 캡처 대상 사이트 로그
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")

        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
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

        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")

        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }

            // 🎯 **수정: 단일 스크롤러 기준으로 캡처**
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

        // 🔧 **개선된 캡처 로직 - 실패 시 재시도 (기존 타이밍 유지)**
        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0  // immediate는 재시도
        )

        // 🔥 **캡처된 jsState 상세 로깅**
        if let jsState = captureResult.snapshot.jsState {
            TabPersistenceManager.debugMessages.append("🔥 캡처된 jsState 키: \(Array(jsState.keys))")

            if let infiniteScrollAnchors = jsState["infiniteScrollAnchors"] as? [String: Any] {
                TabPersistenceManager.debugMessages.append("🚀 캡처된 무한스크롤 앵커 데이터 키: \(Array(infiniteScrollAnchors.keys))")

                if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                    // 앵커 타입별 카운트
                    let vueComponentCount = anchors.filter { ($0["anchorType"] as? String) == "vueComponent" }.count
                    let contentHashCount = anchors.filter { ($0["anchorType"] as? String) == "contentHash" }.count
                    let virtualIndexCount = anchors.filter { ($0["anchorType"] as? String) == "virtualIndex" }.count
                    let structuralPathCount = anchors.filter { ($0["anchorType"] as? String) == "structuralPath" }.count
                    let intersectionCount = anchors.filter { ($0["anchorType"] as? String) == "intersectionInfo" }.count

                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 타입별: Vue=\(vueComponentCount), Hash=\(contentHashCount), Index=\(virtualIndexCount), Path=\(structuralPathCount), Intersection=\(intersectionCount)")

                    if anchors.count > 0 {
                        let firstAnchor = anchors[0]
                        TabPersistenceManager.debugMessages.append("🚀 첫 번째 앵커 키: \(Array(firstAnchor.keys))")

                        // 📊 **첫 번째 앵커 상세 정보 로깅**
                        if let anchorType = firstAnchor["anchorType"] as? String {
                            TabPersistenceManager.debugMessages.append("📊 첫 앵커 타입: \(anchorType)")

                            switch anchorType {
                            case "vueComponent":
                                if let vueComp = firstAnchor["vueComponent"] as? [String: Any] {
                                    let name = vueComp["name"] as? String ?? "unknown"
                                    let dataV = vueComp["dataV"] as? String ?? "unknown"
                                    let index = vueComp["index"] as? Int ?? -1
                                    TabPersistenceManager.debugMessages.append("📊 Vue 컴포넌트: name=\(name), dataV=\(dataV), index=\(index)")
                                }
                            case "contentHash":
                                if let contentHash = firstAnchor["contentHash"] as? [String: Any] {
                                    let shortHash = contentHash["shortHash"] as? String ?? "unknown"
                                    let textLength = (contentHash["text"] as? String)?.count ?? 0
                                    TabPersistenceManager.debugMessages.append("📊 콘텐츠 해시: hash=\(shortHash), textLen=\(textLength)")
                                }
                            case "virtualIndex":
                                if let virtualIndex = firstAnchor["virtualIndex"] as? [String: Any] {
                                    let listIndex = virtualIndex["listIndex"] as? Int ?? -1
                                    let pageIndex = virtualIndex["pageIndex"] as? Int ?? -1
                                    TabPersistenceManager.debugMessages.append("📊 가상 인덱스: list=\(listIndex), page=\(pageIndex)")
                                }
                            default:
                                break
                            }
                        }

                        if let absolutePos = firstAnchor["absolutePosition"] as? [String: Any] {
                            let top = (absolutePos["top"] as? Double) ?? 0
                            let left = (absolutePos["left"] as? Double) ?? 0
                            TabPersistenceManager.debugMessages.append("📊 첫 앵커 위치: X=\(String(format: "%.1f", left))px, Y=\(String(format: "%.1f", top))px")
                        }
                        if let qualityScore = firstAnchor["qualityScore"] as? Int {
                            TabPersistenceManager.debugMessages.append("📊 첫 앵커 품질점수: \(qualityScore)점")
                        }
                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 데이터 캡처 실패")
                }

                if let stats = infiniteScrollAnchors["stats"] as? [String: Any] {
                    TabPersistenceManager.debugMessages.append("📊 무한스크롤 앵커 수집 통계: \(stats)")
                }
            } else {
                TabPersistenceManager.debugMessages.append("🚀 무한스크롤 앵커 데이터 캡처 실패")
            }
        } else {
            TabPersistenceManager.debugMessages.append("🔥 jsState 캡처 완전 실패 - nil")
        }

        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }

        TabPersistenceManager.debugMessages.append("✅ 무한스크롤 앵커 직렬 캡처 완료: \(task.pageRecord.title)")
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
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 캐처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }

            // 재시도 전 잠시 대기 - 🔧 기존 80ms 유지
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
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

        TabPersistenceManager.debugMessages.append("📸 스냅샷 캡처 시도: \(pageRecord.title)")

        // 1. 비주얼 스냅샷 (메인 스레드) - 🔧 기존 캡처 타임아웃 유지 (3초)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false

            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    // Fallback: layer 렌더링
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 성공")
                }
                semaphore.signal()
            }
        }
        
        // ⚡ 캡처 타임아웃 유지 (3초)
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            TabPersistenceManager.debugMessages.append("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. DOM 캡처 - 🔧 기존 캡처 타임아웃 유지 (1초)
        let domSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🌐 DOM 캡처 시작")
        
        DispatchQueue.main.sync {
            let domScript = """
            (function() {
                try {
                    if (document.readyState !== 'complete') return null;
                    
                    
                    
                    // input focus 제거
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
        _ = domSemaphore.wait(timeout: .now() + 5.0) // 🔧 기존 캡처 타임아웃 유지 (1초)
        
        // 3. ✅ **수정: 무한스크롤 전용 앵커 JS 상태 캡처** 
        let jsSemaphore = DispatchSemaphore(value: 0)
        TabPersistenceManager.debugMessages.append("🚀 무한스크롤 전용 앵커 JS 상태 캡처 시작")

        DispatchQueue.main.sync {
            let jsScript = generateInfiniteScrollAnchorCaptureScript() // 🚀 **수정된: 무한스크롤 전용 앵커 캡처**

            webView.evaluateJavaScript(jsScript) { result, error in

                if let error = error {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 오류: \(error.localizedDescription)")
                } else if let data = result as? [String: Any] {
                    jsState = data
                    TabPersistenceManager.debugMessages.append("✅ JS 상태 캡처 성공: \(Array(data.keys))")
                    
                    // 📊 **상세 캡처 결과 로깅**
                    if let infiniteScrollAnchors = data["infiniteScrollAnchors"] as? [String: Any] {
                        if let anchors = infiniteScrollAnchors["anchors"] as? [[String: Any]] {
                            let vueComponentAnchors = anchors.filter { ($0["anchorType"] as? String) == "vueComponent" }
                            let contentHashAnchors = anchors.filter { ($0["anchorType"] as? String) == "contentHash" }
                            let virtualIndexAnchors = anchors.filter { ($0["anchorType"] as? String) == "virtualIndex" }
                            TabPersistenceManager.debugMessages.append("🚀 JS 캡처된 앵커: 총 \(anchors.count)개 (Vue=\(vueComponentAnchors.count), Hash=\(contentHashAnchors.count), Index=\(virtualIndexAnchors.count))")
                        }
                        if let stats = infiniteScrollAnchors["stats"] as? [String: Any] {
                            TabPersistenceManager.debugMessages.append("📊 무한스크롤 JS 캡처 통계: \(stats)")










                        }




                    }
                } else {
                    TabPersistenceManager.debugMessages.append("🔥 JS 상태 캡처 결과 타입 오류: \(type(of: result))")
                }
                jsSemaphore.signal()
            }
        }
        _ = jsSemaphore.wait(timeout: .now() + 3.0) // 🔧 기존 캡처 타임아웃 유지 (2초)

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

        // 버전 증가 (스레드 안전)
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }

        // 🔧 **수정: 백분율 계산 로직 수정 - OR 조건으로 변경**
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
        TabPersistenceManager.debugMessages.append("📊 스크롤 계산 정보: actualScrollableHeight=\(captureData.actualScrollableSize.height), viewportHeight=\(captureData.viewportSize.height), maxScrollY=\(max(0, captureData.actualScrollableSize.height - captureData.viewportSize.height))")

        // 🔄 **순차 실행 설정 생성**
        let restorationConfig = BFCacheSnapshot.RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: max(captureData.actualScrollableSize.height, captureData.contentSize.height)
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
            captureStatus: captureStatus,
            version: version,
            restorationConfig: restorationConfig
        )

        return (snapshot, visualSnapshot)
    }

    // 🚀 **핵심 수정: 무한스크롤 전용 앵커 캡처 - 제목/목록 태그 위주 수집**
    private func generateInfiniteScrollAnchorCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🚀 무한스크롤 전용 앵커 캡처 시작 (제목/목록 태그 위주)');
                
                // 🎯 **단일 스크롤러 유틸리티 함수들**
                function getROOT() { 
                    return document.scrollingElement || document.documentElement; 
                }
                
                // 📊 **상세 로그 수집**
                const detailedLogs = [];
                const pageAnalysis = {};
                
                // 🎯 **수정: 단일 스크롤러 기준으로 정보 수집**
                const ROOT = getROOT();
                const scrollY = parseFloat(ROOT.scrollTop) || 0;
                const scrollX = parseFloat(ROOT.scrollLeft) || 0;
                const viewportHeight = parseFloat(window.innerHeight) || 0;
                const viewportWidth = parseFloat(window.innerWidth) || 0;
                const contentHeight = parseFloat(ROOT.scrollHeight) || 0;
                const contentWidth = parseFloat(ROOT.scrollWidth) || 0;
                
                detailedLogs.push('🚀 무한스크롤 전용 앵커 캡처 시작 (단일 스크롤러)');
                detailedLogs.push('스크롤 위치: X=' + scrollX.toFixed(1) + 'px, Y=' + scrollY.toFixed(1) + 'px');
                detailedLogs.push('뷰포트 크기: ' + viewportWidth.toFixed(0) + ' x ' + viewportHeight.toFixed(0));
                detailedLogs.push('콘텐츠 크기: ' + contentWidth.toFixed(0) + ' x ' + contentHeight.toFixed(0));
                
                pageAnalysis.scroll = { x: scrollX, y: scrollY };
                pageAnalysis.viewport = { width: viewportWidth, height: viewportHeight };
                pageAnalysis.content = { width: contentWidth, height: contentHeight };
                
                console.log('🚀 기본 정보 (단일 스크롤러):', {
                    scroll: [scrollX, scrollY],
                    viewport: [viewportWidth, viewportHeight],
                    content: [contentWidth, contentHeight]
                });
                
                // 🚀 **SHA256 간단 해시 함수 (콘텐츠 해시용)**
                function simpleHash(str) {
                    let hash = 0;
                    if (str.length === 0) return hash.toString(36);
                    for (let i = 0; i < str.length; i++) {
                        const char = str.charCodeAt(i);
                        hash = ((hash << 5) - hash) + char;
                        hash = hash & hash; // 32비트 정수로 변환
                    }
                    return Math.abs(hash).toString(36);
                }
                
                // 🚀 **수정된: data-v-* 속성 찾기 함수**
                function findDataVAttribute(element) {
                    if (!element || !element.attributes) return null;
                    
                    for (let i = 0; i < element.attributes.length; i++) {
                        const attr = element.attributes[i];
                        if (attr.name.startsWith('data-v-')) {
                            return attr.name;
                        }
                    }
                    return null;
                }
                
                // 🚀 **새로운: 태그 타입별 품질 점수 계산**
                function calculateTagQualityScore(element) {
                    const tagName = element.tagName.toLowerCase();
                    const textLength = (element.textContent || '').trim().length;
                    
                    // 기본 점수 (태그 타입별)
                    let baseScore = 50;
                    
                    // 제목 태그 (최고 점수)
                    if (['h1', 'h2', 'h3', 'h4', 'h5', 'h6'].indexOf(tagName) !== -1) {
                        baseScore = 95;
                    }
                    // 목록 항목 (높은 점수)
                    else if (['li', 'article', 'section'].indexOf(tagName) !== -1) {
                        baseScore = 85;
                    }
                    // 단락 (중간 점수)
                    else if (tagName === 'p') {
                        baseScore = 75;
                    }
                    // 링크 (중간 점수)
                    else if (tagName === 'a') {
                        baseScore = 70;
                    }
                    // 스팬/div (낮은 점수)
                    else if (['span', 'div'].indexOf(tagName) !== -1) {
                        baseScore = 60;
                    }
                    
                    // 텍스트 길이 보너스 (최대 +30점)
                    const lengthBonus = Math.min(30, Math.floor(textLength / 10));
                    
                    return Math.min(100, baseScore + lengthBonus);
                }
                
                // 🚀 **핵심 수정: 제목/목록 태그 + ID/Class 속성 위주로 수집**
                function collectSemanticElements() {
                    const semanticElements = [];

                    // 1. ID 속성이 있는 요소 우선 수집 (텍스트 있는 것만)
                    const elementsWithId = document.querySelectorAll('[id]');
                    for (let i = 0; i < elementsWithId.length; i++) {
                        const elem = elementsWithId[i];
                        const idValue = elem.id;
                        const text = (elem.textContent || '').trim();
                        // 의미있는 ID + 텍스트 20자 이상
                        if (idValue && idValue.length > 2 && idValue.length < 100 && text.length >= 20) {
                            semanticElements.push(elem);
                        }
                    }

                    // 2. data-* 속성이 있는 요소 수집 (텍스트 있는 것만)
                    const dataElements = document.querySelectorAll('[data-id], [data-item-id], [data-article-id], [data-post-id], [data-index], [data-key]');
                    for (let i = 0; i < dataElements.length; i++) {
                        const text = (dataElements[i].textContent || '').trim();
                        if (text.length >= 15) {
                            semanticElements.push(dataElements[i]);
                        }
                    }

                    // 3. 특정 class 패턴 요소 수집 (item, post, article, card 등)
                    const classPatterns = document.querySelectorAll('[class*="item"], [class*="post"], [class*="article"], [class*="card"], [class*="list"], [class*="entry"]');
                    for (let i = 0; i < classPatterns.length; i++) {
                        const text = (classPatterns[i].textContent || '').trim();
                        if (text.length >= 10) {
                            semanticElements.push(classPatterns[i]);
                        }
                    }

                    // 4. 제목 태그 수집
                    const headings = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
                    for (let i = 0; i < headings.length; i++) {
                        semanticElements.push(headings[i]);
                    }

                    // 5. 목록 항목 수집
                    const listItems = document.querySelectorAll('li, article, section');
                    for (let i = 0; i < listItems.length; i++) {
                        const text = (listItems[i].textContent || '').trim();
                        if (text.length >= 10) {
                            semanticElements.push(listItems[i]);
                        }
                    }

                    // 6. 단락 태그 수집 (의미있는 것만)
                    const paragraphs = document.querySelectorAll('p');
                    for (let i = 0; i < paragraphs.length; i++) {
                        const text = (paragraphs[i].textContent || '').trim();
                        if (text.length >= 20) {
                            semanticElements.push(paragraphs[i]);
                        }
                    }

                    // 7. 링크 태그 수집 (의미있는 것만)
                    const links = document.querySelectorAll('a');
                    for (let i = 0; i < links.length; i++) {
                        const text = (links[i].textContent || '').trim();
                        if (text.length >= 5) {
                            semanticElements.push(links[i]);
                        }
                    }

                    detailedLogs.push('의미 있는 요소 수집: ' + semanticElements.length + '개');
                    return semanticElements;
                }
                
                // 🚀 **핵심: 무한스크롤 전용 앵커 수집 (뷰포트 영역별)**
                function collectInfiniteScrollAnchors() {
                    const anchors = [];
                    const anchorStats = {
                        totalCandidates: 0,
                        vueComponentAnchors: 0,
                        contentHashAnchors: 0,
                        virtualIndexAnchors: 0,
                        finalAnchors: 0,
                        regionDistribution: {
                            aboveViewport: 0,
                            viewportUpper: 0,
                            viewportMiddle: 0,
                            viewportLower: 0,
                            belowViewport: 0
                        },
                        tagDistribution: {
                            headings: 0,
                            listItems: 0,
                            paragraphs: 0,
                            links: 0,
                            others: 0
                        }
                    };
                    
                    detailedLogs.push('🚀 무한스크롤 전용 앵커 수집 시작 (제목/목록 태그 위주)');
                    
                    // 🚀 **1. 의미 있는 요소 수집**
                    let allCandidateElements = collectSemanticElements();
                    
                    // 🚀 **2. Vue.js 컴포넌트 요소 추가 수집 (data-v-* 속성)**
                    const allElements = document.querySelectorAll('*');
                    const vueElements = [];
                    for (let i = 0; i < allElements.length; i++) {
                        const elem = allElements[i];
                        // data-v-로 시작하는 속성 찾기
                        if (elem.attributes) {
                            for (let j = 0; j < elem.attributes.length; j++) {
                                if (elem.attributes[j].name.startsWith('data-v-')) {
                                    vueElements.push(elem);
                                    break;
                                }
                            }
                        }
                    }
                    for (let i = 0; i < vueElements.length; i++) {
                        allCandidateElements.push(vueElements[i]);
                    }
                    
                    anchorStats.totalCandidates = allCandidateElements.length;
                    detailedLogs.push('후보 요소 총: ' + allCandidateElements.length + '개');
                    
                    // 🚀 **3. 중복 제거**
                    const uniqueElements = [];
                    const processedElements = new Set();
                    
                    for (let i = 0; i < allCandidateElements.length; i++) {
                        const element = allCandidateElements[i];
                        if (!processedElements.has(element)) {
                            processedElements.add(element);
                            uniqueElements.push(element);
                        }
                    }
                    
                    detailedLogs.push('유효 요소: ' + uniqueElements.length + '개');
                    
                    // 🚀 **4. 뷰포트 영역별 + 뷰포트 밖 요소 수집**
                    detailedLogs.push('🎯 뷰포트 영역별 앵커 수집 시작 (상/중/하 + 밖)');
                    
                    // Y축 기준 절대 위치로 정렬 (위에서 아래로)
                    uniqueElements.sort(function(a, b) {
                        const aRect = a.getBoundingClientRect();
                        const bRect = b.getBoundingClientRect();
                        const aTop = scrollY + aRect.top;
                        const bTop = scrollY + bRect.top;
                        return aTop - bTop;
                    });
                    
                    // 🎯 **영역별 분류 및 수집**
                    const viewportTop = scrollY;
                    const viewportBottom = scrollY + viewportHeight;
                    const viewportUpperBound = viewportTop + (viewportHeight * 0.33);
                    const viewportMiddleBound = viewportTop + (viewportHeight * 0.66);
                    
                    const regionsCollected = {
                        aboveViewport: [],
                        viewportUpper: [],
                        viewportMiddle: [],
                        viewportLower: [],
                        belowViewport: []
                    };
                    
                    for (let i = 0; i < uniqueElements.length; i++) {
                        const element = uniqueElements[i];
                        const rect = element.getBoundingClientRect();
                        const elementTop = scrollY + rect.top;
                        const elementCenter = elementTop + (rect.height / 2);
                        
                        if (elementCenter < viewportTop) {
                            regionsCollected.aboveViewport.push(element);
                        } else if (elementCenter >= viewportTop && elementCenter < viewportUpperBound) {
                            regionsCollected.viewportUpper.push(element);
                        } else if (elementCenter >= viewportUpperBound && elementCenter < viewportMiddleBound) {
                            regionsCollected.viewportMiddle.push(element);
                        } else if (elementCenter >= viewportMiddleBound && elementCenter < viewportBottom) {
                            regionsCollected.viewportLower.push(element);
                        } else {
                            regionsCollected.belowViewport.push(element);
                        }
                    }
                    
                    detailedLogs.push('영역별 요소 수: 위=' + regionsCollected.aboveViewport.length + 
                                    ', 상=' + regionsCollected.viewportUpper.length + 
                                    ', 중=' + regionsCollected.viewportMiddle.length + 
                                    ', 하=' + regionsCollected.viewportLower.length + 
                                    ', 아래=' + regionsCollected.belowViewport.length);
                    
                    // 🎯 **각 영역에서 골고루 선택 (총 60개 목표)**
                    const selectedElements = [];
                    const perRegion = 12;
                    
                    const aboveSelected = regionsCollected.aboveViewport.slice(-perRegion);
                    selectedElements.push(...aboveSelected);
                    
                    const upperSelected = regionsCollected.viewportUpper.slice(0, perRegion);
                    selectedElements.push(...upperSelected);
                    
                    const middleSelected = regionsCollected.viewportMiddle.slice(0, perRegion);
                    selectedElements.push(...middleSelected);
                    
                    const lowerSelected = regionsCollected.viewportLower.slice(0, perRegion);
                    selectedElements.push(...lowerSelected);
                    
                    const belowSelected = regionsCollected.belowViewport.slice(0, perRegion);
                    selectedElements.push(...belowSelected);
                    
                    detailedLogs.push('영역별 선택: 위=' + aboveSelected.length + 
                                    ', 상=' + upperSelected.length + 
                                    ', 중=' + middleSelected.length + 
                                    ', 하=' + lowerSelected.length + 
                                    ', 아래=' + belowSelected.length);
                    detailedLogs.push('총 선택: ' + selectedElements.length + '개');
                    
                    // 🚀 **5. 앵커 생성**
                    for (let i = 0; i < selectedElements.length; i++) {
                        try {
                            const element = selectedElements[i];
                            const rect = element.getBoundingClientRect();
                            const absoluteTop = scrollY + rect.top;
                            const absoluteLeft = scrollX + rect.left;
                            const offsetFromTop = scrollY - absoluteTop;
                            const textContent = (element.textContent || '').trim();
                            const tagName = element.tagName.toLowerCase();

                            // ID/Class/data-* 속성 수집
                            const elementId = element.id || null;
                            const elementClasses = element.className ? Array.from(element.classList) : [];
                            const dataAttributes = {};
                            if (element.attributes) {
                                for (let j = 0; j < element.attributes.length; j++) {
                                    const attr = element.attributes[j];
                                    if (attr.name.startsWith('data-')) {
                                        dataAttributes[attr.name] = attr.value;
                                    }
                                }
                            }

                            // 태그 타입 통계
                            if (['h1', 'h2', 'h3', 'h4', 'h5', 'h6'].indexOf(tagName) !== -1) {
                                anchorStats.tagDistribution.headings++;
                            } else if (['li', 'article', 'section'].indexOf(tagName) !== -1) {
                                anchorStats.tagDistribution.listItems++;
                            } else if (tagName === 'p') {
                                anchorStats.tagDistribution.paragraphs++;
                            } else if (tagName === 'a') {
                                anchorStats.tagDistribution.links++;
                            } else {
                                anchorStats.tagDistribution.others++;
                            }

                            // 영역 판정
                            const elementCenter = absoluteTop + (rect.height / 2);
                            let region = 'unknown';
                            if (elementCenter < viewportTop) {
                                region = 'above';
                                anchorStats.regionDistribution.aboveViewport++;
                            } else if (elementCenter < viewportUpperBound) {
                                region = 'upper';
                                anchorStats.regionDistribution.viewportUpper++;
                            } else if (elementCenter < viewportMiddleBound) {
                                region = 'middle';
                                anchorStats.regionDistribution.viewportMiddle++;
                            } else if (elementCenter < viewportBottom) {
                                region = 'lower';
                                anchorStats.regionDistribution.viewportLower++;
                            } else {
                                region = 'below';
                                anchorStats.regionDistribution.belowViewport++;
                            }

                            // 품질 점수 계산
                            const qualityScore = calculateTagQualityScore(element);
                            
                            // 공통 앵커 데이터 (모든 타입에 ID/Class 포함)
                            const commonAnchorData = {
                                absolutePosition: { top: absoluteTop, left: absoluteLeft },
                                viewportPosition: { top: rect.top, left: rect.left },
                                offsetFromTop: offsetFromTop,
                                size: { width: rect.width, height: rect.height },
                                textContent: textContent.substring(0, 100),
                                qualityScore: qualityScore,
                                anchorIndex: i,
                                region: region,
                                tagName: tagName,
                                elementId: elementId,
                                elementClasses: elementClasses,
                                dataAttributes: dataAttributes,
                                captureTimestamp: Date.now()
                            };

                            // Vue Component 앵커
                            const dataVAttr = findDataVAttribute(element);
                            if (dataVAttr) {
                                const vueComponent = {
                                    name: 'unknown',
                                    dataV: dataVAttr,
                                    props: {},
                                    index: i
                                };

                                const classList = Array.from(element.classList);
                                for (let j = 0; j < classList.length; j++) {
                                    const className = classList[j];
                                    if (className.length > 3) {
                                        vueComponent.name = className;
                                        break;
                                    }
                                }

                                if (element.parentElement) {
                                    const siblingIndex = Array.from(element.parentElement.children).indexOf(element);
                                    vueComponent.index = siblingIndex;
                                }

                                anchors.push(Object.assign({}, commonAnchorData, {
                                    anchorType: 'vueComponent',
                                    vueComponent: vueComponent
                                }));
                                anchorStats.vueComponentAnchors++;
                            }

                            // Content Hash 앵커
                            const fullHash = simpleHash(textContent);
                            const shortHash = fullHash.substring(0, 8);

                            anchors.push(Object.assign({}, commonAnchorData, {
                                anchorType: 'contentHash',
                                contentHash: {
                                    fullHash: fullHash,
                                    shortHash: shortHash,
                                    text: textContent.substring(0, 100),
                                    length: textContent.length
                                }
                            }));
                            anchorStats.contentHashAnchors++;

                            // Virtual Index 앵커
                            anchors.push(Object.assign({}, commonAnchorData, {
                                anchorType: 'virtualIndex',
                                virtualIndex: {
                                    listIndex: i,
                                    pageIndex: Math.floor(i / 12),
                                    offsetInPage: absoluteTop,
                                    estimatedTotal: selectedElements.length
                                }
                            }));
                            anchorStats.virtualIndexAnchors++;
                            
                        } catch(e) {
                            console.warn('앵커[' + i + '] 생성 실패:', e);
                        }
                    }
                    
                    anchorStats.finalAnchors = anchors.length;
                    
                    detailedLogs.push('무한스크롤 앵커 생성 완료: ' + anchors.length + '개');
                    detailedLogs.push('태그별 앵커 분포: 제목=' + anchorStats.tagDistribution.headings + 
                                    ', 목록=' + anchorStats.tagDistribution.listItems + 
                                    ', 단락=' + anchorStats.tagDistribution.paragraphs + 
                                    ', 링크=' + anchorStats.tagDistribution.links + 
                                    ', 기타=' + anchorStats.tagDistribution.others);
                    console.log('🚀 무한스크롤 앵커 수집 완료:', anchors.length, '개');
                    
                    return {
                        anchors: anchors,
                        stats: anchorStats
                    };
                }
                
                // 🚀 **메인 실행**
                const startTime = Date.now();
                const infiniteScrollAnchorsData = collectInfiniteScrollAnchors();
                const endTime = Date.now();
                const captureTime = endTime - startTime;
                
                pageAnalysis.capturePerformance = {
                    totalTime: captureTime,
                    anchorsPerSecond: infiniteScrollAnchorsData.anchors.length > 0 ? (infiniteScrollAnchorsData.anchors.length / (captureTime / 1000)).toFixed(2) : 0
                };
                
                detailedLogs.push('=== 무한스크롤 전용 앵커 캡처 완료 (' + captureTime + 'ms) ===');
                detailedLogs.push('최종 무한스크롤 앵커: ' + infiniteScrollAnchorsData.anchors.length + '개');
                
                console.log('🚀 무한스크롤 전용 앵커 캡처 완료:', {
                    infiniteScrollAnchorsCount: infiniteScrollAnchorsData.anchors.length,
                    stats: infiniteScrollAnchorsData.stats,
                    captureTime: captureTime
                });
                
                return {
                    infiniteScrollAnchors: infiniteScrollAnchorsData,
                    scroll: { x: scrollX, y: scrollY },
                    href: window.location.href,
                    title: document.title,
                    timestamp: Date.now(),
                    userAgent: navigator.userAgent,
                    viewport: { width: viewportWidth, height: viewportHeight },
                    content: { width: contentWidth, height: contentHeight },
                    actualScrollable: { 
                        width: Math.max(contentWidth, viewportWidth),
                        height: Math.max(contentHeight, viewportHeight)
                    },
                    detailedLogs: detailedLogs,
                    captureStats: infiniteScrollAnchorsData.stats,
                    pageAnalysis: pageAnalysis,
                    captureTime: captureTime
                };
            } catch(e) { 
                console.error('🚀 무한스크롤 전용 앵커 캡처 실패:', e);
                return {
                    infiniteScrollAnchors: { anchors: [], stats: {} },
                    scroll: { 
                        x: parseFloat(document.scrollingElement?.scrollLeft || document.documentElement.scrollLeft) || 0, 
                        y: parseFloat(document.scrollingElement?.scrollTop || document.documentElement.scrollTop) || 0 
                    },
                    href: window.location.href,
                    title: document.title,
                    actualScrollable: { width: 0, height: 0 },
                    error: e.message,
                    detailedLogs: ['무한스크롤 전용 앵커 캡처 실패: ' + e.message],
                    captureStats: { error: e.message },
                    pageAnalysis: { error: e.message }
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
                console.log('🚫 브라우저 차단 대응 BFCache 페이지 복원');
            }
        });

        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 브라우저 차단 대응 BFCache 페이지 저장');
            }
        });

        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
