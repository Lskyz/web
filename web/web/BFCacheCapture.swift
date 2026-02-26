//  BFCacheCapture.swift
//  📸 BFCache 캡처 시스템 (비주얼 스냅샷 전용)
//  DOM/JS 앵커 캡처 제거 — 복원은 interactionState 기반

import UIKit
import WebKit
import SwiftUI

// MARK: - BFCacheTransitionSystem 캡처 확장
extension BFCacheTransitionSystem {

    // MARK: - 캡처 태스크

    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }

    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        if BFCacheTransitionSystem.shared.isRestoring {
            TabPersistenceManager.debugMessages.append("🔒 복원 중 - 캡처 스킵: \(pageRecord.title)")
            return
        }

        guard let webView = webView else {
            TabPersistenceManager.debugMessages.append("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }

        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
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

        TabPersistenceManager.debugMessages.append("📸 캡처 시작: \(task.pageRecord.title)")

        let bounds = DispatchQueue.main.sync { () -> CGRect? in
            guard webView.window != nil, !webView.bounds.isEmpty else {
                TabPersistenceManager.debugMessages.append("⚠️ 웹뷰 준비 안됨 - 캡처 스킵")
                return nil
            }
            return webView.bounds
        }

        guard let bounds = bounds else { return }

        let captureResult = performRobustCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            bounds: bounds,
            retryCount: task.type == .immediate ? 2 : 0
        )

        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }

        TabPersistenceManager.debugMessages.append("✅ 캡처 완료: \(task.pageRecord.title)")
    }

    // MARK: - 캡처 실행

    private func performRobustCapture(pageRecord: PageRecord, webView: WKWebView, bounds: CGRect, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        for attempt in 0...retryCount {
            let result = attemptCapture(pageRecord: pageRecord, webView: webView, bounds: bounds)
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    TabPersistenceManager.debugMessages.append("🔄 재시도 후 캡처 성공 (시도: \(attempt + 1))")
                }
                return result
            }
            TabPersistenceManager.debugMessages.append("⏳ 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1))")
            Thread.sleep(forTimeInterval: 0.08)
        }
        return (BFCacheSnapshot(pageRecord: pageRecord, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }

    private func attemptCapture(pageRecord: PageRecord, webView: WKWebView, bounds: CGRect) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        let semaphore = DispatchSemaphore(value: 0)

        // 비주얼 스냅샷 (메인 스레드)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = bounds
            config.afterScreenUpdates = false

            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 실패, fallback: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                    TabPersistenceManager.debugMessages.append("📸 스냅샷 성공")
                }
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + 3.0)
        if waitResult == .timedOut {
            TabPersistenceManager.debugMessages.append("⏰ 스냅샷 타임아웃")
            visualSnapshot = renderWebViewToImage(webView)
        }

        let captureStatus: BFCacheSnapshot.CaptureStatus = visualSnapshot != nil ? .visualOnly : .failed

        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let current = self._cacheVersion[pageRecord.id] ?? 0
            let next = current + 1
            self._cacheVersion[pageRecord.id] = next
            return next
        }

        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version
        )

        return (snapshot, visualSnapshot)
    }

    internal func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }

    // MARK: - BFCache JavaScript (pageshow/pagehide 훅만)

    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('BFCache pageshow');
            }
        });
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('BFCache pagehide');
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
