//  BFCacheSnapshot.swift
//  📸 **순차적 4단계 BFCache 복원 시스템**
//  🎯 **Step 1**: 저장 콘텐츠 높이 복원 (동적 사이트만)
//  📏 **Step 2**: 상대좌표 기반 스크롤 복원 (최우선)
//  🔍 **Step 3**: 무한스크롤 전용 앵커 정밀 복원
//  ✅ **Step 4**: 최종 검증 및 미세 보정
//  ⏰ **렌더링 대기**: 각 단계별 필수 대기시간 적용
//  🔒 **타입 안전성**: Swift 호환 기본 타입만 사용
//  🎯 **단일 스크롤러 최적화**: 검출된 단일 스크롤러만 조작

import UIKit
import WebKit
import SwiftUI


// MARK: - 📸 **무한스크롤 전용 앵커 조합 BFCache 페이지 스냅샷**
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

    // 🔄 **순차 실행 설정**
    let restorationConfig: RestorationConfig

    struct RestorationConfig: Codable {
        let enableContentRestore: Bool      // Step 1 활성화
        let enablePercentRestore: Bool      // Step 2 활성화
        let enableAnchorRestore: Bool       // Step 3 활성화
        let enableFinalVerification: Bool   // Step 4 활성화
        let savedContentHeight: CGFloat     // 저장 시점 콘텐츠 높이

        static let `default` = RestorationConfig(
            enableContentRestore: true,
            enablePercentRestore: true,
            enableAnchorRestore: true,
            enableFinalVerification: true,
            savedContentHeight: 0
        )
    }

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
        case restorationConfig
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
        restorationConfig = try container.decodeIfPresent(RestorationConfig.self, forKey: .restorationConfig) ?? RestorationConfig.default

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
        try container.encode(restorationConfig, forKey: .restorationConfig)

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
    init(
        pageRecord: PageRecord, 
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
        version: Int = 1,
        restorationConfig: RestorationConfig = RestorationConfig.default
    ) {
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
        self.restorationConfig = RestorationConfig(
            enableContentRestore: restorationConfig.enableContentRestore,
            enablePercentRestore: restorationConfig.enablePercentRestore,
            enableAnchorRestore: restorationConfig.enableAnchorRestore,
            enableFinalVerification: restorationConfig.enableFinalVerification,
            savedContentHeight: max(actualScrollableSize.height, contentSize.height)
        )
    }

    // 이미지 로드 메서드
    func loadImage() -> UIImage? {
        guard let path = webViewSnapshotPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - 🎯 **핵심: 순차적 4단계 복원 시스템**

    private static var activeRestoreTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private static var activeRestoreTokens: [ObjectIdentifier: UUID] = [:]

    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.restore(to: webView, completion: completion)
            }
            return
        }

        let webViewID = ObjectIdentifier(webView)
        let token = UUID()

        if let previous = Self.activeRestoreTasks[webViewID] {
            previous.cancel()
            TabPersistenceManager.debugMessages.append("🛑 이전 BFCache 복원 작업 취소")
        }
        Self.activeRestoreTokens[webViewID] = token

        // 🔒 **복원 시작 - 캡처 방지 플래그 설정**
        BFCacheTransitionSystem.shared.setRestoring(true)

        let totalStartTime = Date()
        TabPersistenceManager.debugMessages.append("🎯 순차적 4단계 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장 콘텐츠 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")

        let task = Task { @MainActor in
            defer {
                if Self.activeRestoreTokens[webViewID] == token {
                    Self.activeRestoreTasks[webViewID] = nil
                    Self.activeRestoreTokens[webViewID] = nil
                }
                let totalTime = Date().timeIntervalSince(totalStartTime)
                TabPersistenceManager.debugMessages.append("⏱️ 전체 복원 소요 시간: \(String(format: "%.1f", totalTime))초")
            }

            let success = await self.runRestorePipeline(on: webView, webViewID: webViewID, token: token)
            guard Self.activeRestoreTokens[webViewID] == token else { return }
            completion(success)
        }

        Self.activeRestoreTasks[webViewID] = task
    }

    @MainActor
    private func runRestorationScriptAsync(_ script: String, on webView: WKWebView, stepLabel: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page)
        try Task.checkCancellation()

        if let dict = dictionaryFromResult(result, stepLabel: stepLabel) {
            return dict
        }

        throw NSError(
            domain: "BFCacheSwipeTransition",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "\(stepLabel) JSON 파싱 실패"]
        )
    }





    private func doubleValue(from value: Any?) -> Double? {
        if let number = value as? NSNumber {

            return number.doubleValue
        }
        return value as? Double



    }

    private func describeJSONValue(_ value: Any?) -> String {
        guard let value = value else { return "nil" }
        if let dict = value as? [AnyHashable: Any] {
            let keys = dict.keys.compactMap { $0 as? String }
            return "dict(keys: \(keys))"
        }
        if let array = value as? [Any] {
            return "array(count: \(array.count))"
        }
        return "\(type(of: value)): \(String(describing: value))"
    }

    private func doubleDictionary(from value: Any?) -> [String: Double]? {
        func convert(from dictionary: [AnyHashable: Any]) -> [String: Double] {
            var result: [String: Double] = [:]
            for (key, element) in dictionary {
                guard let keyString = key as? String else { continue }
                if let number = element as? NSNumber {
                    result[keyString] = number.doubleValue
                } else if let double = element as? Double {
                    result[keyString] = double
                }
            }
            return result
        }

        if let dictionary = value as? [String: Any] {
            let converted = convert(from: dictionary)
            return converted.isEmpty ? nil : converted
        }
        if let dictionary = value as? [AnyHashable: Any] {
            let converted = convert(from: dictionary)
            return converted.isEmpty ? nil : converted
        }
        if let dictionary = value as? NSDictionary {
            let converted = convert(from: dictionary as! [AnyHashable: Any])
            return converted.isEmpty ? nil : converted






        }
        return nil
    }
    private func dictionaryFromResult(_ result: Any?, stepLabel: String) -> [String: Any]? {
        if let dict = result as? [String: Any] {

            return dict
        }
        if let jsonString = result as? String {
            if let data = jsonString.data(using: .utf8) {
                do {
                    if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return dict
                    } else {
                        TabPersistenceManager.debugMessages.append("WARNING \(stepLabel) JSON decode failed: unexpected structure")
                    }
                } catch {
                    TabPersistenceManager.debugMessages.append("WARNING \(stepLabel) JSON decode failed: \(error.localizedDescription)")
                }
            } else {




                TabPersistenceManager.debugMessages.append("WARNING \(stepLabel) JSON string encoding failed")






            }

        }
        return nil
    }


    private func logDictionaryParseFailure(stepLabel: String, key: String, value: Any?) {
        let description: String
        if let value = value {
            description = "type=\(String(describing: type(of: value))), value=\(String(describing: value))"
        } else {
            description = "value=nil"
        }
        TabPersistenceManager.debugMessages.append("⚠️ \(stepLabel) \(key) 파싱 실패 → \(description)")
    }

    @MainActor
    private func runRestorePipeline(on webView: WKWebView, webViewID: ObjectIdentifier, token: UUID) async -> Bool {
        var overallSuccess = false

        defer {
            if Self.activeRestoreTokens[webViewID] == token {
                BFCacheTransitionSystem.shared.setRestoring(false)
                TabPersistenceManager.debugMessages.append("🔓 복원 완료 - 캡처 재개")
            }
        }

        do {
            _ = try await executeStep1_RestoreContentHeightAsync(on: webView)
            try Task.checkCancellation()

            let step2Success = try await executeStep2_PercentScrollAsync(on: webView)
            if step2Success {
                overallSuccess = true
                TabPersistenceManager.debugMessages.append("📏 [Step 2] ✅ 상대좌표 복원 성공 - 전체 복원 성공으로 간주")
            }
            try Task.checkCancellation()

            _ = try await executeStep3_AnchorRestoreAsync(on: webView)
            try Task.checkCancellation()

            let step4Success = try await executeStep4_FinalVerificationAsync(on: webView)
            try Task.checkCancellation()
            let finalSuccess = overallSuccess || step4Success
            TabPersistenceManager.debugMessages.append("🎯 전체 BFCache 복원 완료: \(finalSuccess ? "성공" : "실패")")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                BFCacheTransitionSystem.shared.captureSnapshot(
                    pageRecord: self.pageRecord,
                    webView: webView,
                    type: .immediate
                )
            }
            return finalSuccess
        } catch is CancellationError {
            TabPersistenceManager.debugMessages.append("🛑 BFCache 복원 작업 취소됨")
            return false
        } catch {
            TabPersistenceManager.debugMessages.append("🛑 BFCache 복원 파이프라인 오류: \(error.localizedDescription)")
            return overallSuccess
        }
    }

    // MARK: - Step 1: 저장 콘텐츠 높이 복원
    @MainActor
    private func executeStep1_RestoreContentHeightAsync(on webView: WKWebView) async throws -> Bool {
        let step1StartTime = Date()
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 저장 콘텐츠 높이 복원 시작")
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 목표 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")

        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 비활성화됨 - Step 2 진행")
            return false
        }

        TabPersistenceManager.debugMessages.append("📦 [Step 1] 페이지 안정화 대기 중...")
        try await Task.sleep(nanoseconds: 200_000_000)

        let js = generateStep1_ContentRestoreScript()
        TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 생성 완료: \(js.count)자")

        var step1Success = false
        do {
            let resultDict = try await runRestorationScriptAsync(js, on: webView, stepLabel: "[Step 1]")
            step1Success = (resultDict["success"] as? Bool) ?? false

            if let errorMsg = resultDict["error"] as? String {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] ❌ 에러: \(errorMsg)")
            }
            if let errorStack = resultDict["errorStack"] as? String {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] 스택: \(errorStack)")
            }
            if let currentHeight = doubleValue(from: resultDict["currentHeight"]) {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] 현재 높이: \(String(format: "%.0f", currentHeight))px")
            }
            if let savedHeight = doubleValue(from: resultDict["savedContentHeight"]) {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] 저장 시점 높이: \(String(format: "%.0f", savedHeight))px")
            }
            if let restoredHeight = doubleValue(from: resultDict["restoredHeight"]) {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] 복원된 높이: \(String(format: "%.0f", restoredHeight))px")
            }
            if let percentage = doubleValue(from: resultDict["percentage"]) {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] 복원률: \(String(format: "%.1f", percentage))%")
            }
            if let isStatic = resultDict["isStaticSite"] as? Bool, isStatic {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] 정적 사이트 - 콘텐츠 복원 불필요")
            }
            if let logs = resultDict["logs"] as? [String] {
                for log in logs {
                    TabPersistenceManager.debugMessages.append("   \(log)")
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 오류: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                TabPersistenceManager.debugMessages.append("📦 [Step 1] Error Domain: \(nsError.domain)")
                TabPersistenceManager.debugMessages.append("📦 [Step 1] Error Code: \(nsError.code)")
                if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] JS Exception Message: \(message)")
                }
                if let lineNumber = nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? Int {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] JS Exception Line: \(lineNumber)")
                }
                if let columnNumber = nsError.userInfo["WKJavaScriptExceptionColumnNumber"] as? Int {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] JS Exception Column: \(columnNumber)")
                }
            }
        }

        let step1Time = Date().timeIntervalSince(step1StartTime)
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 완료: \(step1Success ? "성공" : "실패") (소요: \(String(format: "%.1f", step1Time))초)")
        return step1Success
    }

    // MARK: - Step 2: 상대좌표 기반 스크롤 (최우선)
    @MainActor
    private func executeStep2_PercentScrollAsync(on webView: WKWebView) async throws -> Bool {
        let step2StartTime = Date()
        TabPersistenceManager.debugMessages.append("📏 [Step 2] 상대좌표 기반 스크롤 복원 시작 (최우선)")

        guard restorationConfig.enablePercentRestore else {
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 비활성화됨 - Step 3 진행")
            return false
        }

        let js = generateStep2_PercentScrollScript()
        var step2Success = false

        do {
            let resultDict = try await runRestorationScriptAsync(js, on: webView, stepLabel: "[Step 2]")
            step2Success = (resultDict["success"] as? Bool) ?? false

            if let targetPercent = doubleDictionary(from: resultDict["targetPercent"]) {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] 목표 백분율: X=\(String(format: "%.2f", targetPercent["x"] ?? 0))%, Y=\(String(format: "%.2f", targetPercent["y"] ?? 0))%")
            } else {
                logDictionaryParseFailure(stepLabel: "[Step 2]", key: "targetPercent", value: resultDict["targetPercent"])
            }
            if let calculatedPosition = doubleDictionary(from: resultDict["calculatedPosition"]) {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] 계산된 위치: X=\(String(format: "%.1f", calculatedPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", calculatedPosition["y"] ?? 0))px")
            }
            if let actualPosition = doubleDictionary(from: resultDict["actualPosition"]) {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] 실제 위치: X=\(String(format: "%.1f", actualPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", actualPosition["y"] ?? 0))px")
            }
            if let difference = doubleDictionary(from: resultDict["difference"]) {
                TabPersistenceManager.debugMessages.append("📏 [Step 2] 위치 차이: X=\(String(format: "%.1f", difference["x"] ?? 0))px, Y=\(String(format: "%.1f", difference["y"] ?? 0))px")
            }
            if let logs = resultDict["logs"] as? [String] {
                for log in logs.prefix(5) {
                    TabPersistenceManager.debugMessages.append("   \(log)")
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            TabPersistenceManager.debugMessages.append("📏 [Step 2] JavaScript 오류: \(error.localizedDescription)")
        }

        let step2Time = Date().timeIntervalSince(step2StartTime)
        TabPersistenceManager.debugMessages.append("📏 [Step 2] 완료: \(step2Success ? "성공" : "실패") (소요: \(String(format: "%.1f", step2Time))초)")
        return step2Success
    }

    // MARK: - Step 3: 무한스크롤 전용 앵커 복원
    @MainActor
    private func executeStep3_AnchorRestoreAsync(on webView: WKWebView) async throws -> Bool {
        let step3StartTime = Date()
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 무한스크롤 전용 앵커 정밀 복원 시작")

        guard restorationConfig.enableAnchorRestore else {
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 비활성화됨 - Step 4 진행")
            return false
        }

        var infiniteScrollAnchorDataJSON = "null"
        if let jsState = self.jsState,
           let infiniteScrollAnchorData = jsState["infiniteScrollAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(infiniteScrollAnchorData) {
            infiniteScrollAnchorDataJSON = dataJSON
        }

        let js = generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: infiniteScrollAnchorDataJSON)
        var step3Success = false

        do {
            let resultDict = try await runRestorationScriptAsync(js, on: webView, stepLabel: "[Step 3]")
            step3Success = (resultDict["success"] as? Bool) ?? false

            if let anchorCount = resultDict["anchorCount"] as? Int {
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] 사용 가능한 앵커: \(anchorCount)개")
            }
            if let matchedAnchor = resultDict["matchedAnchor"] as? [String: Any] {
                if let anchorType = matchedAnchor["anchorType"] as? String {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭된 앵커 타입: \(anchorType)")
                }
                if let method = matchedAnchor["matchMethod"] as? String {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭 방법: \(method)")
                }
                if let confidence = doubleValue(from: matchedAnchor["confidence"]) {
                    TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭 신뢰도: \(String(format: "%.1f", confidence))%")
                }
            }
            if let restoredPosition = doubleDictionary(from: resultDict["restoredPosition"]) {
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] 복원된 위치: X=\(String(format: "%.1f", restoredPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", restoredPosition["y"] ?? 0))px")
            }
            if let targetDifference = doubleDictionary(from: resultDict["targetDifference"]) {
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] 목표와의 차이: X=\(String(format: "%.1f", targetDifference["x"] ?? 0))px, Y=\(String(format: "%.1f", targetDifference["y"] ?? 0))px")
            }
            if let logs = resultDict["logs"] as? [String] {
                for log in logs.prefix(10) {
                    TabPersistenceManager.debugMessages.append("   \(log)")
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] JavaScript 오류: \(error.localizedDescription)")
        }

        let step3Time = Date().timeIntervalSince(step3StartTime)
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 완료: \(step3Success ? "성공" : "실패") (소요: \(String(format: "%.1f", step3Time))초)")
        return step3Success
    }

    // MARK: - Step 4: 최종 검증 및 미세 보정
    @MainActor
    private func executeStep4_FinalVerificationAsync(on webView: WKWebView) async throws -> Bool {
        let step4StartTime = Date()
        TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 검증 및 미세 보정 시작")

        guard restorationConfig.enableFinalVerification else {
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 비활성화됨 - 스킵")
            return false
        }

        let js = generateStep4_FinalVerificationScript()
        var step4Success = false

        do {
            let resultDict = try await runRestorationScriptAsync(js, on: webView, stepLabel: "[Step 4]")
            step4Success = (resultDict["success"] as? Bool) ?? false

            if let finalPosition = doubleDictionary(from: resultDict["finalPosition"]) {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 위치: X=\(String(format: "%.1f", finalPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
            }
            if let targetPosition = doubleDictionary(from: resultDict["targetPosition"]) {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] 목표 위치: X=\(String(format: "%.1f", targetPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", targetPosition["y"] ?? 0))px")
            }
            if let finalDifference = doubleDictionary(from: resultDict["finalDifference"]) {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 차이: X=\(String(format: "%.1f", finalDifference["x"] ?? 0))px, Y=\(String(format: "%.1f", finalDifference["y"] ?? 0))px")
            }
            if let withinTolerance = resultDict["withinTolerance"] as? Bool {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] 허용 오차 내: \(withinTolerance ? "예" : "아니오")")
            }
            if let correctionApplied = resultDict["correctionApplied"] as? Bool, correctionApplied {
                TabPersistenceManager.debugMessages.append("✅ [Step 4] 미세 보정 적용됨")
            }
            if let logs = resultDict["logs"] as? [String] {
                for log in logs.prefix(5) {
                    TabPersistenceManager.debugMessages.append("   \(log)")
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            TabPersistenceManager.debugMessages.append("✅ [Step 4] JavaScript 오류: \(error.localizedDescription)")
        }

        let step4Time = Date().timeIntervalSince(step4StartTime)
        TabPersistenceManager.debugMessages.append("✅ [Step 4] 완료: \(step4Success ? "성공" : "실패") (소요: \(String(format: "%.1f", step4Time))초)")
        return step4Success
    }

}
