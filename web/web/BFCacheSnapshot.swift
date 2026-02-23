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

}
