//  BFCacheSnapshot.swift
//  📸 BFCache 페이지 스냅샷 (비주얼 미리보기 전용)
//  🎯 복원은 WKWebView.interactionState / webView.goBack()/goForward() 에 위임

import UIKit
import WebKit
import SwiftUI

// MARK: - 📸 BFCache 페이지 스냅샷 (비주얼 미리보기만)
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
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

    enum CodingKeys: String, CodingKey {
        case pageRecord
        case timestamp
        case webViewSnapshotPath
        case captureStatus
        case version
    }

    init(
        pageRecord: PageRecord,
        timestamp: Date,
        webViewSnapshotPath: String? = nil,
        captureStatus: CaptureStatus = .visualOnly,
        version: Int = 1
    ) {
        self.pageRecord = pageRecord
        self.timestamp = timestamp
        self.webViewSnapshotPath = webViewSnapshotPath
        self.captureStatus = captureStatus
        self.version = version
    }

    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 복원
    // 스크롤/상태 복원은 webView.goBack()/goForward() 또는 webView.interactionState 에서 처리
    // 이 함수는 BFCache UI 전환 후 즉시 완료 통보만 함
    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        BFCacheTransitionSystem.shared.setRestoring(false)
        TabPersistenceManager.debugMessages.append("✅ [interactionState] WebKit goBack/goForward 자동 복원")
        completion(true)
    }
}
