//  BFCacheSnapshotManager.swift
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

    // 복원 컨텍스트 구조체
    private struct RestorationContext {
        let snapshot: BFCacheSnapshot
        weak var webView: WKWebView?
        let completion: (Bool) -> Void
        var overallSuccess: Bool = false
    }

    func restore(to webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // 🔒 **복원 시작 - 캡처 방지 플래그 설정**
        BFCacheTransitionSystem.shared.setRestoring(true)

        let totalStartTime = Date()

        TabPersistenceManager.debugMessages.append("🎯 순차적 4단계 BFCache 복원 시작")
        TabPersistenceManager.debugMessages.append("📊 복원 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        TabPersistenceManager.debugMessages.append("📊 목표 위치: X=\(String(format: "%.1f", scrollPosition.x))px, Y=\(String(format: "%.1f", scrollPosition.y))px")
        TabPersistenceManager.debugMessages.append("📊 목표 백분율: X=\(String(format: "%.2f", scrollPositionPercent.x))%, Y=\(String(format: "%.2f", scrollPositionPercent.y))%")
        TabPersistenceManager.debugMessages.append("📊 저장 콘텐츠 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")

        // 복원 컨텍스트 생성
        let context = RestorationContext(
            snapshot: self,
            webView: webView,
            completion: { success in
                let totalTime = Date().timeIntervalSince(totalStartTime)
                TabPersistenceManager.debugMessages.append("⏱️ 전체 복원 소요 시간: \(String(format: "%.1f", totalTime))초")
                completion(success)
            }
        )

        // Step 1 시작
        executeStep1_RestoreContentHeight(context: context)
    }

    private func runRestorationScript(_ script: String, on webView: WKWebView?, completion: @escaping (Any?, Error?) -> Void) {
        guard let webView = webView else {
            let error = NSError(domain: "BFCacheSwipeTransition", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView unavailable"])
            // Ensure completions and logging always occur on main to avoid races
            if Thread.isMainThread {
                completion(nil, error)
            } else {
                DispatchQueue.main.async { completion(nil, error) }
            }
            return
        }
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page, completionHandler: { result in
            let deliver = {
                switch result {
                case .success(let value):
                    completion(value, nil)
                case .failure(let error):
                    completion(nil, error)
                }
            }
            if Thread.isMainThread {
                deliver()
            } else {
                DispatchQueue.main.async { deliver() }
            }
        })
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

    // MARK: - Step 1: 저장 콘텐츠 높이 복원
    private func executeStep1_RestoreContentHeight(context: RestorationContext) {
        let step1StartTime = Date()
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 저장 콘텐츠 높이 복원 시작")
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 목표 높이: \(String(format: "%.0f", restorationConfig.savedContentHeight))px")

        guard restorationConfig.enableContentRestore else {
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 비활성화됨 - 즉시 Step 2 진행")
            self.executeStep2_PercentScroll(context: context)
            return
        }

        // 🛡️ **페이지 안정화 대기 (200ms) - completion handler unreachable 방지**
        TabPersistenceManager.debugMessages.append("📦 [Step 1] 페이지 안정화 대기 중...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.executeStep1_Delayed(context: context, startTime: step1StartTime)
        }
    }

    private func executeStep1_Delayed(context: RestorationContext, startTime: Date) {
        let js = generateStep1_ContentRestoreScript()
        let jsLength = js.count
        TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 생성 완료: \(jsLength)자")


        context.webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            var step1Success = false

            switch result {
            case .success(let value):
                var resultDict: [String: Any]?

                // callAsyncJavaScript는 JSON 문자열로 반환하므로 파싱 필요
                if let jsonString = value as? String,
                   let jsonData = jsonString.data(using: .utf8) {
                    resultDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                } else if let dict = value as? [String: Any] {
                    resultDict = dict
                }

                if let resultDict = resultDict {
                    step1Success = (resultDict["success"] as? Bool) ?? false

                    // 에러 정보가 있으면 먼저 출력
                    if let errorMsg = resultDict["error"] as? String {
                        TabPersistenceManager.debugMessages.append("📦 [Step 1] ❌ 에러: \(errorMsg)")
                    }
                    if let errorStack = resultDict["errorStack"] as? String {
                        TabPersistenceManager.debugMessages.append("📦 [Step 1] 스택: \(errorStack)")
                    }

                    if let currentHeight = resultDict["currentHeight"] as? Double {
                        TabPersistenceManager.debugMessages.append("📦 [Step 1] 현재 높이: \(String(format: "%.0f", currentHeight))px")
                    }
                    if let savedHeight = resultDict["savedContentHeight"] as? Double {
                        TabPersistenceManager.debugMessages.append("📦 [Step 1] 저장 시점 높이: \(String(format: "%.0f", savedHeight))px")
                    }
                    if let restoredHeight = resultDict["restoredHeight"] as? Double {
                        TabPersistenceManager.debugMessages.append("📦 [Step 1] 복원된 높이: \(String(format: "%.0f", restoredHeight))px")
                    }
                    if let percentage = resultDict["percentage"] as? Double {
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
                } else {
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] JSON 파싱 실패")
                }
            case .failure(let error):
                TabPersistenceManager.debugMessages.append("📦 [Step 1] JavaScript 오류: \(error.localizedDescription)")

                // 🔍 **상세 에러 정보 추출**
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
                    if let stackTrace = nsError.userInfo["WKJavaScriptExceptionStackTrace"] as? String {
                        TabPersistenceManager.debugMessages.append("📦 [Step 1] JS Stack Trace: \(stackTrace)")
                    }
                    if let sourceURL = nsError.userInfo["WKJavaScriptExceptionSourceURL"] as? String {
                        TabPersistenceManager.debugMessages.append("📦 [Step 1] JS Source URL: \(sourceURL)")
                    }

                    // 전체 userInfo 출력
                    TabPersistenceManager.debugMessages.append("📦 [Step 1] Full userInfo: \(nsError.userInfo)")
                }
            }

            let step1Time = Date().timeIntervalSince(startTime)
            TabPersistenceManager.debugMessages.append("📦 [Step 1] 완료: \(step1Success ? "성공" : "실패") (소요: \(String(format: "%.1f", step1Time))초)")

            // 🚀 **비동기 실행: delay 제거**
            self.executeStep2_PercentScroll(context: context)
        }
    }

    // MARK: - Step 2: 상대좌표 기반 스크롤 (최우선)
    private func executeStep2_PercentScroll(context: RestorationContext) {
        let step2StartTime = Date()
        TabPersistenceManager.debugMessages.append("📏 [Step 2] 상대좌표 기반 스크롤 복원 시작 (최우선)")

        guard restorationConfig.enablePercentRestore else {
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 비활성화됨 - 즉시 Step 3 진행")
            self.executeStep3_AnchorRestore(context: context)
            return
        }

        let js = generateStep2_PercentScrollScript()

        context.webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            var step2Success = false
            var updatedContext = context

            switch result {
            case .success(let value):
                var resultDict: [String: Any]?

                // callAsyncJavaScript는 JSON 문자열로 반환하므로 파싱 필요
                if let jsonString = value as? String,
                   let jsonData = jsonString.data(using: .utf8) {
                    resultDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                } else if let dict = value as? [String: Any] {
                    resultDict = dict
                }

                if let resultDict = resultDict {
                    step2Success = (resultDict["success"] as? Bool) ?? false

                    if let targetPercent = resultDict["targetPercent"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("📏 [Step 2] 목표 백분율: X=\(String(format: "%.2f", targetPercent["x"] ?? 0))%, Y=\(String(format: "%.2f", targetPercent["y"] ?? 0))%")
                    }
                    if let calculatedPosition = resultDict["calculatedPosition"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("📏 [Step 2] 계산된 위치: X=\(String(format: "%.1f", calculatedPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", calculatedPosition["y"] ?? 0))px")
                    }
                    if let actualPosition = resultDict["actualPosition"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("📏 [Step 2] 실제 위치: X=\(String(format: "%.1f", actualPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", actualPosition["y"] ?? 0))px")
                    }
                    if let difference = resultDict["difference"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("📏 [Step 2] 위치 차이: X=\(String(format: "%.1f", difference["x"] ?? 0))px, Y=\(String(format: "%.1f", difference["y"] ?? 0))px")
                    }
                    if let logs = resultDict["logs"] as? [String] {
                        for log in logs.prefix(5) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }

                    // 상대좌표 복원 성공 시 전체 성공으로 간주
                    if step2Success {
                        updatedContext.overallSuccess = true
                        TabPersistenceManager.debugMessages.append("📏 [Step 2] ✅ 상대좌표 복원 성공 - 전체 복원 성공으로 간주")
                    }
                }
            case .failure(let error):
                TabPersistenceManager.debugMessages.append("📏 [Step 2] JavaScript 오류: \(error.localizedDescription)")
            }

            let step2Time = Date().timeIntervalSince(step2StartTime)
            TabPersistenceManager.debugMessages.append("📏 [Step 2] 완료: \(step2Success ? "성공" : "실패") (소요: \(String(format: "%.1f", step2Time))초)")

            // 🚀 **비동기 실행: delay 제거**
            self.executeStep3_AnchorRestore(context: updatedContext)
        }
    }

    // MARK: - Step 3: 무한스크롤 전용 앵커 복원
    private func executeStep3_AnchorRestore(context: RestorationContext) {
        let step3StartTime = Date()
        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 무한스크롤 전용 앵커 정밀 복원 시작")

        guard restorationConfig.enableAnchorRestore else {
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 비활성화됨 - 즉시 Step 4 진행")
            self.executeStep4_FinalVerification(context: context)
            return
        }

        // 무한스크롤 앵커 데이터 확인
        var infiniteScrollAnchorDataJSON = "null"
        if let jsState = self.jsState,
           let infiniteScrollAnchorData = jsState["infiniteScrollAnchors"] as? [String: Any],
           let dataJSON = convertToJSONString(infiniteScrollAnchorData) {
            infiniteScrollAnchorDataJSON = dataJSON
        }

        let js = generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: infiniteScrollAnchorDataJSON)

        context.webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            var step3Success = false

            switch result {
            case .success(let value):
                var resultDict: [String: Any]?

                // callAsyncJavaScript는 JSON 문자열로 반환하므로 파싱 필요
                if let jsonString = value as? String,
                   let jsonData = jsonString.data(using: .utf8) {
                    resultDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                } else if let dict = value as? [String: Any] {
                    resultDict = dict
                }

                if let resultDict = resultDict {
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
                        if let confidence = matchedAnchor["confidence"] as? Double {
                            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 매칭 신뢰도: \(String(format: "%.1f", confidence))%")
                        }
                    }
                    if let restoredPosition = resultDict["restoredPosition"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 복원된 위치: X=\(String(format: "%.1f", restoredPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", restoredPosition["y"] ?? 0))px")
                    }
                    if let targetDifference = resultDict["targetDifference"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("🔍 [Step 3] 목표와의 차이: X=\(String(format: "%.1f", targetDifference["x"] ?? 0))px, Y=\(String(format: "%.1f", targetDifference["y"] ?? 0))px")
                    }
                    if let logs = resultDict["logs"] as? [String] {
                        for log in logs.prefix(10) {
                            TabPersistenceManager.debugMessages.append("   \(log)")
                        }
                    }
                }
            case .failure(let error):
                TabPersistenceManager.debugMessages.append("🔍 [Step 3] JavaScript 오류: \(error.localizedDescription)")
            }

            let step3Time = Date().timeIntervalSince(step3StartTime)
            TabPersistenceManager.debugMessages.append("🔍 [Step 3] 완료: \(step3Success ? "성공" : "실패") (소요: \(String(format: "%.1f", step3Time))초)")

            // 성공/실패 관계없이 다음 단계 진행
            self.executeStep4_FinalVerification(context: context)
        }
    }

    // MARK: - Step 4: 최종 검증 및 미세 보정
    private func executeStep4_FinalVerification(context: RestorationContext) {
        let step4StartTime = Date()
        TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 검증 및 미세 보정 시작")

        guard restorationConfig.enableFinalVerification else {
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 비활성화됨 - 스킵")
            context.completion(context.overallSuccess)
            return
        }

        let js = generateStep4_FinalVerificationScript()

        context.webView?.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            var step4Success = false

            switch result {
            case .success(let value):
                var resultDict: [String: Any]?

                // callAsyncJavaScript는 JSON 문자열로 반환하므로 파싱 필요
                if let jsonString = value as? String,
                   let jsonData = jsonString.data(using: .utf8) {
                    resultDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                } else if let dict = value as? [String: Any] {
                    resultDict = dict
                }

                if let resultDict = resultDict {
                    step4Success = (resultDict["success"] as? Bool) ?? false

                    if let finalPosition = resultDict["finalPosition"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("✅ [Step 4] 최종 위치: X=\(String(format: "%.1f", finalPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", finalPosition["y"] ?? 0))px")
                    }
                    if let targetPosition = resultDict["targetPosition"] as? [String: Double] {
                        TabPersistenceManager.debugMessages.append("✅ [Step 4] 목표 위치: X=\(String(format: "%.1f", targetPosition["x"] ?? 0))px, Y=\(String(format: "%.1f", targetPosition["y"] ?? 0))px")
                    }
                    if let finalDifference = resultDict["finalDifference"] as? [String: Double] {
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
                }
            case .failure(let error):
                TabPersistenceManager.debugMessages.append("✅ [Step 4] JavaScript 오류: \(error.localizedDescription)")
            }

            let step4Time = Date().timeIntervalSince(step4StartTime)
            TabPersistenceManager.debugMessages.append("✅ [Step 4] 완료: \(step4Success ? "성공" : "실패") (소요: \(String(format: "%.1f", step4Time))초)")

            // 즉시 완료 처리
            let finalSuccess = context.overallSuccess || step4Success
            TabPersistenceManager.debugMessages.append("🎯 전체 BFCache 복원 완료: \(finalSuccess ? "성공" : "실패")")

            // 🔒 **복원 완료 - 캡처 허용**
            BFCacheTransitionSystem.shared.setRestoring(false)
            TabPersistenceManager.debugMessages.append("🔓 복원 완료 - 캡처 재개")

            // 📸 **복원 완료 후 최종 위치 캡처**
            if let webView = context.webView {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    BFCacheTransitionSystem.shared.captureSnapshot(
                        pageRecord: self.pageRecord,
                        webView: webView,
                        type: .immediate
                    )
                }
            }

            context.completion(finalSuccess)
        }
    }

    // MARK: - 🎯 단일 스크롤러 JavaScript 생성 메서드들

    // 🎯 **공통 유틸리티 스크립트 생성**
    private func generateCommonUtilityScript() -> String {
        return """
        // 공통 BFCache 유틸리티 (비동기 기반)
        function getROOT() {
            try {
                if (!document || !document.documentElement) return null;
                return document.scrollingElement || document.documentElement || document.body;
            } catch(e) {
                return null;
            }
        }

        function isElementValid(element) {
            try {
                return element && element.isConnected && element.ownerDocument === document;
            } catch(e) {
                return false;
            }
        }

        function nextFrame() {
            return new Promise(resolve => requestAnimationFrame(() => resolve()));
        }

        function delay(ms = 0) {
            return new Promise(resolve => setTimeout(resolve, ms));
        }

        function getMaxScroll() {
            const root = getROOT();
            const scrollWidth = root ? root.scrollWidth : 0;
            const scrollHeight = root ? root.scrollHeight : 0;
            return {
                x: Math.max(0, scrollWidth - window.innerWidth),
                y: Math.max(0, scrollHeight - window.innerHeight)
            };
        }

        function isScrollable(element) {
            if (!element) return false;
            const cs = getComputedStyle(element);
            if (!cs) return false;
            const overflowY = cs.overflowY || cs.overflow || "";
            const overflowX = cs.overflowX || cs.overflow || "";
            const canScrollY = /(auto|scroll)/i.test(overflowY) && element.scrollHeight > element.clientHeight + 1;
            const canScrollX = /(auto|scroll)/i.test(overflowX) && element.scrollWidth > element.clientWidth + 1;
            return canScrollY || canScrollX;
        }

        function findScrollContainers() {
            const root = getROOT();
            const candidates = [];
            if (root) candidates.push(root);
            if (document.body && document.body !== root) candidates.push(document.body);
            const selector = '[data-scroll-container], main, .content, [class*="scroll"], [class*="Scroll"], [class*="list"], [class*="List"], [role="main"]';
            document.querySelectorAll(selector).forEach(el => {
                if (isScrollable(el)) {
                    candidates.push(el);
                }
            });
            const seen = new Set();
            const unique = [];
            candidates.forEach(el => {
                if (el && !seen.has(el)) {
                    seen.add(el);
                    unique.push(el);
                }
            });
            unique.sort((a, b) => (b.scrollHeight || 0) - (a.scrollHeight || 0));
            return unique.length ? unique : (root ? [root] : []);
        }

        function findSentinel(root) {
            if (!root) return null;
            const selector = [
                '[data-testid*="loader"]',
                '[data-test*="loader"]',
                '[class*="loader"]',
                '[class*="sentinel"]',
                '[id*="sentinel"]',
                '[aria-busy="true"]',
                '.infinite-scroll-component__outerdiv',
                '[data-infinite-scroll]',
                '.load-more',
                '.infinite-loader'
            ].join(',');
            return root.querySelector(selector) || root.lastElementChild || root;
        }

        async function waitForStableLayoutAsync(options = {}) {
            const { frames = 3, timeout = 800, threshold = 2 } = options;
            const root = getROOT();
            if (!root) return;
            let stableFrames = 0;
            let lastHeight = root.scrollHeight;
            const start = Date.now();
            while (Date.now() - start < timeout) {
                await nextFrame();
                const currentHeight = root.scrollHeight;
                if (Math.abs(currentHeight - lastHeight) <= threshold) {
                    stableFrames += 1;
                    if (stableFrames >= frames) {
                        break;
                    }
                } else {
                    stableFrames = 0;
                    lastHeight = currentHeight;
                }
            }
        }

        function optimizeLazyMedia(rootNode = document) {
            if (!rootNode || typeof rootNode.querySelectorAll !== 'function') return 0;
            let optimized = 0;
            const media = rootNode.querySelectorAll('img, iframe');
            const viewportBottom = (window.innerHeight || 0) + 1200;
            for (let i = 0; i < media.length; i++) {
                const el = media[i];
                if (!el || !isElementValid(el)) continue;

                // 뷰포트 밖 미디어를 우선 지연 로딩 처리
                let isNearViewport = true;
                try {
                    const rect = el.getBoundingClientRect();
                    isNearViewport = rect.top < viewportBottom;
                } catch (e) {}

                if (el.tagName === 'IMG') {
                    if (!el.getAttribute('loading')) {
                        el.setAttribute('loading', isNearViewport ? 'eager' : 'lazy');
                        optimized += 1;
                    }
                    if (!el.getAttribute('decoding')) {
                        el.setAttribute('decoding', 'async');
                    }
                }

                if (!isNearViewport && !el.getAttribute('fetchpriority')) {
                    el.setAttribute('fetchpriority', 'low');
                }
            }
            return optimized;
        }

        function waitForContentLoad(scrollRoot, beforeHeight, timeout = 500) {
            return new Promise((resolve) => {
                const startTime = Date.now();
                let resolved = false;

                // 센티널: 스크롤 끝에 배치
                const sentinel = document.createElement('div');
                sentinel.style.cssText = 'position:absolute;bottom:0;height:1px;pointer-events:none;';
                scrollRoot.appendChild(sentinel);

                // IntersectionObserver: 새 콘텐츠 렌더링 감지
                const observer = new IntersectionObserver((entries) => {
                    if (resolved) return;

                    const currentHeight = scrollRoot.scrollHeight;
                    const growth = currentHeight - beforeHeight;

                    // 높이 증가 확인
                    if (growth >= 10) {
                        resolved = true;
                        cleanup();
                        resolve({
                            success: true,
                            height: currentHeight,
                            growth: growth,
                            time: Date.now() - startTime
                        });
                    }
                }, {
                    root: null,
                    threshold: 0,
                    rootMargin: '5000px'
                });

                observer.observe(sentinel);

                // 타임아웃
                setTimeout(() => {
                    if (!resolved) {
                        resolved = true;
                        cleanup();
                        resolve({
                            success: false,
                            height: scrollRoot.scrollHeight,
                            growth: scrollRoot.scrollHeight - beforeHeight,
                            time: timeout
                        });
                    }
                }, timeout);

                function cleanup() {
                    observer.disconnect();
                    sentinel.remove();
                }
            });
        }

        function getScrollableParent(element) {
            let node = element ? element.parentElement : null;
            while (node && node !== document.body) {
                if (isScrollable(node)) {
                    return node;
                }
                node = node.parentElement;
            }
            return getROOT();
        }

        function fixedHeaderHeight(doc = document) {
            let height = 0;
            doc.querySelectorAll('header, [class*="header"], [class*="gnb"], [class*="navbar"], [class*="nav-bar"], [data-fixed-header]').forEach(el => {
                const cs = getComputedStyle(el);
                if (!cs) return;
                if (cs.position === 'fixed' || cs.position === 'sticky') {
                    const rect = el.getBoundingClientRect();
                    if (rect.height > height) {
                        height = rect.height;
                    }
                }
            });
            return height;
        }

        async function scrollStepAsync(element, target, axis = 'y', ratio = 5.0, minStep = 200) {
            if (!element) return 0;
            const isY = axis === 'y';
            const getCurrent = () => isY ? element.scrollTop : element.scrollLeft;
            const setCurrent = value => {
                if (isY) {
                    element.scrollTop = value;
                } else {
                    element.scrollLeft = value;
                }
            };
            const limit = Math.max(0, (isY ? element.scrollHeight - element.clientHeight : element.scrollWidth - element.clientWidth));
            const goal = Math.min(limit, Math.max(0, target));
            let current = getCurrent();
            let guard = 0;
            while (Math.abs(goal - current) > 0.5 && guard < 20) {
                const distance = goal - current;
                const step = Math.max(minStep, Math.abs((isY ? element.clientHeight : element.clientWidth) * ratio));
                const delta = Math.sign(distance) * Math.min(step, Math.abs(distance));
                setCurrent(current + delta);
                await nextFrame();
                current = getCurrent();
                guard += 1;
            }
            setCurrent(goal);
            await nextFrame();
            return getCurrent();
        }

        async function scrollNearBottomAsync(root, options = {}) {
            const { ratio = 1.2, marginPx = 800 } = options;
            if (!root) return;
            const max = Math.max(0, root.scrollHeight - root.clientHeight);
            const goal = Math.max(0, max - marginPx);
            await scrollStepAsync(root, goal, 'y', ratio);
        }

        async function preciseScrollToAsync(x, y) {
            const root = getROOT();
            if (!root) return { x: 0, y: 0 };
            const finalX = await scrollStepAsync(root, x, 'x');
            const finalY = await scrollStepAsync(root, y, 'y');
            return {
                x: root.scrollLeft || finalX || 0,
                y: root.scrollTop || finalY || 0
            };
        }

        async function ensureElementVisibleAsync(element, options = {}) {
            const { marginPx = 0 } = options;
            if (!element) return null;
            const container = getScrollableParent(element);
            if (!container) return null;
            const rect = element.getBoundingClientRect();
            const absoluteTop = (container.scrollTop || 0) + rect.top;
            const header = fixedHeaderHeight();
            const targetY = Math.max(0, absoluteTop - header - marginPx);
            const finalY = await scrollStepAsync(container, targetY, 'y');
            return { container, rect, header, finalY };
        }

        function sanitizeForJSON(value) {
            const replacer = (key, val) => {
                if (typeof val === 'number' && !Number.isFinite(val)) return null;
                if (typeof val === 'bigint' || typeof val === 'function' || typeof val === 'symbol') return null;
                if (val && typeof val === 'object') {
                    if (typeof Element !== 'undefined' && val instanceof Element) {
                        return { tag: val.tagName };
                    }
                    if (typeof Node !== 'undefined' && val instanceof Node) {
                        return { node: val.nodeName };
                    }
                }
                return val;
            };
            try {
                return JSON.parse(JSON.stringify(value, replacer));
            } catch (error) {
                return { error: 'sanitize_failed', message: error.message };
            }
        }

        function serializeForJSON(value) {
            const safe = sanitizeForJSON(value);
            try {
                return JSON.stringify(safe);
            } catch (error) {
                return JSON.stringify({ error: 'serialize_failed', message: error.message });
            }
        }

        function ensureOverflowAnchorState(disabled) {
            window.__bfcacheOverflowAnchor = window.__bfcacheOverflowAnchor || {
                disabled: false,
                doc: null,
                body: null
            };
            const state = window.__bfcacheOverflowAnchor;
            if (disabled) {
                if (!state.disabled) {
                    if (document.documentElement) {
                        state.doc = document.documentElement.style.overflowAnchor || "";
                        document.documentElement.style.setProperty('overflow-anchor', 'none', 'important');
                    }
                    if (document.body) {
                        state.body = document.body.style.overflowAnchor || "";
                        document.body.style.setProperty('overflow-anchor', 'none', 'important');
                    }
                    state.disabled = true;
                }
            } else if (state.disabled) {
                if (document.documentElement) {
                    if (state.doc) {
                        document.documentElement.style.overflowAnchor = state.doc;
                    } else {
                        document.documentElement.style.removeProperty('overflow-anchor');
                    }
                }
                if (document.body) {
                    if (state.body) {
                        document.body.style.overflowAnchor = state.body;
                    } else {
                        document.body.style.removeProperty('overflow-anchor');
                    }
                }
                state.disabled = false;
            }
        }

        // 🔍 무한 스크롤 메커니즘 감지 (디버깅용)
        function installInfiniteScrollDetector(logs) {
            if (window.__infiniteScrollDetectorInstalled) return;
            window.__infiniteScrollDetectorInstalled = true;

            // 1. IntersectionObserver 감지
            const OrigIO = window.IntersectionObserver;
            let ioInstances = [];
            window.IntersectionObserver = function(callback, options) {
                const instanceId = ioInstances.length + 1;
                const wrappedCallback = function(entries, observer) {
                    entries.forEach(entry => {
                        if (entry.isIntersecting) {
                            const target = entry.target;
                            logs.push('[IO-' + instanceId + '] 🎯 요소 감지됨');
                            logs.push('  Tag: ' + target.tagName);
                            logs.push('  Class: ' + (target.className || 'none'));
                            logs.push('  ID: ' + (target.id || 'none'));
                            try {
                                const dataStr = JSON.stringify(target.dataset);
                                if (dataStr && dataStr !== '{}') {
                                    logs.push('  Data: ' + dataStr.slice(0, 100));
                                }
                            } catch(e) {}
                            const text = (target.textContent || '').trim();
                            if (text) {
                                logs.push('  Text: ' + text.slice(0, 50));
                            }
                            logs.push('  Y: ' + entry.boundingClientRect.top.toFixed(0));
                        }
                    });
                    return callback.apply(this, arguments);
                };

                logs.push('[IO-' + instanceId + '] ✨ 생성됨');
                logs.push('  rootMargin: ' + (options?.rootMargin || '0px'));
                logs.push('  threshold: ' + JSON.stringify(options?.threshold || 0));

                const instance = new OrigIO(wrappedCallback, options);
                ioInstances.push(instance);

                const origObserve = instance.observe.bind(instance);
                instance.observe = function(target) {
                    const selector = target.className ? '.' + target.className.split(' ')[0] :
                                   (target.id ? '#' + target.id : target.tagName);
                    logs.push('[IO-' + instanceId + '] 👀 관찰 시작');
                    logs.push('  Tag: ' + target.tagName);
                    logs.push('  Class: ' + (target.className || 'none'));
                    logs.push('  ID: ' + (target.id || 'none'));
                    logs.push('  Selector: ' + selector);
                    return origObserve(target);
                };

                return instance;
            };

            // 2. XHR/fetch 감지
            const openOrig = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                const stack = new Error().stack.split('\\n').slice(2, 5).join('\\n  ');
                logs.push('[XHR] 📡 요청 시작');
                logs.push('  Method: ' + method);
                logs.push('  URL: ' + url);
                logs.push('  Stack:');
                logs.push('  ' + stack.slice(0, 300));

                const origSend = this.send.bind(this);
                this.send = function() {
                    this.addEventListener('load', function() {
                        try {
                            const json = JSON.parse(this.responseText);
                            const keys = Object.keys(json).slice(0, 5);
                            logs.push('[XHR] ✅ 응답 수신');
                            logs.push('  Status: ' + this.status);
                            logs.push('  Keys: ' + keys.join(', '));
                            logs.push('  Length: ' + this.responseText.length);
                        } catch(e) {
                            logs.push('[XHR] ✅ 응답 수신');
                            logs.push('  Status: ' + this.status);
                            logs.push('  Length: ' + this.responseText.length);
                        }
                    });
                    return origSend.apply(this, arguments);
                };

                return openOrig.apply(this, arguments);
            };

            const fetchOrig = window.fetch;
            window.fetch = async function(url, opts) {
                const stack = new Error().stack.split('\\n').slice(2, 5).join('\\n  ');
                const method = opts?.method || 'GET';
                logs.push('[fetch] 📡 요청 시작');
                logs.push('  Method: ' + method);
                logs.push('  URL: ' + url);
                logs.push('  Body: ' + (opts?.body ? 'present' : 'none'));
                logs.push('  Stack:');
                logs.push('  ' + stack.slice(0, 300));

                const response = await fetchOrig.call(this, url, opts);

                logs.push('[fetch] ✅ 응답 수신');
                logs.push('  Status: ' + response.status);
                logs.push('  URL: ' + url);

                return response;
            };
        }

        (function hardenEnv() {
            try {
                if (window._bfcacheEnvHardened) return;
                window._bfcacheEnvHardened = true;
                if (history && typeof history.scrollRestoration === 'string') {
                    history.scrollRestoration = 'manual';
                }
            } catch (e) {}
            try {
                document.documentElement.style.setProperty('scroll-behavior', 'auto', 'important');
            } catch (e) {}
        })();
        """
    }
    private func generateStep1_ContentRestoreScript() -> String {
        let savedHeight = self.restorationConfig.savedContentHeight

        // 🛡️ **값 검증**
        guard savedHeight.isFinite && savedHeight >= 0 else {
            TabPersistenceManager.debugMessages.append("⚠️ [Step 1] savedHeight 비정상: \(savedHeight)")
            return """
            return JSON.stringify({ success: false, error: 'invalid_height', savedContentHeight: \(savedHeight), logs: ['savedHeight 값이 비정상입니다'] });
            """
        }

        return """
        try {
            \(generateCommonUtilityScript())

            const logs = [];
            const savedContentHeight = parseFloat('\(savedHeight)');
            logs.push('[Step 1] 저장 시점 높이: ' + savedContentHeight.toFixed(0) + 'px');

            const root = getROOT();
            logs.push('[Step 1] 스크롤 루트: ' + (root ? root.tagName : 'null'));

                const currentHeight = root ? root.scrollHeight : 0;
                const viewportHeight = window.innerHeight || 0;
                const rawTargetScrollY = parseFloat('\(self.scrollPosition.y)');
                const targetScrollY = Number.isFinite(rawTargetScrollY) ? Math.max(0, rawTargetScrollY) : 0;
                const prefetchDistancePx = 800;
                const desiredRestoreHeight = Math.max(
                    currentHeight,
                    Math.min(savedContentHeight, targetScrollY + viewportHeight + prefetchDistancePx)
                );
                const desiredScrollReach = targetScrollY + prefetchDistancePx;
                logs.push('[Step 1] 현재 높이: ' + currentHeight.toFixed(0) + 'px');
                logs.push('[Step 1] 뷰포트 높이: ' + viewportHeight.toFixed(0) + 'px');
                logs.push('[Step 1] 목표 스크롤: ' + targetScrollY.toFixed(0) + 'px');
                logs.push('[Step 1] 목표 복원 높이(Windowed): ' + desiredRestoreHeight.toFixed(0) + 'px');

                // 🛡️ **가상 리스트 감지: scrollHeight ≈ 뷰포트 높이**
                const isVirtualList = Math.abs(currentHeight - viewportHeight) < 50;
                if (isVirtualList) {
                    logs.push('[Step 1] 가상 리스트 감지 - 목표 위치까지 트리거 필요');
                }

                const heightDiff = savedContentHeight - currentHeight;
                logs.push('[Step 1] 높이 차이: ' + heightDiff.toFixed(0) + 'px (' + (heightDiff > 0 ? '부족' : '충분') + ')');

                ensureOverflowAnchorState(true);

                const percentage = savedContentHeight > 0 ? (currentHeight / savedContentHeight) * 100 : 0;
                const isStaticSite = percentage >= 98;

                if (isStaticSite) {
                    logs.push('정적 사이트 - 콘텐츠 이미 충분함');
                    return serializeForJSON({
                        success: true,
                        isStaticSite: true,
                        currentHeight: currentHeight,
                        savedContentHeight: savedContentHeight,
                        restoredHeight: currentHeight,
                        percentage: percentage,
                        triggeredInfiniteScroll: false,
                        logs: logs
                    });
                }

                logs.push('동적 사이트 - 콘텐츠 로드 시도');

                // 🔍 무한 스크롤 메커니즘 감지 설치
                installInfiniteScrollDetector(logs);
                logs.push('🔍 무한 스크롤 감지기 설치 완료');
                const optimizedMediaCount = optimizeLazyMedia(document);
                if (optimizedMediaCount > 0) {
                    logs.push('[Step 1] 미디어 지연 로딩 최적화: ' + optimizedMediaCount + '개');
                }

                const loadMoreButtons = document.querySelectorAll(
                    '[data-testid*="load"], [class*="load"], [class*="more"], ' +
                    'button[class*="more"], .load-more, .show-more'
                );

                let clicked = 0;
                loadMoreButtons.forEach(btn => {
                    if (clicked < 5 && btn && typeof btn.click === 'function') {
                        btn.click();
                        clicked += 1;
                    }
                });

                if (clicked > 0) {
                    logs.push('더보기 버튼 ' + clicked + '개 클릭');
                    await nextFrame();
                    await delay(160);
                }

                const containers = findScrollContainers();
                logs.push('[Step 1] 컨테이너: ' + containers.length + '개');

                let grew = false;
                const step1StartTime = Date.now();

                // 🚀 **Observer 기반 이벤트 드리븐 감지**
                for (let containerIndex = 0; containerIndex < containers.length; containerIndex++) {
                    const scrollRoot = containers[containerIndex];
                    logs.push('[Step 1] 컨테이너 ' + (containerIndex + 1) + '/' + containers.length + ' 체크');

                    if (!scrollRoot) {
                        logs.push('[Step 1] 컨테이너 ' + (containerIndex + 1) + ' null - 스킵');
                        continue;
                    }
                    if (!isElementValid(scrollRoot)) {
                        logs.push('[Step 1] 컨테이너 ' + (containerIndex + 1) + ' 무효 - 스킵');
                        continue;
                    }

                    let lastHeight = scrollRoot.scrollHeight;
                    logs.push('[Step 1] 컨테이너 ' + (containerIndex + 1) + ' 시작: ' + lastHeight.toFixed(0) + 'px');

                    let containerGrew = false;
                    let batchCount = 0;
                    const maxAttempts = 50;
                    const maxWait = 500;
                    const scrollsPerBatch = 5;

                    while (batchCount < maxAttempts) {
                        if (!isElementValid(scrollRoot)) break;

                        const currentScrollHeight = scrollRoot.scrollHeight;
                        const maxScrollY = currentScrollHeight - viewportHeight;

                        // 🛡️ **목표 높이 도달 시 중단 (가상리스트는 scrollY 기준)**
                        if (isVirtualList) {
                            if (maxScrollY >= desiredScrollReach) {
                                logs.push('[Step 1] 가상리스트 목표 scrollY 도달 (배치: ' + batchCount + ')');
                                grew = true;
                                containerGrew = true;
                                break;
                            }
                        } else {
                            if (currentScrollHeight >= desiredRestoreHeight) {
                                logs.push('[Step 1] 목표 높이 도달 (배치: ' + batchCount + ')');
                                grew = true;
                                containerGrew = true;
                                break;
                            }
                        }

                        // 🛡️ **과도한 성장 방지**
                        if (currentScrollHeight >= desiredRestoreHeight * 1.05) {
                            logs.push('[Step 1] 100% 초과 (배치: ' + batchCount + ')');
                            grew = true;
                            containerGrew = true;
                            break;
                        }

                        // 🔧 **배치당 여러 번 스크롤**
                        let batchGrowth = 0;
                        let batchSuccess = false;
                        const batchStartTime = Date.now();

                        for (let scrollIndex = 0; scrollIndex < scrollsPerBatch; scrollIndex++) {
                            const beforeHeight = scrollRoot.scrollHeight;

                            // 목표 도달 시 중단
                            if (beforeHeight >= desiredRestoreHeight) {
                                batchSuccess = true;
                                break;
                            }

                            const prefetchMarginPx = Math.max(prefetchDistancePx, Math.round((scrollRoot.clientHeight || viewportHeight || 0) * 0.75));
                            const sentinel = findSentinel(scrollRoot);

                            if (sentinel && isElementValid(sentinel) && typeof sentinel.scrollIntoView === 'function') {
                                try {
                                    await scrollNearBottomAsync(scrollRoot, { ratio: 1.2, marginPx: prefetchMarginPx });
                                } catch(e) {
                                    scrollRoot.scrollTo(0, Math.max(0, scrollRoot.scrollHeight - prefetchMarginPx));
                                }
                            } else {
                                await scrollNearBottomAsync(scrollRoot, { ratio: 1.2, marginPx: prefetchMarginPx });
                            }

                            const result = await waitForContentLoad(scrollRoot, beforeHeight, maxWait);

                            if (!isElementValid(scrollRoot)) break;

                            if (result.success) {
                                batchGrowth += result.growth;
                                batchSuccess = true;
                                lastHeight = result.height;
                                optimizeLazyMedia(scrollRoot);
                            } else if (result.growth > 0) {
                                batchGrowth += result.growth;
                                lastHeight = result.height;
                            } else {
                                // 더 이상 성장 안 함
                                break;
                            }
                        }

                        const batchTime = ((Date.now() - batchStartTime) / 1000).toFixed(2);

                        if (batchSuccess) {
                            grew = true;
                            containerGrew = true;
                            batchCount++;

                            if (batchCount === 0 || batchCount % 5 === 0) {
                                logs.push('[Step 1] Batch ' + batchCount + ': +' + batchGrowth.toFixed(0) + 'px (' + batchTime + 's, 현재: ' + lastHeight.toFixed(0) + 'px)');
                            }
                        } else {
                            if (batchGrowth > 0) {
                                logs.push('[Step 1] 소폭 증가: +' + batchGrowth.toFixed(0) + 'px (' + batchTime + 's, 계속)');
                                batchCount++;
                            } else {
                                logs.push('[Step 1] 성장 중단 (배치: ' + batchCount + ')');
                                break;
                            }
                        }
                    }

                    if (containerGrew) {
                        logs.push('[Step 1] 컨테이너 트리거 성공 - 계속');
                    } else {
                        logs.push('[Step 1] 컨테이너 트리거 실패');
                    }
                }

                await waitForStableLayoutAsync({ frames: 4, timeout: 500 });

                const step1TotalTime = ((Date.now() - step1StartTime) / 800).toFixed(1);
                logs.push('[Step 1] 총 소요 시간: ' + step1TotalTime + '초');

                const refreshedRoot = getROOT();
                const restoredHeight = refreshedRoot ? refreshedRoot.scrollHeight : 0;
                const finalSavedPercentage = savedContentHeight > 0 ? (restoredHeight / savedContentHeight) * 100 : 0;
                const finalGoalPercentage = desiredRestoreHeight > 0 ? (restoredHeight / desiredRestoreHeight) * 100 : 0;
                const success = finalGoalPercentage >= 95 || (grew && restoredHeight > currentHeight + 128);

                logs.push('복원: ' + restoredHeight.toFixed(0) + 'px (goal=' + finalGoalPercentage.toFixed(1) + '%, saved=' + finalSavedPercentage.toFixed(1) + '%)');

                return serializeForJSON({
                    success: success,
                    isStaticSite: false,
                    currentHeight: currentHeight,
                    savedContentHeight: savedContentHeight,
                    goalContentHeight: desiredRestoreHeight,
                    restoredHeight: restoredHeight,
                    percentage: finalGoalPercentage,
                    savedPercentage: finalSavedPercentage,
                    triggeredInfiniteScroll: grew,
                    logs: logs
                });

        } catch(e) {
            return serializeForJSON({
                success: false,
                error: e.message,
                errorStack: e.stack ? e.stack.split('\\n').slice(0, 3).join('\\n') : 'no stack',
                logs: [
                    '[Step 1] ❌ 치명적 오류 발생',
                    '[Step 1] 오류 메시지: ' + e.message,
                    '[Step 1] 오류 타입: ' + e.name,
                    '[Step 1] 스택 트레이스: ' + (e.stack ? e.stack.substring(0, 200) : 'none')
                ]
            });
        }
        """
    }
    private func generateStep2_PercentScrollScript() -> String {
        let targetPercentX = self.scrollPositionPercent.x
        let targetPercentY = self.scrollPositionPercent.y
        let savedHeight = self.restorationConfig.savedContentHeight

        return """
        try {
            \(generateCommonUtilityScript())

            const logs = [];
            const targetPercentX = parseFloat('\(targetPercentX)');
            const targetPercentY = parseFloat('\(targetPercentY)');
            const savedContentHeight = parseFloat('\(savedHeight)');

                logs.push('[Step 2] 상대좌표 기반 스크롤 복원');
                logs.push('목표 백분율: X=' + targetPercentX.toFixed(2) + '%, Y=' + targetPercentY.toFixed(2) + '%');
                logs.push('저장 시점 높이: ' + savedContentHeight.toFixed(0) + 'px');

                await waitForStableLayoutAsync({ frames: 6, timeout: 1000 });

                const root = getROOT();
                if (!root) {
                    logs.push('스크롤 루트를 찾을 수 없음');
                    return serializeForJSON({
                        success: false,
                        targetPercent: { x: targetPercentX, y: targetPercentY },
                        calculatedPosition: { x: 0, y: 0 },
                        actualPosition: { x: 0, y: 0 },
                        difference: { x: 0, y: 0 },
                        logs: logs
                    });
                }

                const maxScrollY = Math.max(0, savedContentHeight - window.innerHeight);
                const maxScrollX = Math.max(0, root.scrollWidth - window.innerWidth);
                logs.push('최대 스크롤 (저장 기준): X=' + maxScrollX.toFixed(0) + 'px, Y=' + maxScrollY.toFixed(0) + 'px');

                const targetX = (targetPercentX / 100) * maxScrollX;
                const targetY = (targetPercentY / 100) * maxScrollY;

                logs.push('계산된 목표: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');

                const preciseResult = await preciseScrollToAsync(targetX, targetY);

                await waitForStableLayoutAsync({ frames: 3, timeout: 800 });

                const updatedRoot = getROOT();
                const actualX = updatedRoot ? (updatedRoot.scrollLeft || preciseResult.x || 0) : preciseResult.x || 0;
                const actualY = updatedRoot ? (updatedRoot.scrollTop || preciseResult.y || 0) : preciseResult.y || 0;

                const diffX = Math.abs(actualX - targetX);
                const diffY = Math.abs(actualY - targetY);

                logs.push('실제 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');

                const success = diffY <= 50;

                return serializeForJSON({
                    success: success,
                    targetPercent: { x: targetPercentX, y: targetPercentY },
                    calculatedPosition: { x: targetX, y: targetY },
                    actualPosition: { x: actualX, y: actualY },
                    difference: { x: diffX, y: diffY },
                    logs: logs
                });

        } catch(e) {
            return serializeForJSON({
                success: false,
                error: e.message,
                logs: ['[Step 2] 오류: ' + e.message]
            });
        }
        """
    }
    private func generateStep3_InfiniteScrollAnchorRestoreScript(anchorDataJSON: String) -> String {
        let targetX = self.scrollPosition.x
        let targetY = self.scrollPosition.y
        let savedHeight = self.restorationConfig.savedContentHeight

        return """
        try {
            \(generateCommonUtilityScript())

            const logs = [];
            const targetX = parseFloat('\(targetX)');
            const targetY = parseFloat('\(targetY)');
            const savedContentHeight = parseFloat('\(savedHeight)');
            const infiniteScrollAnchorData = \(anchorDataJSON);

                logs.push('[Step 3] 무한스크롤 전용 앵커 복원');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                logs.push('저장 시점 높이: ' + savedContentHeight.toFixed(0) + 'px');

                await waitForStableLayoutAsync({ frames: 4, timeout: 1000 });

                
                // 앵커 데이터 확인
                if (!infiniteScrollAnchorData || !infiniteScrollAnchorData.anchors || infiniteScrollAnchorData.anchors.length === 0) {
                    logs.push('무한스크롤 앵커 데이터 없음 - 스킵');
                    return serializeForJSON({
                        success: false,
                        anchorCount: 0,
                        logs: logs
                    });
                }
                
                const anchors = infiniteScrollAnchorData.anchors;
                logs.push('사용 가능한 앵커: ' + anchors.length + '개');

                // 무한스크롤 앵커 타입별 필터링
                const vueComponentAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'vueComponent' && anchor.vueComponent;
                });
                const contentHashAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'contentHash' && anchor.contentHash;
                });
                const virtualIndexAnchors = anchors.filter(function(anchor) {
                    return anchor.anchorType === 'virtualIndex' && anchor.virtualIndex;
                });

                logs.push('Vue Component 앵커: ' + vueComponentAnchors.length + '개');
                logs.push('Content Hash 앵커: ' + contentHashAnchors.length + '개');
                logs.push('Virtual Index 앵커: ' + virtualIndexAnchors.length + '개');

                // 🎯 **새 방식: 모든 앵커 매칭 → 목표 위치와 거리 계산 → 가장 가까운 것 선택**
                const allMatchedCandidates = [];

                // className 처리 함수
                function getClassNameString(element) {
                    if (typeof element.className === 'string') {
                        return element.className;
                    } else if (element.className && typeof element.className.toString === 'function') {
                        return element.className.toString();
                    }
                    return '';
                }

                logs.push('🔍 거리 기반 매칭 시작 (목표: Y=' + targetY.toFixed(0) + 'px)');

                // 1. ID 기반 매칭 시도
                for (let i = 0; i < anchors.length; i++) {
                    const anchor = anchors[i];
                    if (anchor.elementId) {
                        const element = document.getElementById(anchor.elementId);
                        if (element) {
                            const ROOT = getROOT();
                            const rect = element.getBoundingClientRect();
                            const elementY = ROOT.scrollTop + rect.top;
                            const distance = Math.abs(elementY - targetY);
                            allMatchedCandidates.push({
                                element: element,
                                anchor: anchor,
                                method: 'element_id',
                                distance: distance,
                                confidence: 100
                            });
                        }
                    }
                }

                // 2. data-* 속성 매칭 시도
                for (let i = 0; i < anchors.length; i++) {
                    const anchor = anchors[i];
                    if (anchor.dataAttributes) {
                        const keys = Object.keys(anchor.dataAttributes);
                        for (let j = 0; j < keys.length; j++) {
                            const key = keys[j];
                            const value = anchor.dataAttributes[key];
                            const selector = '[' + key + '="' + value + '"]';
                            try {
                                const elements = document.querySelectorAll(selector);
                                if (elements.length > 0) {
                                    const ROOT = getROOT();
                                    const rect = elements[0].getBoundingClientRect();
                                    const elementY = ROOT.scrollTop + rect.top;
                                    const distance = Math.abs(elementY - targetY);
                                    allMatchedCandidates.push({
                                        element: elements[0],
                                        anchor: anchor,
                                        method: 'data_attribute',
                                        distance: distance,
                                        confidence: 95
                                    });
                                    break;
                                }
                            } catch(e) {}
                        }
                    }
                }

                // 3. Vue Component 앵커 매칭
                for (let i = 0; i < vueComponentAnchors.length; i++) {
                    const anchor = vueComponentAnchors[i];
                    const vueComp = anchor.vueComponent;

                    if (vueComp.dataV) {
                        const vueElements = document.querySelectorAll('[' + vueComp.dataV + ']');
                        for (let j = 0; j < vueElements.length; j++) {
                            const element = vueElements[j];
                            const classNameStr = getClassNameString(element);

                            if (vueComp.name && classNameStr.indexOf(vueComp.name) !== -1) {
                                if (typeof vueComp.index === 'number') {
                                    const elementIndex = element.parentElement
                                        ? Array.from(element.parentElement.children).indexOf(element)
                                        : -1;
                                    if (elementIndex !== -1 && Math.abs(elementIndex - vueComp.index) <= 2) {
                                        const ROOT = getROOT();
                                        const rect = element.getBoundingClientRect();
                                        const elementY = ROOT.scrollTop + rect.top;
                                        const distance = Math.abs(elementY - targetY);
                                        allMatchedCandidates.push({
                                            element: element,
                                            anchor: anchor,
                                            method: 'vue_component_with_index',
                                            distance: distance,
                                            confidence: 90
                                        });
                                    }
                                } else {
                                    const ROOT = getROOT();
                                    const rect = element.getBoundingClientRect();
                                    const elementY = ROOT.scrollTop + rect.top;
                                    const distance = Math.abs(elementY - targetY);
                                    allMatchedCandidates.push({
                                        element: element,
                                        anchor: anchor,
                                        method: 'vue_component',
                                        distance: distance,
                                        confidence: 85
                                    });
                                }
                            }
                        }
                    }
                }

                // 4. Content Hash 앵커 매칭
                for (let i = 0; i < contentHashAnchors.length; i++) {
                    const anchor = contentHashAnchors[i];
                    const contentHash = anchor.contentHash;

                    if (contentHash.text && contentHash.text.length > 20) {
                        const searchText = contentHash.text.substring(0, 50);
                        const selector = anchor.tagName || '*';
                        const candidateElements = document.querySelectorAll(selector);
                        for (let j = 0; j < candidateElements.length; j++) {
                            const element = candidateElements[j];
                            const elementText = (element.textContent || '').trim();
                            if (elementText.indexOf(searchText) !== -1) {
                                const ROOT = getROOT();
                                const rect = element.getBoundingClientRect();
                                const elementY = ROOT.scrollTop + rect.top;
                                const distance = Math.abs(elementY - targetY);
                                allMatchedCandidates.push({
                                    element: element,
                                    anchor: anchor,
                                    method: 'content_hash',
                                    distance: distance,
                                    confidence: 80
                                });
                                break;
                            }
                        }
                    }
                }

                // 5. Virtual Index 앵커 매칭 (페이지 오프셋 기반)
                for (let i = 0; i < virtualIndexAnchors.length; i++) {
                    const anchor = virtualIndexAnchors[i];
                    const virtualIndex = anchor.virtualIndex;

                    if (virtualIndex.offsetInPage !== undefined) {
                        const estimatedY = virtualIndex.offsetInPage;
                        // 저장된 위치와 목표 위치가 가까우면 후보로 추가
                        if (Math.abs(estimatedY - targetY) < 500) {
                            const selector = anchor.tagName || '*';
                            const candidateElements = document.querySelectorAll(selector);
                            for (let j = 0; j < candidateElements.length; j++) {
                                const element = candidateElements[j];
                                const ROOT = getROOT();
                                const rect = element.getBoundingClientRect();
                                const elementY = ROOT.scrollTop + rect.top;
                                const distance = Math.abs(elementY - targetY);
                                if (distance < 500) {
                                    allMatchedCandidates.push({
                                        element: element,
                                        anchor: anchor,
                                        method: 'virtual_index',
                                        distance: distance,
                                        confidence: 70
                                    });
                                }
                            }
                        }
                    }
                }

                logs.push('매칭된 후보 수: ' + allMatchedCandidates.length + '개');

                // 🎯 **거리 기반 정렬: 가장 가까운 것 선택**
                let foundElement = null;
                let matchedAnchor = null;
                let matchMethod = '';
                let confidence = 0;

                if (allMatchedCandidates.length > 0) {
                    allMatchedCandidates.sort(function(a, b) {
                        return a.distance - b.distance;
                    });

                    const best = allMatchedCandidates[0];
                    foundElement = best.element;
                    matchedAnchor = best.anchor;
                    matchMethod = best.method;
                    confidence = best.confidence;

                    logs.push('최적 매칭 선택: ' + matchMethod + ' (거리: ' + best.distance.toFixed(0) + 'px, 신뢰도: ' + confidence + '%)');
                } else {
                    logs.push('매칭된 앵커 없음');
                }

                if (foundElement && matchedAnchor) {
                    // 🎯 **수정: scrollIntoView 대신 직접 계산 + 헤더 보정**
                    const ROOT = getROOT();
                    const rect = foundElement.getBoundingClientRect();
                    const absY = ROOT.scrollTop + rect.top;
                    let headerHeightPx = fixedHeaderHeight();
                    const finalY = Math.max(0, absY - headerHeightPx);
                    
                    const offsetTop = (typeof matchedAnchor.offsetFromTop === 'number') ? matchedAnchor.offsetFromTop : 0;
                    let adjustedY = Math.max(0, finalY - Math.max(0, offsetTop));

                    const visibility = await ensureElementVisibleAsync(foundElement, { marginPx: Math.max(0, offsetTop) });
                    await waitForStableLayoutAsync({ frames: 3, timeout: 900 });

                    let container = visibility && visibility.container ? visibility.container : getScrollableParent(foundElement);
                    headerHeightPx = (visibility && visibility.header !== undefined) ? visibility.header : fixedHeaderHeight();
                    let actualContainerY = container ? (container.scrollTop || 0) : 0;

                    if (!visibility) {
                        const rootFallback = getROOT();
                        if (rootFallback) {
                            const rect2 = foundElement.getBoundingClientRect();
                            const absY2 = (rootFallback.scrollTop || 0) + rect2.top;
                            const targetOffset = Math.max(0, absY2 - headerHeightPx - Math.max(0, offsetTop));
                            await scrollStepAsync(rootFallback, targetOffset, 'y');
                            await waitForStableLayoutAsync({ frames: 2, timeout: 600 });
                            container = rootFallback;
                            actualContainerY = rootFallback.scrollTop || 0;
                        }
                    }

                    const rootAfter = getROOT();
                    const actualX = rootAfter ? (rootAfter.scrollLeft || 0) : 0;
                    const actualY = rootAfter ? (rootAfter.scrollTop || actualContainerY || 0) : actualContainerY || 0;
                    const diffX = Math.abs(actualX - targetX);
                    const diffY = Math.abs(actualY - targetY);

                    logs.push('앵커 복원 후 위치: X=' + actualX.toFixed(1) + 'px, Y=' + actualY.toFixed(1) + 'px');
                    logs.push('목표와의 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                    logs.push('매칭 신뢰도: ' + confidence + '%');
                    logs.push('헤더 보정: ' + headerHeightPx.toFixed(0) + 'px');

                    return serializeForJSON({
                        success: diffY <= 100,
                        anchorCount: anchors.length,
                        matchedAnchor: {
                            anchorType: matchedAnchor.anchorType,
                            matchMethod: matchMethod,
                            confidence: confidence
                        },
                        restoredPosition: { x: actualX, y: actualY },
                        containerScroll: { y: actualContainerY },
                        targetDifference: { x: diffX, y: diffY },
                        logs: logs
                    });
                }

                logs.push('무한스크롤 앵커 매칭 실패');
                return serializeForJSON({
                    success: false,
                    anchorCount: anchors.length,
                    logs: logs
                });
                
        } catch(e) {
            return serializeForJSON({
                success: false,
                error: e.message,
                logs: ['[Step 3] 오류: ' + e.message]
            });
        }
        """
    }

    private func generateStep4_FinalVerificationScript() -> String {
        let targetX = self.scrollPosition.x
        let targetY = self.scrollPosition.y
        let savedHeight = self.restorationConfig.savedContentHeight

        return """
        try {
            \(generateCommonUtilityScript())

            const logs = [];
            const targetX = parseFloat('\(targetX)');
            const targetY = parseFloat('\(targetY)');
            const savedContentHeight = parseFloat('\(savedHeight)');
            const tolerance = 30;

                logs.push('[Step 4] 최종 검증 및 미세 보정');
                logs.push('목표 위치: X=' + targetX.toFixed(1) + 'px, Y=' + targetY.toFixed(1) + 'px');
                logs.push('저장 시점 높이: ' + savedContentHeight.toFixed(0) + 'px');

                await waitForStableLayoutAsync({ frames: 3, timeout: 900 });
                
                const root = getROOT();
                if (!root) {
                    logs.push('스크롤 루트를 찾을 수 없음');
                    ensureOverflowAnchorState(false);
                    return serializeForJSON({
                        success: false,
                        targetPosition: { x: targetX, y: targetY },
                        finalPosition: { x: 0, y: 0 },
                        finalDifference: { x: targetX, y: targetY },
                        withinTolerance: false,
                        correctionApplied: false,
                        logs: logs
                    });
                }
                
                let currentX = root.scrollLeft || 0;
                let currentY = root.scrollTop || 0;
                let diffX = Math.abs(currentX - targetX);
                let diffY = Math.abs(currentY - targetY);
                let correctionApplied = false;
                
                logs.push('현재 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                logs.push('위치 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                const preciseAdjust = async () => {
                    const precise = await preciseScrollToAsync(targetX, targetY);
                    await waitForStableLayoutAsync({ frames: 2, timeout: 500 });
                    currentX = root.scrollLeft || precise.x || 0;
                    currentY = root.scrollTop || precise.y || 0;
                    diffX = Math.abs(currentX - targetX);
                    diffY = Math.abs(currentY - targetY);
                };
                
                if (diffX > tolerance || diffY > tolerance) {
                    logs.push('허용 오차 초과 - rAF 기반 정밀 보정 시작');
                    correctionApplied = true;
                    
                    for (let attempt = 0; attempt < 3 && (diffX > tolerance || diffY > tolerance); attempt++) {
                        await preciseAdjust();
                    }
                    
                    let microAdjust = 0;
                    while (diffY > 20 && microAdjust < 3) {
                        const delta = targetY > currentY ? 12 : -12;
                        await scrollStepAsync(root, currentY + delta, 'y', 0.2, 4);
                        await waitForStableLayoutAsync({ frames: 1, timeout: 240 });
                        currentX = root.scrollLeft || 0;
                        currentY = root.scrollTop || 0;
                        diffX = Math.abs(currentX - targetX);
                        diffY = Math.abs(currentY - targetY);
                        microAdjust += 1;
                    }
                }
                
                ensureOverflowAnchorState(false);
                
                logs.push('최종 위치: X=' + currentX.toFixed(1) + 'px, Y=' + currentY.toFixed(1) + 'px');
                logs.push('최종 차이: X=' + diffX.toFixed(1) + 'px, Y=' + diffY.toFixed(1) + 'px');
                
                return serializeForJSON({
                    success: diffY <= 50,
                    targetPosition: { x: targetX, y: targetY },
                    finalPosition: { x: currentX, y: currentY },
                    finalDifference: { x: diffX, y: diffY },
                    withinTolerance: diffX <= tolerance && diffY <= tolerance,
                    correctionApplied: correctionApplied,
                    logs: logs
                });
                
        } catch(e) {
            ensureOverflowAnchorState(false);
            return serializeForJSON({
                success: false,
                error: e.message,
                logs: ['[Step 4] 오류: ' + e.message]
            });
        }
        """
    }

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
