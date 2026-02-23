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

        function getListTailFingerprint(root, sampleSize = 4) {
            if (!root || !isElementValid(root)) return '';
            const selector = [
                '[data-id]',
                '[data-item-id]',
                '[data-article-id]',
                '[data-post-id]',
                '[data-index]',
                '[data-key]',
                'article',
                'li',
                '.item',
                '.post',
                '.card',
                'a[href]'
            ].join(',');
            const nodes = Array.from(root.querySelectorAll(selector));
            if (!nodes.length) return '';
            const tail = nodes.slice(-sampleSize);
            return tail.map(node => {
                const text = (node.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 40);
                const href = typeof node.getAttribute === 'function' ? (node.getAttribute('href') || '') : '';
                const dataId =
                    (typeof node.getAttribute === 'function' && (
                        node.getAttribute('data-id') ||
                        node.getAttribute('data-item-id') ||
                        node.getAttribute('data-article-id') ||
                        node.getAttribute('data-post-id') ||
                        node.getAttribute('data-key') ||
                        node.getAttribute('data-index')
                    )) || '';
                return [node.tagName || '', dataId, href, text].join('#');
            }).join('|');
        }

        function waitForProgressSignal(scrollRoot, options = {}) {
            return new Promise((resolve) => {
                if (!scrollRoot || !isElementValid(scrollRoot)) {
                    resolve({ success: false, reason: 'invalid_root', time: 0 });
                    return;
                }

                const {
                    timeout = 100,
                    beforeRequestSeq = null,
                    beforeFingerprint = ''
                } = options;

                const start = Date.now();
                let resolved = false;
                let rafId = null;
                let timeoutId = null;

                const finish = (success, reason) => {
                    if (resolved) return;
                    resolved = true;
                    if (rafId !== null) cancelAnimationFrame(rafId);
                    if (timeoutId !== null) clearTimeout(timeoutId);
                    resolve({
                        success: success,
                        reason: reason,
                        time: Date.now() - start
                    });
                };

                const check = () => {
                    if (resolved) return;
                    if (!isElementValid(scrollRoot)) {
                        finish(false, 'root_detached');
                        return;
                    }

                    if (Number.isFinite(beforeRequestSeq)) {
                        const seq = ((window.__bfcacheNetworkActivity || {}).requestSeq) || 0;
                        if (seq > beforeRequestSeq) {
                            finish(true, 'network_start');
                            return;
                        }
                    }

                    if (beforeFingerprint) {
                        const currentFingerprint = getListTailFingerprint(scrollRoot);
                        if (currentFingerprint && currentFingerprint !== beforeFingerprint) {
                            finish(true, 'fingerprint_change');
                            return;
                        }
                    }

                    rafId = requestAnimationFrame(check);
                };

                rafId = requestAnimationFrame(check);
                timeoutId = setTimeout(() => finish(false, 'progress_timeout'), timeout);
            });
        }

        function nudgeSentinelIntoViewport(scrollRoot, sentinel, options = {}) {
            const { padding = 8 } = options;
            if (!scrollRoot || !sentinel || !isElementValid(scrollRoot) || !isElementValid(sentinel)) {
                return { adjusted: false, reason: 'invalid_target' };
            }

            const docEl = document.documentElement;
            const viewportHeight = window.innerHeight || (docEl ? docEl.clientHeight : 0) || 0;
            if (viewportHeight <= 0) {
                return { adjusted: false, reason: 'invalid_viewport' };
            }

            const containerRect = scrollRoot.getBoundingClientRect();
            const sentinelRect = sentinel.getBoundingClientRect();
            const visibleTop = Math.max(padding, containerRect.top + padding);
            const visibleBottom = Math.min(viewportHeight - padding, containerRect.bottom - padding);

            if (visibleBottom <= visibleTop) {
                return { adjusted: false, reason: 'container_outside_viewport' };
            }

            let delta = 0;
            if (sentinelRect.top > visibleBottom) {
                delta = sentinelRect.top - visibleBottom;
            } else if (sentinelRect.bottom < visibleTop) {
                delta = sentinelRect.bottom - visibleTop;
            } else {
                return { adjusted: false, reason: 'already_visible' };
            }

            if (Math.abs(delta) < 1) {
                return { adjusted: false, reason: 'small_delta' };
            }

            const beforeTop = scrollRoot.scrollTop || 0;
            const maxTop = Math.max(0, scrollRoot.scrollHeight - scrollRoot.clientHeight);
            const targetTop = Math.max(0, Math.min(maxTop, beforeTop + delta));

            scrollRoot.scrollTop = targetTop;
            const afterTop = scrollRoot.scrollTop || 0;

            return {
                adjusted: Math.abs(afterTop - beforeTop) >= 1,
                reason: 'nudged',
                beforeTop: beforeTop,
                afterTop: afterTop,
                delta: afterTop - beforeTop
            };
        }

        async function waitForStableLayoutAsync(options = {}) {
            const {
                frames = 3,
                timeout = 800,
                threshold = 2,
                stabilityElement = null,
                stableRectFrames = 2,
                rectThreshold = 1,
                requireNetworkIdle = false
            } = options;
            const root = getROOT();
            if (!root) return;
            let stableFrames = 0;
            let rectStableCount = 0;
            let lastHeight = root.scrollHeight;
            let lastRectTop = null;
            const start = Date.now();
            while (Date.now() - start < timeout) {
                await nextFrame();
                if (!isElementValid(root)) break;
                const currentHeight = root.scrollHeight;
                if (Math.abs(currentHeight - lastHeight) <= threshold) {
                    stableFrames += 1;
                } else {
                    stableFrames = 0;
                    lastHeight = currentHeight;
                }

                if (stabilityElement && isElementValid(stabilityElement)) {
                    const rect = stabilityElement.getBoundingClientRect();
                    if (lastRectTop !== null && Math.abs(rect.top - lastRectTop) <= rectThreshold) {
                        rectStableCount += 1;
                    } else {
                        rectStableCount = 0;
                    }
                    lastRectTop = rect.top;
                }

                const networkState = window.__bfcacheNetworkActivity || {};
                const networkIdle = !requireNetworkIdle || (networkState.inFlight || 0) === 0;

                if (stableFrames >= frames && networkIdle) {
                    break;
                }

                if (stabilityElement && rectStableCount >= stableRectFrames && networkIdle) {
                    break;
                }
            }
        }

        function waitForContentLoad(scrollRoot, beforeHeight, timeout = 500, options = {}) {
            return new Promise((resolve) => {
                if (!scrollRoot || !isElementValid(scrollRoot)) {
                    resolve({
                        success: false,
                        reason: 'invalid_root',
                        height: 0,
                        growth: 0,
                        time: 0
                    });
                    return;
                }

                const startTime = Date.now();
                const baseHeight = Number.isFinite(beforeHeight) ? beforeHeight : (scrollRoot.scrollHeight || 0);
                const baseTop = Number.isFinite(options.beforeTop) ? options.beforeTop : (scrollRoot.scrollTop || 0);
                const minGrowth = Number.isFinite(options.minGrowth) ? options.minGrowth : 10;
                const networkStartGraceMs = Number.isFinite(options.networkStartGraceMs) ? options.networkStartGraceMs : 50;
                const resolveOnProgressSignals = options.resolveOnProgressSignals !== false;
                const allowNetworkStart = options.allowNetworkStart !== false;
                const allowScrollApplied = options.allowScrollApplied !== false;
                const allowSentinelIntersect = options.allowSentinelIntersect !== false;
                const networkStateAtStart = window.__bfcacheNetworkActivity || {};
                const requestSeqAtStart = networkStateAtStart.requestSeq || 0;

                let resolved = false;
                let rafId = null;
                let timeoutId = null;
                let observer = null;
                let timeoutNudgeTried = false;

                // 센티널: 스크롤 끝에 배치
                const fallbackSentinel = document.createElement('div');
                fallbackSentinel.style.cssText = 'position:absolute;bottom:0;height:1px;pointer-events:none;';
                scrollRoot.appendChild(fallbackSentinel);
                const observedSentinel = (options.observedSentinel && isElementValid(options.observedSentinel))
                    ? options.observedSentinel
                    : fallbackSentinel;

                const finish = (success, reason) => {
                    if (resolved) return;
                    resolved = true;
                    cleanup();
                    const currentHeight = isElementValid(scrollRoot) ? (scrollRoot.scrollHeight || 0) : baseHeight;
                    resolve({
                        success: success,
                        reason: reason,
                        height: currentHeight,
                        growth: currentHeight - baseHeight,
                        time: Date.now() - startTime
                    });
                };

                const checkProgress = () => {
                    if (resolved) return;
                    if (!isElementValid(scrollRoot)) {
                        finish(false, 'root_detached');
                        return;
                    }

                    const currentHeight = scrollRoot.scrollHeight || 0;
                    const growth = currentHeight - baseHeight;
                    if (growth >= minGrowth) {
                        finish(true, 'height_growth');
                        return;
                    }

                    const currentTop = scrollRoot.scrollTop || 0;
                    if (resolveOnProgressSignals && allowScrollApplied && Math.abs(currentTop - baseTop) >= 1) {
                        finish(true, 'scroll_applied');
                        return;
                    }

                    const networkState = window.__bfcacheNetworkActivity || {};
                    const requestSeq = networkState.requestSeq || 0;
                    const lastStart = networkState.lastStart || 0;
                    if (resolveOnProgressSignals && allowNetworkStart && requestSeq > requestSeqAtStart && lastStart >= startTime - networkStartGraceMs) {
                        finish(true, 'network_start');
                        return;
                    }

                    rafId = requestAnimationFrame(checkProgress);
                };

                if (typeof IntersectionObserver === 'function' && isElementValid(observedSentinel)) {
                    observer = new IntersectionObserver((entries) => {
                        if (resolved) return;
                        for (const entry of entries) {
                            if (entry.isIntersecting) {
                                if (entry.target === scrollRoot) continue;
                                if (resolveOnProgressSignals && allowSentinelIntersect) {
                                    finish(true, 'sentinel_intersect');
                                }
                                return;
                            }
                        }
                    }, {
                        root: null,
                        threshold: 0
                    });
                    observer.observe(observedSentinel);
                }

                rafId = requestAnimationFrame(checkProgress);

                // 타임아웃
                timeoutId = setTimeout(() => {
                    if (!resolved) {
                        if (!timeoutNudgeTried && isElementValid(observedSentinel)) {
                            timeoutNudgeTried = true;
                            const nudge = nudgeSentinelIntoViewport(scrollRoot, observedSentinel, { padding: 6 });
                            if (nudge.adjusted) {
                                requestAnimationFrame(() => {
                                    if (resolved) return;
                                    const currentHeight = isElementValid(scrollRoot) ? (scrollRoot.scrollHeight || 0) : baseHeight;
                                    if (currentHeight - baseHeight >= minGrowth) {
                                        finish(true, 'height_growth');
                                        return;
                                    }
                                    timeoutId = setTimeout(() => {
                                        if (!resolved) finish(false, 'timeout');
                                    }, 80);
                                });
                                return;
                            }
                        }
                        finish(false, 'timeout');
                    }
                }, timeout);

                function cleanup() {
                    if (observer) observer.disconnect();
                    if (rafId !== null) cancelAnimationFrame(rafId);
                    if (timeoutId !== null) clearTimeout(timeoutId);
                    if (fallbackSentinel && fallbackSentinel.isConnected) {
                        fallbackSentinel.remove();
                    }
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
            const { ratio = 0.9, marginPx = 1 } = options;
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
        function installInfiniteScrollDetector(logs, options = {}) {
            if (window.__infiniteScrollDetectorInstalled) return;
            window.__infiniteScrollDetectorInstalled = true;
            const { verbose = false } = options;
            window.__bfcacheNetworkActivity = window.__bfcacheNetworkActivity || {
                requestSeq: 0,
                inFlight: 0,
                lastStart: 0,
                lastEnd: 0
            };

            const markNetworkStart = () => {
                const state = window.__bfcacheNetworkActivity;
                state.requestSeq = (state.requestSeq || 0) + 1;
                state.inFlight = (state.inFlight || 0) + 1;
                state.lastStart = Date.now();
            };

            const markNetworkEnd = () => {
                const state = window.__bfcacheNetworkActivity;
                state.inFlight = Math.max(0, (state.inFlight || 0) - 1);
                state.lastEnd = Date.now();
            };

            // 3. XHR/fetch 감지
            const openOrig = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                if (verbose) {
                    logs.push('[XHR] 📡 요청 시작');
                    logs.push('  Method: ' + method);
                    logs.push('  URL: ' + url);
                }

                const origSend = this.send.bind(this);
                this.send = function() {
                    markNetworkStart();

                    const onLoadEnd = () => {
                        markNetworkEnd();
                        this.removeEventListener('loadend', onLoadEnd);
                    };
                    this.addEventListener('loadend', onLoadEnd);

                    if (verbose) {
                        this.addEventListener('load', function() {
                            logs.push('[XHR] ✅ 응답 수신');
                            logs.push('  Status: ' + this.status);
                            logs.push('  Length: ' + (this.responseText ? this.responseText.length : 0));
                        });
                    }
                    return origSend.apply(this, arguments);
                };

                return openOrig.apply(this, arguments);
            };

            const fetchOrig = window.fetch;
            window.fetch = async function(url, opts) {
                const method = opts?.method || 'GET';
                if (verbose) {
                    logs.push('[fetch] 📡 요청 시작');
                    logs.push('  Method: ' + method);
                    logs.push('  URL: ' + url);
                }

                markNetworkStart();
                try {
                    const response = await fetchOrig.call(this, url, opts);
                    if (verbose) {
                        logs.push('[fetch] ✅ 응답 수신');
                        logs.push('  Status: ' + response.status);
                        logs.push('  URL: ' + url);
                    }
                    return response;
                } finally {
                    markNetworkEnd();
                }
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
                logs.push('[Step 1] 현재 높이: ' + currentHeight.toFixed(0) + 'px');
                logs.push('[Step 1] 뷰포트 높이: ' + viewportHeight.toFixed(0) + 'px');

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
                installInfiniteScrollDetector(logs, { verbose: false });
                logs.push('🔍 무한 스크롤 감지기 설치 완료');

                const isSafeToClick = (el) => {
                    if (!el) return false;
                    if (el.disabled || el.getAttribute('aria-disabled') === 'true') return false;

                    // 1st guard: block anchors with real targets
                    if (el.tagName && el.tagName.toLowerCase() === 'a') {
                        const href = (el.getAttribute('href') || '').trim();
                        // only allow empty or plain '#'
                        if (href !== '' && href !== '#') {
                            return false;
                        }
                    }

                    // 2nd guard: block click bubbling into navigational anchors
                    let parent = el.parentElement;
                    let depth = 0;
                    while (parent && depth < 3) {
                        if (parent.tagName && parent.tagName.toLowerCase() === 'a') {
                            const parentHref = (parent.getAttribute('href') || '').trim();
                            if (parentHref !== '' && parentHref !== '#') return false;
                        }
                        parent = parent.parentElement;
                        depth += 1;
                    }

                    const text = ((el.textContent || '') + (el.getAttribute('aria-label') || '')).trim();

                    // 3rd guard: exclude tab/navigation-like controls
                    if (/개념글|추천글|베스트|전체글|갤러리|게시판|이동|목록|홈|home|login|로그인/i.test(text)) {
                        return false;
                    }

                    return true;
                };

                // 🔍 더보기 전용 탐색 함수 (isSafeToClick 우회 — href 있는 a도 더보기 패턴이면 허용)
                const findLoadMoreButton = () => {
                    // 1순위: id 기반 명시 패턴 (구글 #pnnext 등)
                    const byId = document.querySelector(
                        '#pnnext, #load-more, #loadMore, [id*="load-more"], [id*="loadmore"], [id*="pnnext"]'
                    );
                    if (byId && !byId.disabled && byId.getAttribute('aria-disabled') !== 'true') return byId;
                    // 2순위: 텍스트/클래스 기반 (button + a + role=button, href 있어도 허용)
                    const all = document.querySelectorAll('button, [role="button"], a');
                    for (const el of all) {
                        if (el.disabled || el.getAttribute('aria-disabled') === 'true') continue;
                        const txt = ((el.textContent || '') + (el.getAttribute('aria-label') || '')).trim();
                        // 탭/네비게이션 제외 (isSafeToClick 3rd guard 동일 적용)
                        if (/개념글|추천글|베스트|전체글|갤러리|게시판|이동|목록|홈|home|login|로그인/i.test(txt)) continue;
                        if (/더보기|more.?results|load.?more|show.?more|view.?more/i.test(txt)) return el;
                        const cls = (el.className || '').toString();
                        if (/load.?more|show.?more|infinite/i.test(cls)) return el;
                    }
                    return null;
                };

                const loadMoreButtons = document.querySelectorAll(
                    '[data-testid*="load"], [class*="load-more"], [class*="show-more"], button[class*="more"], [id*="load-more"], [id*="pnnext"]'
                );

                let clicked = 0;
                loadMoreButtons.forEach(btn => {
                    if (clicked < 5 && isSafeToClick(btn) && typeof btn.click === 'function') {
                        btn.click();
                        clicked += 1;
                    }
                });

                if (clicked > 0) {
                    logs.push('더보기 버튼 ' + clicked + '개 클릭');
                    await nextFrame();
                    await delay(160);
                }

                // 🚀 워밍업 패스: 배치 루프 전 더보기 버튼+스크롤을 빠르게 2회 선제 실행
                // (제스처 감지~Step 1 실행 사이의 공백 시간을 활용)
                {
                    const warmRoot = document.scrollingElement || document.documentElement;
                    const warmH0 = warmRoot.scrollHeight;
                    // 1차 선제 트리거
                    const wb1 = findLoadMoreButton(); if (wb1) wb1.click();
                    warmRoot.scrollTo({ top: 99999, behavior: 'instant' });
                    await delay(80);
                    // 2차 선제 트리거
                    const wb2 = findLoadMoreButton(); if (wb2) wb2.click();
                    warmRoot.scrollTo({ top: 99999, behavior: 'instant' });
                    await delay(80);
                    const warmGrowth = warmRoot.scrollHeight - warmH0;
                    if (warmGrowth > 0) logs.push('[Step 1] 워밍업 성장: +' + warmGrowth.toFixed(0) + 'px');
                }

                const containers = findScrollContainers();
                logs.push('[Step 1] 컨테이너: ' + containers.length + '개');

                let grew = false;
                const step1StartTime = Date.now();
                const triggerStats = {
                    height_growth: 0,
                    network_start: 0,
                    sentinel_intersect: 0,
                    scroll_applied: 0,
                    fingerprint_change: 0,
                    delayed_growth: 0,
                    timeout: 0
                };

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
                    const maxAttempts = isVirtualList ? 36 : 16;
                    const maxWait = isVirtualList ? 450 : 400; // 일반 DOM: API 응답 ~400ms 커버
                    const scrollsPerBatch = isVirtualList ? 4 : 3;
                    const maxSignalOnlyBatches = isVirtualList ? 4 : 1;
                    let stagnantProgressBatches = 0;

                    while (batchCount < maxAttempts) {
                        if (!isElementValid(scrollRoot)) break;

                        const currentScrollHeight = scrollRoot.scrollHeight;
                        const maxScrollY = currentScrollHeight - viewportHeight;

                        // 🛡️ **목표 높이 도달 시 중단 (가상리스트는 scrollY 기준)**
                        if (isVirtualList) {
                            if (maxScrollY >= savedContentHeight) {
                                logs.push('[Step 1] 가상리스트 목표 scrollY 도달 (배치: ' + batchCount + ')');
                                grew = true;
                                containerGrew = true;
                                break;
                            }
                        } else {
                            if (currentScrollHeight >= savedContentHeight) {
                                logs.push('[Step 1] 목표 높이 도달 (배치: ' + batchCount + ')');
                                grew = true;
                                containerGrew = true;
                                break;
                            }
                        }

                        // 🛡️ **과도한 성장 방지**
                        if (currentScrollHeight >= savedContentHeight * 1.0) {
                            logs.push('[Step 1] 100% 초과 (배치: ' + batchCount + ')');
                            grew = true;
                            containerGrew = true;
                            break;
                        }

                        // 🔧 **배치당 여러 번 스크롤**
                        let batchGrowth = 0;
                        let batchSuccess = false;
                        let batchHadProgressSignal = false;
                        let batchProgressOnly = false;
                        let batchMeaningfulProgress = false;
                        let batchSignalCount = 0;
                        let fingerprintBaseline = '';
                        const batchStartTime = Date.now();

                        // [배치마다] 더보기/로드더보기 버튼 범용 탐색 및 클릭 (스크롤과 이중 트리거)
                        const findAndClickLoadMore = () => {
                            const btn = findLoadMoreButton();
                            if (btn && typeof btn.click === 'function') {
                                btn.click();
                                return true;
                            }
                            return false;
                        };
                        const didClickMore = findAndClickLoadMore();
                        if (didClickMore) {
                            logs.push('[Step 1] 더보기 버튼 클릭 (배치 ' + batchCount + ')');
                            await nextFrame();
                            await delay(60);
                        }

                        for (let scrollIndex = 0; scrollIndex < scrollsPerBatch; scrollIndex++) {
                            const beforeHeight = scrollRoot.scrollHeight;
                            const beforeTop = scrollRoot.scrollTop || 0;
                            const beforeRequestSeq = ((window.__bfcacheNetworkActivity || {}).requestSeq) || 0;
                            if (scrollIndex === 0) {
                                fingerprintBaseline = getListTailFingerprint(scrollRoot);
                            }

                            // 목표 도달 시 중단
                            if (beforeHeight >= savedContentHeight) {
                                batchSuccess = true;
                                break;
                            }

                            const sentinel = findSentinel(scrollRoot);

                            if (sentinel && isElementValid(sentinel) && typeof sentinel.scrollIntoView === 'function') {
                                try {
                                    sentinel.scrollIntoView({ block: 'end', behavior: 'instant' });
                                } catch(e) {
                                    scrollRoot.scrollTo(0, scrollRoot.scrollHeight);
                                }
                            } else {
                                scrollRoot.scrollTo(0, scrollRoot.scrollHeight);
                            }

                            const observedSentinel = sentinel && isElementValid(sentinel) ? sentinel : findSentinel(scrollRoot);
                            if (observedSentinel && isElementValid(observedSentinel)) {
                                const nudgeResult = nudgeSentinelIntoViewport(scrollRoot, observedSentinel, { padding: 6 });
                                if (nudgeResult.adjusted) {
                                    await nextFrame();
                                }
                            }

                            const result = await waitForContentLoad(scrollRoot, beforeHeight, maxWait, {
                                beforeTop: beforeTop,
                                observedSentinel: observedSentinel,
                                allowNetworkStart: isVirtualList,
                                allowScrollApplied: isVirtualList,
                                allowSentinelIntersect: isVirtualList // 일반 DOM 방식 사이트에서 sentinel 허탕 배치 제거
                            });

                            if (!isElementValid(scrollRoot)) break;

                            if (result.reason) {
                                triggerStats[result.reason] = (triggerStats[result.reason] || 0) + 1;
                            }

                            if (result.success) {
                                if (result.growth > 0) {
                                    batchGrowth += result.growth;
                                    lastHeight = result.height;
                                    batchMeaningfulProgress = true;
                                    batchSuccess = true;
                                } else {
                                    batchHadProgressSignal = true;
                                    batchProgressOnly = true;

                                    // 진행 신호는 최대 1회만 후속 확인하여 과도한 대기 누적 방지
                                    batchSignalCount += 1;
                                    const shouldProbeProgress = false; // sentinel_intersect 후 waitForProgressSignal 대기 제거 (fingerprint=0 사이트에서 100ms×N 낭비)

                                    if (shouldProbeProgress) {
                                        const progressSignal = await waitForProgressSignal(scrollRoot, {
                                            timeout: isVirtualList ? 100 : 70,
                                            beforeRequestSeq: beforeRequestSeq,
                                            beforeFingerprint: fingerprintBaseline
                                        });

                                        if (!isElementValid(scrollRoot)) break;

                                        if (progressSignal.reason) {
                                            triggerStats[progressSignal.reason] = (triggerStats[progressSignal.reason] || 0) + 1;
                                        }

                                        if (progressSignal.success) {
                                            batchMeaningfulProgress = true;
                                            batchProgressOnly = false;
                                            if (progressSignal.reason === 'fingerprint_change') {
                                                triggerStats.delayed_growth += 1;
                                                fingerprintBaseline = getListTailFingerprint(scrollRoot);
                                            }
                                        }
                                    } else if (isVirtualList && (result.reason === 'network_start' || result.reason === 'scroll_applied')) {
                                        batchMeaningfulProgress = true;
                                        batchProgressOnly = false;
                                    } else {
                                        const afterFingerprint = getListTailFingerprint(scrollRoot);
                                        if (fingerprintBaseline && afterFingerprint && afterFingerprint !== fingerprintBaseline) {
                                            triggerStats.fingerprint_change += 1;
                                            triggerStats.delayed_growth += 1;
                                            batchMeaningfulProgress = true;
                                            batchProgressOnly = false;
                                            fingerprintBaseline = afterFingerprint;
                                        }
                                    }
                                }
                            } else if (result.growth > 0) {
                                batchGrowth += result.growth;
                                lastHeight = result.height;
                                batchMeaningfulProgress = true;
                                batchSuccess = true;
                                break; // height_growth 확인 즉시 다음 배치로 (남은 스크롤 불필요)
                            } else {
                                // 더 이상 성장 안 함
                                break;
                            }
                        }

                        if (!batchSuccess && isVirtualList && batchMeaningfulProgress) {
                            batchSuccess = true;
                        }

                        const batchTime = ((Date.now() - batchStartTime) / 1000).toFixed(2);

                        if (batchSuccess) {
                            if (batchGrowth > 0 || (isVirtualList && batchMeaningfulProgress)) {
                                grew = true;
                            }
                            containerGrew = true;
                            batchCount++;

                            if (batchGrowth > 0 || batchMeaningfulProgress) {
                                stagnantProgressBatches = 0;
                            } else {
                                stagnantProgressBatches += 1;
                                logs.push('[Step 1] 신호 성공(성장 대기): ' + batchTime + 's');
                                if (stagnantProgressBatches >= 5) {
                                    logs.push('[Step 1] 신호 반복 대비 성장 정체 - 중단');
                                    break;
                                }
                            }

                            if (batchCount === 0 || batchCount % 5 === 0) {
                                logs.push('[Step 1] Batch ' + batchCount + ': +' + batchGrowth.toFixed(0) + 'px (' + batchTime + 's, 현재: ' + lastHeight.toFixed(0) + 'px)');
                            }
                        } else {
                            if (batchProgressOnly || batchHadProgressSignal) {
                                stagnantProgressBatches += 1;
                                logs.push('[Step 1] 트리거 감지(성장 미확인): ' + batchTime + 's');
                                if (!isVirtualList || stagnantProgressBatches >= maxSignalOnlyBatches) {
                                    logs.push('[Step 1] 트리거 반복 대비 성장 정체 - 중단');
                                    break;
                                }
                                batchCount++;
                            } else if (batchGrowth > 0) {
                                logs.push('[Step 1] 소폭 증가: +' + batchGrowth.toFixed(0) + 'px (' + batchTime + 's, 계속)');
                                batchCount++;
                                stagnantProgressBatches = 0;
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

                const summaryOrder = [
                    'height_growth',
                    'network_start',
                    'sentinel_intersect',
                    'scroll_applied',
                    'fingerprint_change',
                    'delayed_growth',
                    'timeout',
                    'progress_timeout',
                    'root_detached',
                    'invalid_root'
                ];
                const summaryParts = summaryOrder.map(name => name + '=' + (triggerStats[name] || 0));
                Object.keys(triggerStats).forEach(name => {
                    if (summaryOrder.indexOf(name) === -1) {
                        summaryParts.push(name + '=' + triggerStats[name]);
                    }
                });
                logs.push('[Step 1] 신호 요약: ' + summaryParts.join(', '));

                const settleRoot = getROOT();
                const settleSentinel = findSentinel(settleRoot);
                await waitForStableLayoutAsync({
                    frames: 4,
                    timeout: 500,
                    stabilityElement: settleSentinel,
                    stableRectFrames: 2,
                    requireNetworkIdle: true
                });

                const step1TotalTime = ((Date.now() - step1StartTime) / 1000).toFixed(1);
                logs.push('[Step 1] 총 소요 시간: ' + step1TotalTime + '초');

                const refreshedRoot = getROOT();
                const restoredHeight = refreshedRoot ? refreshedRoot.scrollHeight : 0;
                const finalPercentage = savedContentHeight > 0 ? (restoredHeight / savedContentHeight) * 100 : 0;
                const success = finalPercentage >= 80 || (grew && restoredHeight > currentHeight + 128);

                logs.push('복원: ' + restoredHeight.toFixed(0) + 'px (' + finalPercentage.toFixed(1) + '%)');

                return serializeForJSON({
                    success: success,
                    isStaticSite: false,
                    currentHeight: currentHeight,
                    savedContentHeight: savedContentHeight,
                    restoredHeight: restoredHeight,
                    percentage: finalPercentage,
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
