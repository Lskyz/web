//
//  CustomWebView.swift
//
//  🎯 **단순화된 웹뷰 - 복잡한 캐시 시스템 제거**
//  ✅ 기본적인 히스토리 네비게이션만 유지
//  🌐 SPA 네비게이션 & DOM 변경 감지 훅 통합
//  🔧 제목 덮어쓰기 문제 해결 - titleObserver URL 검증 추가
//  📁 다운로드 기능 헬퍼 통합 완료 - 단방향 의존성 구현
//  🏊‍♂️ 웹뷰 풀 실제 연동 완료 - 생성/등록/재사용/정리
//  🚫 팝업 차단 시스템 완전 통합
//  🚫 복잡한 캐시 및 미리보기 시스템 제거
//  🎭 앞뒤 스와이프 제스처 슬라이드 전환 효과 적용
//

import SwiftUI
import WebKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import Foundation
import Security
import Photos

// MARK: - CustomWebView (UIViewRepresentable)
struct CustomWebView: UIViewRepresentable {
    @ObservedObject var stateModel: WebViewStateModel
    @Binding var playerURL: URL?
    @Binding var showAVPlayer: Bool
    var onScroll: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - makeUIView
    func makeUIView(context: Context) -> WKWebView {
        // ✅ 오디오 세션 활성화 (헬퍼 호출)
        configureAudioSessionForMixing()

        // 🏊‍♂️ **핵심 1: 웹뷰 풀에서 재사용 시도**
        var webView: WKWebView?
        if let tabID = stateModel.tabID {
            webView = WebViewPool.shared.reuseWebView(for: tabID)
            TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 풀 재사용 시도: 탭 \(String(tabID.uuidString.prefix(8)))")
        }
        
        // 재사용할 웹뷰가 없으면 새로 생성
        if webView == nil {
            // WKWebView 설정
            let config = WKWebViewConfiguration()
            config.allowsInlineMediaPlayback = true
            config.allowsPictureInPictureMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            config.websiteDataStore = WKWebsiteDataStore.default()
            config.processPool = WKProcessPool()

            // 📁 **다운로드 기능 헬퍼 통합**: iOS 14+ 다운로드 설정 강화
            if #available(iOS 14.0, *) {
                config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
                // ✅ 다운로드 허용 설정 추가
                config.preferences.javaScriptCanOpenWindowsAutomatically = true
                config.allowsInlineMediaPlayback = true
            }

            // 사용자 스크립트/메시지 핸들러 (헬퍼 호출)
            let controller = WKUserContentController()
            controller.addUserScript(makeVideoScript())
            controller.addUserScript(makeDesktopModeScript())
            controller.addUserScript(WebViewDataModel.makeSPANavigationScript())
            controller.addUserScript(makeImageSaveScript()) // 📷 이미지 저장 스크립트 추가
            controller.add(context.coordinator, name: "playVideo")
            controller.add(context.coordinator, name: "setZoom")
            controller.add(context.coordinator, name: "spaNavigation")
            controller.add(context.coordinator, name: "saveImage") // 📷 이미지 저장 핸들러 추가
            config.userContentController = controller

            // WKWebView 생성
            webView = WKWebView(frame: .zero, configuration: config)
            TabPersistenceManager.debugMessages.append("🆕 새 웹뷰 생성: 탭 \(String(stateModel.tabID?.uuidString.prefix(8) ?? "unknown"))")
        }
        
        guard let finalWebView = webView else {
            fatalError("🚨 웹뷰 생성/재사용 실패")
        }
        
        // 🏊‍♂️ **핵심 2: 웹뷰 풀에 등록**
        if let tabID = stateModel.tabID {
            WebViewPool.shared.registerWebView(finalWebView, for: tabID)
            TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 풀 등록: 탭 \(String(tabID.uuidString.prefix(8)))")
        }
        
        // 🎯 네이티브 제스처 완전 비활성화
        finalWebView.allowsBackForwardNavigationGestures = false
        
        finalWebView.scrollView.contentInsetAdjustmentBehavior = .never
        finalWebView.scrollView.decelerationRate = .normal

        // ✅ 하단 UI 겹치기를 위한 투명 처리 (헬퍼 호출)
        setupTransparentWebView(finalWebView)

        // ✨ Delegate 연결
        finalWebView.uiDelegate = context.coordinator
        
        // 📁 **수정**: NavigationDelegate는 DataModel이 처리 (WKNavigationDelegate 구현체)
        finalWebView.navigationDelegate = stateModel.dataModel
        
        // 📁 **다운로드 기능 헬퍼 호출**: iOS 14+ 다운로드 설정
        if #available(iOS 14.0, *) {
            setupWebViewDownloads(webView: finalWebView, stateModel: stateModel)
            TabPersistenceManager.debugMessages.append("📁 다운로드 기능 활성화 완료 (iOS 14+)")
        }
        
        context.coordinator.webView = finalWebView
        stateModel.webView = finalWebView
        
        // ✨ 초기 사용자 에이전트 설정 (헬퍼 호출)
        updateUserAgentIfNeeded(webView: finalWebView, stateModel: stateModel)

        // 🎭 슬라이드 전환 효과가 적용된 제스처 설정
        context.coordinator.setupSlideTransitionGesture(for: finalWebView)

        // Pull to Refresh (헬퍼 호출)
        setupPullToRefresh(for: finalWebView, target: context.coordinator, action: #selector(Coordinator.handleRefresh(_:)))
        finalWebView.scrollView.delegate = context.coordinator

        // ✨ 로딩 상태 동기화를 위한 KVO 옵저버 추가
        context.coordinator.setupLoadingObservers(for: finalWebView)

        // 초기 로드
        if let url = stateModel.currentURL {
            finalWebView.load(URLRequest(url: url))
        } else {
            finalWebView.load(URLRequest(url: URL(string: "about:blank")!))
        }

        // 외부 제어용 Notification 옵저버 등록
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleExternalOpenURL(_:)),
            name: .init("ExternalOpenURL"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.reloadWebView),
            name: .init("WebViewReload"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goBack),
            name: .init("WebViewGoBack"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goForward),
            name: .init("WebViewGoForward"),
            object: nil
        )

        // 📁 **다운로드 오버레이 헬퍼 호출**
        installDownloadOverlay(on: finalWebView, 
                              overlayContainer: &context.coordinator.overlayContainer,
                              overlayTitleLabel: &context.coordinator.overlayTitleLabel,
                              overlayPercentLabel: &context.coordinator.overlayPercentLabel,
                              overlayProgress: &context.coordinator.overlayProgress)

        // 📁 **다운로드 관련 이벤트 옵저버 등록 (헬퍼와 연동)**
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadStart(_:)),
                                               name: .WebViewDownloadStart,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadProgress(_:)),
                                               name: .WebViewDownloadProgress,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadFinish(_:)),
                                               name: .WebViewDownloadFinish,
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handleDownloadFailed(_:)),
                                               name: .WebViewDownloadFailed,
                                               object: nil)

        // 🎬 **PIP 관련 옵저버 등록**
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handlePIPStart(_:)),
                                               name: .init("StartPIPForTab"),
                                               object: nil)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.handlePIPStop(_:)),
                                               name: .init("StopPIPForTab"),
                                               object: nil)

        return finalWebView
    }

    // MARK: - updateUIView
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 연결 상태 확인 및 재연결
        if uiView.uiDelegate !== context.coordinator {
            uiView.uiDelegate = context.coordinator
        }
        if context.coordinator.webView !== uiView {
            context.coordinator.webView = uiView
        }
        // ✅ navigationDelegate가 항상 dataModel로 연결되어 있어야 함
        if uiView.navigationDelegate !== stateModel.dataModel {
            uiView.navigationDelegate = stateModel.dataModel
        }

        // ✅ 하단 UI 겹치기를 위한 투명 설정 유지 (헬퍼 호출)
        maintainTransparentWebView(uiView)
        
        // ✨ 데스크탑 모드 변경 시 페이지 새로고침으로 스크립트 적용 (헬퍼 호출)
        updateDesktopModeIfNeeded(webView: uiView, stateModel: stateModel, lastDesktopMode: &context.coordinator.lastDesktopMode)
    }

    // MARK: - teardown
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // 🏊‍♂️ **핵심 3: 웹뷰 해체 시 풀로 이동 (PIP 보호 고려)**
        if let tabID = coordinator.parent.stateModel.tabID {
            // 탭 닫기 처리 (PIP 보호 확인)
            _ = WebViewPool.shared.handleTabClose(tabID)
            TabPersistenceManager.debugMessages.append("🏊‍♂️ 웹뷰 해체 - 풀 처리: 탭 \(String(tabID.uuidString.prefix(8)))")
        }

        // KVO 옵저버 제거
        coordinator.removeLoadingObservers(for: uiView)

        // 스크롤/델리게이트 해제
        uiView.scrollView.delegate = nil
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil // 📁 네비게이션 델리게이트도 해제
        coordinator.webView = nil

        // 🎭 제스처 제거
        coordinator.removeSlideTransitionGesture(from: uiView)

        // 오디오 세션 비활성화 (헬퍼 호출)
        deactivateAudioSession()

        // 메시지 핸들러 제거
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "playVideo")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "setZoom")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "spaNavigation")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "saveImage")

        // 모든 옵저버 제거
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKUIDelegate, UIScrollViewDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {

        var parent: CustomWebView
        weak var webView: WKWebView?

        // ✨ 데스크탑 모드 변경 감지용 플래그
        var lastDesktopMode: Bool = false

        // 🎭 슬라이드 전환 효과가 적용된 제스처 관리
        private var leftEdgeGesture: UIScreenEdgePanGestureRecognizer?
        private var rightEdgeGesture: UIScreenEdgePanGestureRecognizer?
        
        // 🎭 전환 효과 상태 관리
        private var transitionInProgress = false
        
        // 📁 **다운로드 진행률 UI 구성 요소들 (헬퍼가 관리)**
        var overlayContainer: UIVisualEffectView?
        var overlayTitleLabel: UILabel?
        var overlayPercentLabel: UILabel?
        var overlayProgress: UIProgressView?

        // ✨ KVO 옵저버들
        private var loadingObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var titleObserver: NSKeyValueObservation?
        private var progressObserver: NSKeyValueObservation?

        init(_ parent: CustomWebView) {
            self.parent = parent
            self.lastDesktopMode = parent.stateModel.isDesktopMode
            super.init()
        }

        deinit {
            removeLoadingObservers(for: webView)
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: - 🎬 **PIP 이벤트 핸들러 추가**
        
        @objc func handlePIPStart(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let tabID = userInfo["tabID"] as? UUID,
                  let url = userInfo["url"] as? URL,
                  tabID == parent.stateModel.tabID else { return }
            
            // PIP 시작 - PIPManager에 알림
            PIPManager.shared.startPIP(for: tabID, with: url)
            TabPersistenceManager.debugMessages.append("🎬 PIP 시작 요청 수신: 탭 \(String(tabID.uuidString.prefix(8)))")
        }
        
        @objc func handlePIPStop(_ notification: Notification) {
            guard let tabID = parent.stateModel.tabID else { return }
            
            // PIP 종료 - PIPManager에 알림
            PIPManager.shared.stopPIP()
            TabPersistenceManager.debugMessages.append("🎬 PIP 종료 요청 수신: 탭 \(String(tabID.uuidString.prefix(8)))")
        }

        // MARK: - 🎭 슬라이드 전환 효과가 적용된 제스처 설정
        func setupSlideTransitionGesture(for webView: WKWebView) {
            // 왼쪽 에지 제스처 (뒤로가기 - 오른쪽에서 슬라이드)
            let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleSlideTransitionGesture(_:)))
            leftEdge.edges = .left
            leftEdge.delegate = self
            webView.addGestureRecognizer(leftEdge)
            self.leftEdgeGesture = leftEdge
            
            // 오른쪽 에지 제스처 (앞으로가기 - 왼쪽에서 슬라이드)
            let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleSlideTransitionGesture(_:)))
            rightEdge.edges = .right
            rightEdge.delegate = self
            webView.addGestureRecognizer(rightEdge)
            self.rightEdgeGesture = rightEdge
            
            print("🎭 슬라이드 전환 효과 제스처 설정 완료")
        }
        
        func removeSlideTransitionGesture(from webView: WKWebView) {
            if let gesture = leftEdgeGesture {
                webView.removeGestureRecognizer(gesture)
                self.leftEdgeGesture = nil
            }
            if let gesture = rightEdgeGesture {
                webView.removeGestureRecognizer(gesture)
                self.rightEdgeGesture = nil
            }
            
            // 웹뷰 변환 초기화
            webView.transform = .identity
            webView.layer.shadowOpacity = 0.0
        }
        
        // MARK: - 🎭 SlideFromRightIOS 스타일 전환 효과 핸들러
        @objc private func handleSlideTransitionGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard let webView = webView else { return }
            
            let translation = gesture.translation(in: gesture.view)
            let velocity = gesture.velocity(in: gesture.view)
            let isLeftEdge = (gesture.edges == .left)
            let progress = abs(translation.x) / (gesture.view?.bounds.width ?? 1)
            
            switch gesture.state {
            case .began:
                // 전환 시작 - 오버레이 뷰 생성
                if isLeftEdge && parent.stateModel.canGoBack {
                    createSlideTransitionOverlay(for: webView, direction: .back)
                } else if !isLeftEdge && parent.stateModel.canGoForward {
                    createSlideTransitionOverlay(for: webView, direction: .forward)
                }
                
            case .changed:
                // 제스처 진행 중 - 전환 효과 업데이트
                updateSlideTransitionProgress(progress: progress, translation: translation.x, isLeftEdge: isLeftEdge)
                
            case .ended, .cancelled:
                let shouldComplete = progress > 0.3 || abs(velocity.x) > 800
                
                if shouldComplete {
                    // 전환 완료 애니메이션
                    completeSlideTransition(isLeftEdge: isLeftEdge, completion: { [weak self] in
                        // 실제 네비게이션 실행
                        if isLeftEdge && self?.parent.stateModel.canGoBack == true {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            self?.parent.stateModel.goBack()
                            print("🎭 슬라이드 뒤로가기 완료")
                        } else if !isLeftEdge && self?.parent.stateModel.canGoForward == true {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            self?.parent.stateModel.goForward()
                            print("🎭 슬라이드 앞으로가기 완료")
                        }
                        self?.removeSlideTransitionOverlay()
                    })
                } else {
                    // 전환 취소 애니메이션
                    cancelSlideTransition()
                }
                
            default:
                break
            }
        }
        
        // MARK: - 🎭 슬라이드 전환 오버레이 관리
        
        private enum SlideDirection {
            case back, forward
        }
        
        private func createSlideTransitionOverlay(for webView: WKWebView, direction: SlideDirection) {
            guard transitionOverlayView == nil else { return }
            
            // 현재 웹뷰의 스크린샷 생성
            let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
            let screenshot = renderer.image { context in
                webView.layer.render(in: context.cgContext)
            }
            
            // 오버레이 뷰 생성
            let overlayView = UIView(frame: webView.bounds)
            overlayView.backgroundColor = .systemBackground
            
            // 스크린샷 이미지 뷰
            let imageView = UIImageView(image: screenshot)
            imageView.frame = webView.bounds
            imageView.contentMode = .scaleAspectFill
            overlayView.addSubview(imageView)
            
            // 그림자 효과
            let shadowView = UIView()
            shadowView.backgroundColor = .black
            shadowView.alpha = 0.2
            shadowView.frame = CGRect(
                x: direction == .back ? -10 : webView.bounds.width + 10,
                y: 0,
                width: 10,
                height: webView.bounds.height
            )
            overlayView.addSubview(shadowView)
            
            // 웹뷰에 추가
            webView.addSubview(overlayView)
            transitionOverlayView = overlayView
            
            // 초기 위치 설정
            let initialX: CGFloat = direction == .back ? -webView.bounds.width : webView.bounds.width
            overlayView.transform = CGAffineTransform(translationX: initialX, y: 0)
        }
        
        private func updateSlideTransitionProgress(progress: CGFloat, translation: CGFloat, isLeftEdge: Bool) {
            guard let overlayView = transitionOverlayView,
                  let webView = webView else { return }
            
            let screenWidth = webView.bounds.width
            
            if isLeftEdge {
                // 왼쪽에서 시작하는 뒤로가기 (오른쪽으로 슬라이드)
                let translateX = max(-screenWidth, -screenWidth + translation)
                overlayView.transform = CGAffineTransform(translationX: translateX, y: 0)
            } else {
                // 오른쪽에서 시작하는 앞으로가기 (왼쪽으로 슬라이드)
                let translateX = min(screenWidth, screenWidth + translation)
                overlayView.transform = CGAffineTransform(translationX: translateX, y: 0)
            }
            
            // 투명도 조절
            overlayView.alpha = 0.3 + (progress * 0.7)
        }
        
        private func completeSlideTransition(isLeftEdge: Bool, completion: @escaping () -> Void) {
            guard let overlayView = transitionOverlayView else {
                completion()
                return
            }
            
            // 완료 애니메이션 - 슬라이드 인
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.5,
                options: [.curveEaseOut],
                animations: {
                    overlayView.transform = .identity
                    overlayView.alpha = 1.0
                },
                completion: { _ in
                    // 잠시 대기 후 네비게이션 실행
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        completion()
                    }
                }
            )
        }
        
        private func cancelSlideTransition() {
            guard let overlayView = transitionOverlayView,
                  let webView = webView else { return }
            
            let screenWidth = webView.bounds.width
            let cancelX: CGFloat = overlayView.transform.tx > 0 ? screenWidth : -screenWidth
            
            // 취소 애니메이션 - 슬라이드 아웃
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                options: [.curveEaseInOut],
                animations: {
                    overlayView.transform = CGAffineTransform(translationX: cancelX, y: 0)
                    overlayView.alpha = 0.0
                },
                completion: { [weak self] _ in
                    self?.removeSlideTransitionOverlay()
                }
            )
        }
        
        private func removeSlideTransitionOverlay() {
            transitionOverlayView?.removeFromSuperview()
            transitionOverlayView = nil
        }
        
        // MARK: - UIGestureRecognizerDelegate
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 에지 제스처는 스크롤과 충돌하지 않음
            return true
        }

        // MARK: - 단순화된 로딩 옵저버 (복잡한 캐시 로직 제거)
        func setupLoadingObservers(for webView: WKWebView) {
            loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                let isLoading = change.newValue ?? false

                DispatchQueue.main.async {
                    if self.parent.stateModel.isLoading != isLoading {
                        self.parent.stateModel.isLoading = isLoading
                    }
                }
            }

            // 진행률 KVO
            progressObserver = webView.observe(\.estimatedProgress, options: [.new, .initial]) { [weak self] webView, change in
                guard let self = self else { return }
                let progress = change.newValue ?? 0.0

                DispatchQueue.main.async {
                    let newProgress = max(0.0, min(1.0, progress))
                    self.parent.stateModel.loadingProgress = newProgress
                }
            }

            // URL KVO
            urlObserver = webView.observe(\.url, options: [.new]) { [weak self] webView, change in
                guard let self = self, let newURL = change.newValue, let url = newURL else { return }

                DispatchQueue.main.async {
                    if self.parent.stateModel.currentURL != url {
                        self.parent.stateModel.setNavigatingFromWebView(true)
                        self.parent.stateModel.currentURL = url
                        self.parent.stateModel.setNavigatingFromWebView(false)
                    }
                }
            }

            // Title KVO
            titleObserver = webView.observe(\.title, options: [.new]) { [weak self] webView, change in
                guard let self = self,
                      let title = change.newValue,
                      let title = title,
                      !title.isEmpty,
                      let currentURL = webView.url else { return }

                DispatchQueue.main.async {
                    // 🔧 URL 기반 제목 업데이트
                    self.parent.stateModel.dataModel.updatePageTitle(for: currentURL, title: title)
                }
            }
        }

        func removeLoadingObservers(for webView: WKWebView?) {
            loadingObserver?.invalidate()
            urlObserver?.invalidate()
            titleObserver?.invalidate()
            progressObserver?.invalidate()
            loadingObserver = nil
            urlObserver = nil
            titleObserver = nil
            progressObserver = nil
        }

        // MARK: - 🌐 통합된 JS 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "playVideo" {
                if let urlString = message.body as? String, let url = URL(string: urlString) {
                    DispatchQueue.main.async {
                        self.parent.playerURL = url
                        self.parent.showAVPlayer = true
                        
                        // 🎬 **PIP 시작 알림 추가**
                        if let tabID = self.parent.stateModel.tabID {
                            PIPManager.shared.startPIP(for: tabID, with: url)
                            TabPersistenceManager.debugMessages.append("🎬 비디오 재생으로 PIP 시작: 탭 \(String(tabID.uuidString.prefix(8)))")
                        }
                    }
                }
            } else if message.name == "setZoom" {
                if let data = message.body as? [String: Any],
                   let zoom = data["zoom"] as? Double {
                    DispatchQueue.main.async {
                        self.parent.stateModel.currentZoomLevel = zoom
                    }
                }
            } else if message.name == "spaNavigation" {
                if let data = message.body as? [String: Any],
                   let type = data["type"] as? String,
                   let urlString = data["url"] as? String,
                   let url = URL(string: urlString) {
                    
                    let title = data["title"] as? String ?? ""
                    let timestamp = data["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000
                    let shouldExclude = data["shouldExclude"] as? Bool ?? false
                    let siteType = data["siteType"] as? String ?? "unknown"
                    
                    DispatchQueue.main.async {
                        if shouldExclude {
                            return
                        }
                        
                        self.parent.stateModel.dataModel.handleSPANavigation(
                            type: type,
                            url: url,
                            title: title,
                            timestamp: timestamp,
                            siteType: siteType
                        )
                    }
                }
            }
        }

        // MARK: Pull to Refresh (헬퍼 호출)
        @objc func handleRefresh(_ sender: UIRefreshControl) {
            handleWebViewRefresh(sender, webView: webView)
        }

        // MARK: 외부 URL 오픈
        @objc func handleExternalOpenURL(_ note: Notification) {
            guard
                let userInfo = note.userInfo,
                let url = userInfo["url"] as? URL,
                let webView = webView
            else { return }
            webView.load(URLRequest(url: url))
        }

        // MARK: 네비게이션 명령
        @objc func reloadWebView() { 
            webView?.reload()
        }
        @objc func goBack() { 
            parent.stateModel.goBack()
        }
        @objc func goForward() { 
            parent.stateModel.goForward()
        }

        // MARK: 스크롤 전달
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll?(scrollView.contentOffset.y)
        }

        // ✅ SSL 인증서 경고 처리 (헬퍼 호출)
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            handleSSLChallenge(webView: webView, challenge: challenge, stateModel: parent.stateModel, completionHandler: completionHandler)
        }

        // MARK: - 🚫 **핵심 추가: 팝업 차단 시스템 통합**
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            
            let sourceURL = webView.url
            let targetURL = navigationAction.request.url
            
            // 🚫 **팝업 차단 확인**
            if PopupBlockManager.shared.shouldBlockPopup(from: sourceURL, targetURL: targetURL) {
                // 팝업 차단 및 알림 발송
                PopupBlockManager.shared.blockPopup(from: sourceURL, targetURL: targetURL)
                
                TabPersistenceManager.debugMessages.append("🚫 팝업 차단됨: \(targetURL?.absoluteString ?? "알 수 없음")")
                
                // 팝업 차단 - nil 반환으로 새 창 생성 방지
                return nil
            }
            
            // 팝업 허용 - 현재 웹뷰에서 로드
            TabPersistenceManager.debugMessages.append("✅ 팝업 허용: \(targetURL?.absoluteString ?? "알 수 없음")")
            webView.load(navigationAction.request)
            return nil
        }
        
        // MARK: - 📷 이미지 저장 컨텍스트 메뉴 처리
        
        /// 웹뷰 컨텍스트 메뉴 커스터마이징
        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            
            // 이미지 요소인지 확인
            guard let url = elementInfo.linkURL ?? extractImageURL(from: elementInfo) else {
                completionHandler(nil)
                return
            }
            
            let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                return self.createImageContextMenu(for: url, webView: webView)
            }
            
            completionHandler(configuration)
        }
        
        /// 이미지 URL 추출
        private func extractImageURL(from elementInfo: WKContextMenuElementInfo) -> URL? {
            // iOS 15+에서 사용 가능한 방법
            if #available(iOS 15.0, *) {
                return elementInfo.linkURL
            }
            return nil
        }
        
        /// 이미지 컨텍스트 메뉴 생성
        private func createImageContextMenu(for url: URL, webView: WKWebView) -> UIMenu {
            var actions: [UIAction] = []
            
            // 이미지 저장 액션
            let saveAction = UIAction(
                title: "사진에 저장",
                image: UIImage(systemName: "square.and.arrow.down"),
                handler: { [weak self] _ in
                    self?.saveImageToPhotoLibrary(from: url)
                }
            )
            actions.append(saveAction)
            
            // 이미지 복사 액션
            let copyAction = UIAction(
                title: "이미지 복사",
                image: UIImage(systemName: "doc.on.doc"),
                handler: { [weak self] _ in
                    self?.copyImageToPasteboard(from: url)
                }
            )
            actions.append(copyAction)
            
            // 이미지 공유 액션
            let shareAction = UIAction(
                title: "공유",
                image: UIImage(systemName: "square.and.arrow.up"),
                handler: { [weak self] _ in
                    self?.shareImage(from: url)
                }
            )
            actions.append(shareAction)
            
            return UIMenu(title: "", children: actions)
        }
        
        /// 사진 라이브러리에 이미지 저장
        private func saveImageToPhotoLibrary(from url: URL) {
            // 1. 권한 확인
            checkPhotoLibraryPermission { [weak self] granted in
                guard granted else {
                    self?.showPermissionAlert()
                    return
                }
                
                // 2. 이미지 다운로드 및 저장
                self?.downloadAndSaveImage(from: url)
            }
        }
        
        /// 사진 라이브러리 권한 확인
        private func checkPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            
            switch status {
            case .authorized, .limited:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    DispatchQueue.main.async {
                        completion(newStatus == .authorized || newStatus == .limited)
                    }
                }
            @unknown default:
                completion(false)
            }
        }
        
        /// 이미지 다운로드 및 저장
        private func downloadAndSaveImage(from url: URL) {
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.showErrorAlert(message: "이미지 다운로드 실패: \(error.localizedDescription)")
                        TabPersistenceManager.debugMessages.append("📷 이미지 다운로드 실패: \(error.localizedDescription)")
                        return
                    }
                    
                    guard let data = data, let image = UIImage(data: data) else {
                        self?.showErrorAlert(message: "이미지 변환에 실패했습니다.")
                        TabPersistenceManager.debugMessages.append("📷 이미지 변환 실패")
                        return
                    }
                    
                    self?.saveImageToLibrary(image)
                }
            }.resume()
        }
        
        /// 실제 이미지 저장
        private func saveImageToLibrary(_ image: UIImage) {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { [weak self] success, error in
                DispatchQueue.main.async {
                    if success {
                        self?.showSuccessAlert()
                        TabPersistenceManager.debugMessages.append("📷 이미지 저장 성공")
                    } else {
                        let errorMsg = error?.localizedDescription ?? "알 수 없는 오류"
                        self?.showErrorAlert(message: "이미지 저장 실패: \(errorMsg)")
                        TabPersistenceManager.debugMessages.append("📷 이미지 저장 실패: \(errorMsg)")
                    }
                }
            }
        }
        
        /// 이미지를 클립보드에 복사
        private func copyImageToPasteboard(from url: URL) {
            URLSession.shared.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    guard let data = data, let image = UIImage(data: data) else {
                        TabPersistenceManager.debugMessages.append("📷 이미지 복사 실패")
                        return
                    }
                    
                    UIPasteboard.general.image = image
                    TabPersistenceManager.debugMessages.append("📷 이미지 클립보드 복사 완료")
                    
                    // 성공 피드백
                    let feedback = UIImpactFeedbackGenerator(style: .light)
                    feedback.impactOccurred()
                }
            }.resume()
        }
        
        /// 이미지 공유
        private func shareImage(from url: URL) {
            URLSession.shared.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    guard let data = data, let image = UIImage(data: data) else {
                        TabPersistenceManager.debugMessages.append("📷 이미지 공유 실패")
                        return
                    }
                    
                    guard let topVC = getTopViewController() else { return }
                    
                    let activityVC = UIActivityViewController(activityItems: [image, url], applicationActivities: nil)
                    activityVC.popoverPresentationController?.sourceView = topVC.view
                    activityVC.popoverPresentationController?.sourceRect = topVC.view.bounds
                    
                    topVC.present(activityVC, animated: true)
                    TabPersistenceManager.debugMessages.append("📷 이미지 공유 시트 표시")
                }
            }.resume()
        }

       // MARK: - 알림 메시지들
        
        private func showPermissionAlert() {
            guard let topVC = getTopViewController() else { return }
            
            let alert = UIAlertController(
                title: "사진 접근 권한 필요",
                message: "이미지를 사진 앱에 저장하려면 사진 접근 권한이 필요합니다.\n\n설정 > 개인정보 보호 및 보안 > 사진에서 권한을 허용해주세요.",
                preferredStyle: .alert
            )
            
            alert.addAction(UIAlertAction(title: "설정으로 이동", style: .default) { _ in
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(settingsURL)
                }
            })
            
            alert.addAction(UIAlertAction(title: "취소", style: .cancel))
            
            topVC.present(alert, animated: true)
        }
        
        private func showErrorAlert(message: String) {
            guard let topVC = getTopViewController() else { return }
            
            let alert = UIAlertController(
                title: "오류",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "확인", style: .default))
            topVC.present(alert, animated: true)
        }
        
        private func showSuccessAlert() {
            guard let topVC = getTopViewController() else { return }
            
            let alert = UIAlertController(
                title: "완료",
                message: "이미지가 사진 앱에 저장되었습니다.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "확인", style: .default))
            topVC.present(alert, animated: true)
            
            // 성공 피드백
            let feedback = UINotificationFeedbackGenerator()
            feedback.notificationOccurred(.success)
        }

        // MARK: 📁 **다운로드 이벤트 핸들러 (헬퍼 호출)**
        @objc func handleDownloadStart(_ note: Notification) {
            let filename = note.userInfo?["filename"] as? String
            showOverlay(filename: filename, overlayContainer: overlayContainer, overlayTitleLabel: overlayTitleLabel, overlayPercentLabel: overlayPercentLabel, overlayProgress: overlayProgress)
        }

        @objc func handleDownloadProgress(_ note: Notification) {
            let progress = note.userInfo?["progress"] as? Double ?? 0
            updateOverlay(progress: progress, overlayProgress: overlayProgress, overlayPercentLabel: overlayPercentLabel)
        }

        @objc func handleDownloadFinish(_ note: Notification) {
            hideOverlay(overlayContainer: overlayContainer)
        }

        @objc func handleDownloadFailed(_ note: Notification) {
            hideOverlay(overlayContainer: overlayContainer)
        }
    }
}
