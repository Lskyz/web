// CustomWebView.swift의 didFailProvisionalNavigation 메서드 수정

func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    // ✨ 로딩 실패 처리
    DispatchQueue.main.async {
        if self.parent.stateModel.isLoading {
            self.parent.stateModel.isLoading = false
        }
        self.parent.stateModel.loadingProgress = 0.0
    }
    
    let nsError = error as NSError
    
    // ✅ 스와이프 뒤로가기 중엔 모든 에러 무시
    if isSwipeBackNavigation {
        parent.stateModel.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        return
    }
    
    // ✅ 사용자 취소는 당연히 무시 (새 URL 입력, 링크 클릭 등)
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        parent.stateModel.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        return
    }
    
    // ✅ 이제 더 많은 에러를 ContentView로 전달 (ContentView에서 잘 처리하니까)
    let shouldNotifyUser = shouldShowErrorToUser(nsError)
    
    if shouldNotifyUser, let tabID = parent.stateModel.tabID {
        NotificationCenter.default.post(
            name: .webViewDidFailLoad,
            object: nil,
            userInfo: [
                "tabID": tabID.uuidString,
                "error": error,
                "url": webView.url?.absoluteString ?? parent.stateModel.currentURL?.absoluteString ?? ""
            ]
        )
        TabPersistenceManager.debugMessages.append("❌ 사용자 알림 에러: \(nsError.code)")
    } else {
        TabPersistenceManager.debugMessages.append("🔕 무시된 에러: \(nsError.code) - \(nsError.localizedDescription)")
    }
    
    parent.stateModel.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
}

// ✅ 더 많은 에러를 사용자에게 알리도록 수정
private func shouldShowErrorToUser(_ error: NSError) -> Bool {
    guard error.domain == NSURLErrorDomain else { return false }
    
    switch error.code {
    // ✅ 사용자가 알아야 할 중요한 에러들
    case NSURLErrorCannotFindHost,           // 잘못된 주소/도메인
         NSURLErrorUnsupportedURL,           // 지원하지 않는 URL 형식
         NSURLErrorBadURL,                   // 잘못된 URL 형식
         NSURLErrorFileDoesNotExist,         // 파일이 존재하지 않음
         NSURLErrorTimedOut,                 // 타임아웃
         NSURLErrorNotConnectedToInternet,   // 인터넷 연결 없음
         NSURLErrorCannotConnectToHost,      // 서버 연결 불가
         NSURLErrorNetworkConnectionLost,    // 네트워크 연결 끊김
         NSURLErrorDNSLookupFailed:          // DNS 조회 실패
        return true
        
    // ✅ 무시할 에러들 (일시적이거나 불필요한 알림)
    case NSURLErrorHTTPTooManyRedirects,     // 리다이렉트 너무 많음 (사이트 문제)
         NSURLErrorResourceUnavailable,      // 리소스 사용 불가 (임시)
         NSURLErrorInternationalRoamingOff,  // 로밍 꺼짐 (설정 문제)
         NSURLErrorCallIsActive,             // 통화 중 (일시적)
         NSURLErrorDataNotAllowed,           // 데이터 사용 불가 (설정 문제)
         NSURLError
