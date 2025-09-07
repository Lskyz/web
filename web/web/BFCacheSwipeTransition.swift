//
//  BFCacheSwipeTransition.swift
//  🔥 **완전 무음 복원 시스템 - 전면 리팩토링**
//  ✅ 델리게이트 캡처 + 프리페인트 가드 + 오버레이 + 메시지 브리지
//  ✅ 정밀 앵커/랜드마크 복원 + 무한스크롤 버스트 + 최종 수렴
//  🚫 Promise 제거, 메시지 체인 기반 파이프라인
//  ⚡ 2.5~3.0초 상한, 24px 오차 내 정착
//

import UIKit
import WebKit
import SwiftUI

// MARK: - 타임스탬프 유틸
fileprivate func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

// MARK: - 🔥 **신규 스냅샷 구조체 (Schema v2)**
struct BFCacheSnapshot: Codable {
    let pageRecord: PageRecord
    var domSnapshot: String?
    
    // 📍 정밀 좌표 + 상대치
    let scrollPosition: CGPoint          // 절대 px 좌표
    let scrollPositionPercent: CGPoint   // 0~100% 상대 좌표
    let contentSize: CGSize              // 콘텐츠 크기
    let viewportSize: CGSize             // 뷰포트 크기
    let actualScrollableSize: CGSize     // 실제 스크롤 가능 최대 크기
    
    // 🎯 앵커 후보 (최대 5개)
    let anchors: [AnchorInfo]
    
    // 🗺️ 랜드마크 (최대 12개)
    let landmarks: [LandmarkInfo]
    
    // 📌 상단 고정 헤더
    let stickyTop: CGFloat
    
    // 🔄 가상 리스트 힌트
    let virtualList: VirtualListInfo?
    
    // ♾️ 무한스크롤 트리거
    let loadTriggers: [LoadTriggerInfo]
    
    // 🖼️ iframe 스크롤 상태 (v2)
    let iframesV2: [IFrameScrollInfo]
    
    // 🔑 레이아웃 서명
    let layoutKey: String
    
    // 📊 스키마 버전
    let schemaVersion: Int
    
    var jsState: [String: Any]?
    let timestamp: Date
    var webViewSnapshotPath: String?
    let captureStatus: CaptureStatus
    let version: Int
    
    enum CaptureStatus: String, Codable {
        case complete       // 모든 데이터 캡처 성공
        case partial        // 일부만 캡처 성공
        case visualOnly     // 이미지만 캡처 성공
        case failed         // 캡처 실패
    }
    
    // 🎯 앵커 정보
    struct AnchorInfo: Codable {
        let selector: String
        let role: String                    // h1|h2|h3|article|main|section|card|list-item|other
        let absTop: CGFloat                 // scrollY + rect.top
        let absLeft: CGFloat                // scrollX + rect.left
        let offsetFromTop: CGFloat          // scroll - abs (뷰포트 기준 오프셋)
        let offsetFromLeft: CGFloat
        let width: CGFloat
        let height: CGFloat
        let textHead: String                // 60자 이내 텍스트 머리말
        let textHash: String                // 텍스트 해시
    }
    
    // 🗺️ 랜드마크 정보
    struct LandmarkInfo: Codable {
        let selector: String
        let role: String
        let absTop: CGFloat
        let textHash: String
    }
    
    // 🔄 가상 리스트 정보
    struct VirtualListInfo: Codable {
        let type: String                    // react-virtualized|RecyclerView|virtual-list|unknown
        let beforePx: CGFloat               // 앞쪽 spacer 높이
        let afterPx: CGFloat                // 뒤쪽 spacer 높이
        let itemHeightAvg: CGFloat          // 평균 아이템 높이
    }
    
    // ♾️ 로드 트리거 정보
    struct LoadTriggerInfo: Codable {
        let selector: String
        let label: String                   // 40자 이내 레이블
    }
    
    // 🖼️ iframe 스크롤 정보 (v2)
    struct IFrameScrollInfo: Codable {
        let selector: String
        let crossOrigin: Bool
        let scrollX: CGFloat
        let scrollY: CGFloat
        let src: String
        let dataAttrs: [String: String]
    }
    
    // Codable을 위한 CodingKeys
    enum CodingKeys: String, CodingKey {
        case pageRecord, domSnapshot, scrollPosition, scrollPositionPercent
        case contentSize, viewportSize, actualScrollableSize
        case anchors, landmarks, stickyTop, virtualList, loadTriggers, iframesV2
        case layoutKey, schemaVersion, jsState, timestamp, webViewSnapshotPath
        case captureStatus, version
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
        
        anchors = try container.decodeIfPresent([AnchorInfo].self, forKey: .anchors) ?? []
        landmarks = try container.decodeIfPresent([LandmarkInfo].self, forKey: .landmarks) ?? []
        stickyTop = try container.decodeIfPresent(CGFloat.self, forKey: .stickyTop) ?? 0
        virtualList = try container.decodeIfPresent(VirtualListInfo.self, forKey: .virtualList)
        loadTriggers = try container.decodeIfPresent([LoadTriggerInfo].self, forKey: .loadTriggers) ?? []
        iframesV2 = try container.decodeIfPresent([IFrameScrollInfo].self, forKey: .iframesV2) ?? []
        layoutKey = try container.decodeIfPresent(String.self, forKey: .layoutKey) ?? ""
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        
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
        
        try container.encode(anchors, forKey: .anchors)
        try container.encode(landmarks, forKey: .landmarks)
        try container.encode(stickyTop, forKey: .stickyTop)
        try container.encodeIfPresent(virtualList, forKey: .virtualList)
        try container.encode(loadTriggers, forKey: .loadTriggers)
        try container.encode(iframesV2, forKey: .iframesV2)
        try container.encode(layoutKey, forKey: .layoutKey)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        
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
         anchors: [AnchorInfo] = [],
         landmarks: [LandmarkInfo] = [],
         stickyTop: CGFloat = 0,
         virtualList: VirtualListInfo? = nil,
         loadTriggers: [LoadTriggerInfo] = [],
         iframesV2: [IFrameScrollInfo] = [],
         layoutKey: String = "",
         schemaVersion: Int = 2,
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
        self.anchors = anchors
        self.landmarks = landmarks
        self.stickyTop = stickyTop
        self.virtualList = virtualList
        self.loadTriggers = loadTriggers
        self.iframesV2 = iframesV2
        self.layoutKey = layoutKey
        self.schemaVersion = schemaVersion
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
}

// MARK: - 🔥 **네비게이션 델리게이트 - 떠나기/도착 캡처**
final class BFCacheNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var system: BFCacheTransitionSystem?
    weak var stateModel: WebViewStateModel?
    weak var dataModel: WebViewDataModel?
    
    // 중복 캡처 방지 (300ms 내)
    private var lastCaptureTime: Date = Date(timeIntervalSince1970: 0)
    private let duplicateGuardInterval: TimeInterval = 0.3
    
    init(system: BFCacheTransitionSystem, stateModel: WebViewStateModel, dataModel: WebViewDataModel) {
        self.system = system
        self.stateModel = stateModel
        self.dataModel = dataModel
        super.init()
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 떠나기 직전 캡처: back/forward 외 네비게이션에 대해 수행
        if navigationAction.navigationType != .backForward {
            let now = Date()
            if now.timeIntervalSince(lastCaptureTime) > duplicateGuardInterval {
                system?.storeLeavingSnapshotIfPossible(webView: webView, stateModel: stateModel!)
                lastCaptureTime = now
            }
        }
        
        // 원래 DataModel의 델리게이트 메서드 호출
        dataModel?.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }
    
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // 새문서 첫 페인트전에 오버레이/차단 활성화
        system?.overlay_begin(webView)
        system?.scrollLock_begin(webView)
        
        // 원래 DataModel의 델리게이트 메서드 호출
        dataModel?.webView(webView, didCommit: navigation)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 도착 스냅샷(백그라운드)
        system?.storeArrivalSnapshotIfPossible(webView: webView, stateModel: stateModel!)
        
        // 원래 DataModel의 델리게이트 메서드 호출
        dataModel?.webView(webView, didFinish: navigation)
    }
    
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // 비정상 종료 복구
        system?.overlay_forceRemove(webView)
        system?.scrollLock_end(webView)
        
        // 원래 DataModel의 델리게이트 메서드 호출
        dataModel?.webViewWebContentProcessDidTerminate?(webView)
    }
    
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        dataModel?.webView(webView, didStartProvisionalNavigation: navigation)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dataModel?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dataModel?.webView(webView, didFail: navigation, withError: error)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        dataModel?.webView(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
    }
    
    @available(iOS 14.0, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        dataModel?.webView?(webView, navigationAction: navigationAction, didBecome: download)
    }
    
    @available(iOS 14.0, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        dataModel?.webView?(webView, navigationResponse: navigationResponse, didBecome: download)
    }
}

// MARK: - 🔥 **상태머신 - 파이프라인 관리**
enum RestoreState: Equatable {
    case idle
    case overlayOn
    case phase1Restoring
    case burstLoading
    case iframeRestoring
    case settling
    case releasing
    case done
    case timedOut
}

enum RestoreEvent {
    case start(snapshot: BFCacheSnapshot)
    case jsMessage(name: String, body: Any?)
    case timeout
}

final class RestoreStateMachine {
    var state: RestoreState = .idle
    weak var webView: WKWebView?
    weak var system: BFCacheTransitionSystem?
    let deadline: Date
    private var currentSnapshot: BFCacheSnapshot?
    private var completion: ((Bool) -> Void)?
    
    init(webView: WKWebView, system: BFCacheTransitionSystem, timeout: TimeInterval = 2.8) {
        self.webView = webView
        self.system = system
        self.deadline = Date().addingTimeInterval(timeout)
    }
    
    func startRestore(snapshot: BFCacheSnapshot, completion: @escaping (Bool) -> Void) {
        self.currentSnapshot = snapshot
        self.completion = completion
        handleEvent(.start(snapshot: snapshot))
    }
    
    func handleEvent(_ event: RestoreEvent) {
        guard let webView = webView, let system = system else {
            completion?(false)
            return
        }
        
        // 타임아웃 체크
        if Date() > deadline && state != .releasing && state != .done {
            timedOutFallback()
            return
        }
        
        switch (state, event) {
        case (.idle, .start(let snapshot)):
            state = .overlayOn
            system.overlay_begin(webView)
            system.scrollLock_begin(webView)
            startPhase1(snapshot: snapshot)
            
        case (.phase1Restoring, .jsMessage(let name, _)) where name == "bfcache_restore_done":
            if needsBurst() {
                state = .burstLoading
                startBurst()
            } else {
                state = .iframeRestoring
                startIframe()
            }
            
        case (.burstLoading, .jsMessage(let name, _)) where name == "bfcache_progressive_done":
            state = .iframeRestoring
            startIframe()
            
        case (.iframeRestoring, .jsMessage(let name, _)) where name == "bfcache_iframe_done":
            state = .settling
            startSettle()
            
        case (.settling, .jsMessage(let name, _)) where name == "bfcache_restore_done":
            state = .releasing
            releaseUI()
            
        case (_, .timeout):
            timedOutFallback()
            
        default:
            break
        }
    }
    
    private func startPhase1(snapshot: BFCacheSnapshot) {
        guard let webView = webView else { return }
        state = .phase1Restoring
        
        let payload = buildPhase1PayloadJSON(snapshot: snapshot)
        let js = """
        (function restoreOnce(){
          const p = \(payload);
          const se = document.scrollingElement || document.documentElement;
          function jumpTo(y){ se.scrollTo({left:p.targetX||0, top:Math.max(0,y), behavior:'auto'}); }
          let used='coordinateFallback', info='';
          
          try {
            // 앵커 우선
            if (Array.isArray(p.anchors)) {
              for (const a of p.anchors) {
                let el = a.selector ? document.querySelector(a.selector) : null;
                if (!el && a.textHash) {
                  const cands = document.querySelectorAll('h1,h2,h3,article,main,.post,.article,.card,.list-item,section,div');
                  for (const e of cands) {
                    const head=(e.innerText||'').trim().slice(0,60).toLowerCase();
                    if (head && head.hash64 && head.hash64()===a.textHash) { el=e; break; }
                  }
                }
                if (el) {
                  const r = el.getBoundingClientRect();
                  const absTop = (window.scrollY||0) + r.top;
                  const y = absTop - (Number(a.offsetFromTop)||0) - (p.stickyTop||0);
                  jumpTo(y);
                  used='anchor'; info=a.selector||'hash';
                  break;
                }
              }
            }
            // 퍼센트
            if (used==='coordinateFallback' && typeof p.percentY==='number') {
              const maxY = Math.max(0, (se.scrollHeight - window.innerHeight));
              const y = Math.min(maxY, Math.max(0, (p.percentY/100) * maxY));
              jumpTo(y); used='percent'; info=String(p.percentY);
            }
            // 랜드마크
            if (used==='coordinateFallback' && Array.isArray(p.landmarks)) {
              let bestAbs=null, bestDist=Infinity;
              for (const lm of p.landmarks) {
                const el = lm.selector ? document.querySelector(lm.selector) : null;
                if (!el) continue;
                const absTop = (window.scrollY||0) + el.getBoundingClientRect().top;
                const d = Math.abs((p.targetY||0) - absTop);
                if (d < bestDist) { bestDist=d; bestAbs=absTop; }
              }
              if (bestAbs!=null) { jumpTo(bestAbs - (p.stickyTop||0)); used='landmark'; info='nearest'; }
            }
          } catch(e) { used='error'; info=String(e); jumpTo(p.targetY||0); }
          
          // 서브픽셀 정리
          const dpr = window.devicePixelRatio||1, fy = Math.round((window.scrollY||0)*dpr)/dpr;
          se.scrollTo({left:p.targetX||0, top:fy, behavior:'auto'});
          
          // 완료 신호
          if (window.webkit?.messageHandlers?.bfcache_restore_done) {
            window.webkit.messageHandlers.bfcache_restore_done.postMessage({ok:true, method:used, info, finalY: fy, t: Date.now()});
          }
        })();
        
        // 텍스트 해시 함수 추가
        if (!String.prototype.hash64) {
          String.prototype.hash64 = function(){
            let h1=0xdeadbeef|0, h2=0x41c6ce57|0;
            for (let i=0;i<this.length;i++){
              const ch=this.charCodeAt(i);
              h1 = Math.imul(h1 ^ ch, 2654435761);
              h2 = Math.imul(h2 ^ ch, 1597334677);
            }
            h1 = (h1 ^ (h1>>>16)) + (h2 ^ (h2>>>13)) | 0;
            h2 = (h2 ^ (h2>>>16)) + (h1 ^ (h1>>>13)) | 0;
            return (BigInt.asUintN(64, (BigInt(h1>>>0)<<32n) | BigInt(h2>>>0))).toString(16);
          };
        }
        """
        
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func startBurst() {
        guard let webView = webView, let snapshot = currentSnapshot else { return }
        
        let targetY = Int(snapshot.scrollPosition.y)
        let js = """
        (function burstLoad(){
          const se = document.scrollingElement || document.documentElement;
          const targetY = \(targetY);
          const maxY = se.scrollHeight - window.innerHeight;
          
          if (maxY < targetY) {
            let cycles=0, prevH=se.scrollHeight, noGain=0, t0=Date.now();
            
            function clickTriggers(){
              try {
                document.querySelectorAll('.load-more,.show-more,[data-testid*="load"],[class*="load"][class*="more"],[aria-label*="더보기"],[aria-label*="more"]').forEach(b=>{ try{ b.click(); }catch(_){} });
              } catch(_){}
            }
            function dispatchEvents(){
              window.dispatchEvent(new Event('scroll', {bubbles:true}));
              window.dispatchEvent(new Event('resize', {bubbles:true}));
            }
            
            function step(){
              if (Date.now()-t0 > 900) return done('timeout');
              if (cycles >= 6) return done('max');
              
              se.scrollTo({top: se.scrollHeight, behavior:'auto'});
              dispatchEvents();
              clickTriggers();
              
              setTimeout(()=>{
                const h = se.scrollHeight;
                if (h > prevH) { prevH=h; noGain=0; } else { noGain++; }
                cycles++;
                if (noGain >= 2) return done('stable');
                step();
              }, 180);
            }
            function done(reason){
              if (window.webkit?.messageHandlers?.bfcache_progressive_done) {
                window.webkit.messageHandlers.bfcache_progressive_done.postMessage({ok:true, cycles, reason, finalH: se.scrollHeight, t: Date.now()});
              }
            }
            step();
          } else {
            if (window.webkit?.messageHandlers?.bfcache_progressive_done) {
              window.webkit.messageHandlers.bfcache_progressive_done.postMessage({ok:true, cycles:0, reason:'skip', t: Date.now()});
            }
          }
        })();
        """
        
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func startIframe() {
        guard let webView = webView, let snapshot = currentSnapshot else { return }
        
        let iframesJSON = buildIframesJSON(snapshot: snapshot)
        let js = """
        (function restoreIframes(){
          const iframes = \(iframesJSON);
          let restored=0;
          (iframes||[]).forEach(info=>{
            try{
              const ifr = document.querySelector(info.selector);
              if (!ifr) return;
              try {
                const doc = ifr.contentWindow.document;
                const se = doc.scrollingElement || doc.documentElement;
                se.scrollTo({left:Number(info.scrollX)||0, top:Number(info.scrollY)||0, behavior:'auto'});
                restored++;
              } catch(e) {
                try { 
                  ifr.contentWindow.postMessage({
                    type:'restoreScroll', 
                    scrollX:Number(info.scrollX)||0, 
                    scrollY:Number(info.scrollY)||0,
                    silentRestore: true
                  }, '*'); 
                  restored++; 
                } catch(_){}
              }
            }catch(_){}
          });
          if (window.webkit?.messageHandlers?.bfcache_iframe_done) {
            window.webkit.messageHandlers.bfcache_iframe_done.postMessage({ok:true, restored, t: Date.now()});
          }
        })();
        """
        
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func startSettle() {
        guard let webView = webView, let snapshot = currentSnapshot else { return }
        
        let targetY = Int(snapshot.scrollPosition.y)
        let js = """
        (function settle(){
          const targetY = \(targetY);
          const se = document.scrollingElement || document.documentElement;
          const vv = window.visualViewport;
          const pageTop = vv ? (vv.pageTop||0) : 0;
          const tol = 24;
          
          function curY(){ return window.scrollY||0; }
          
          let y = curY(), err = (targetY - pageTop) - y, step = Math.max(window.innerHeight, Math.abs(err)), iter=0;
          
          while (Math.abs(err) > tol && iter < 2){
            y += Math.sign(err) * Math.min(Math.abs(err), step);
            se.scrollTo({top: Math.max(0,y), behavior:'auto'});
            step *= 0.5; iter++;
            err = (targetY - pageTop) - curY();
          }
          
          if (window.webkit?.messageHandlers?.bfcache_restore_done) {
            window.webkit.messageHandlers.bfcache_restore_done.postMessage({ok:true, method:'settle', finalY: curY(), iters:iter, errPx: Math.abs((targetY - pageTop) - curY()), t: Date.now()});
          }
        })();
        """
        
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func releaseUI() {
        guard let webView = webView, let system = system else { return }
        state = .done
        
        // hold 해제 + overlay 제거 + scrollLock 해제
        let releaseJS = """
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            try {
              window.__restore_hold_flag__ = false;
              document.documentElement.classList.remove('__restore_hold','__noanchor');
              
              var s = document.querySelector('style[data-restore-style="true"]');
              if (s && s.parentNode) s.parentNode.removeChild(s);
              
              console.log('🛡️ 프리페인트 가드 해제 완료');
            } catch(e) {
              console.error('가드 해제 실패:', e);
            }
          });
        });
        """
        
        webView.evaluateJavaScript(releaseJS) { [weak self] _, _ in
            system.scrollLock_end(webView)
            system.overlay_end(webView)
            self?.completion?(true)
        }
    }
    
    private func timedOutFallback() {
        guard let webView = webView, let system = system else { return }
        state = .timedOut
        
        // 랜드마크 근사로 즉시 공개
        releaseUI()
        system.dbg("⏰ 복원 타임아웃 - 폴백 처리")
    }
    
    private func needsBurst() -> Bool {
        guard let snapshot = currentSnapshot else { return false }
        return snapshot.virtualList != nil || !snapshot.loadTriggers.isEmpty
    }
    
    private func buildPhase1PayloadJSON(snapshot: BFCacheSnapshot) -> String {
        var payload: [String: Any] = [
            "targetX": snapshot.scrollPosition.x,
            "targetY": snapshot.scrollPosition.y,
            "percentX": snapshot.scrollPositionPercent.x,
            "percentY": snapshot.scrollPositionPercent.y,
            "stickyTop": snapshot.stickyTop,
            "layoutKey": snapshot.layoutKey,
            "schemaVersion": snapshot.schemaVersion
        ]
        
        // 앵커 정보 추가
        if !snapshot.anchors.isEmpty {
            payload["anchors"] = snapshot.anchors.map { anchor in
                [
                    "selector": anchor.selector,
                    "role": anchor.role,
                    "absTop": anchor.absTop,
                    "absLeft": anchor.absLeft,
                    "offsetFromTop": anchor.offsetFromTop,
                    "offsetFromLeft": anchor.offsetFromLeft,
                    "width": anchor.width,
                    "height": anchor.height,
                    "textHead": anchor.textHead,
                    "textHash": anchor.textHash
                ]
            }
        }
        
        // 랜드마크 정보 추가
        if !snapshot.landmarks.isEmpty {
            payload["landmarks"] = snapshot.landmarks.map { landmark in
                [
                    "selector": landmark.selector,
                    "role": landmark.role,
                    "absTop": landmark.absTop,
                    "textHash": landmark.textHash
                ]
            }
        }
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        
        return json
    }
    
    private func buildIframesJSON(snapshot: BFCacheSnapshot) -> String {
        let iframes = snapshot.iframesV2.map { iframe in
            [
                "selector": iframe.selector,
                "crossOrigin": iframe.crossOrigin,
                "scrollX": iframe.scrollX,
                "scrollY": iframe.scrollY,
                "src": iframe.src,
                "dataAttrs": iframe.dataAttrs
            ] as [String: Any]
        }
        
        guard let data = try? JSONSerialization.data(withJSONObject: iframes, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        
        return json
    }
}

// MARK: - 🧵 **개선된 제스처 컨텍스트 (먹통 방지)**
private class GestureContext {
    let tabID: UUID
    let gestureID: UUID = UUID()
    weak var webView: WKWebView?
    weak var stateModel: WebViewStateModel?
    private var isValid: Bool = true
    private let validationQueue = DispatchQueue(label: "gesture.validation", attributes: .concurrent)
    
    init(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        self.tabID = tabID
        self.webView = webView
        self.stateModel = stateModel
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 생성: \(String(gestureID.uuidString.prefix(8)))")
    }
    
    func validateAndExecute(_ operation: () -> Void) {
        validationQueue.sync {
            guard isValid else {
                TabPersistenceManager.debugMessages.append("🧵 무효한 컨텍스트 - 작업 취소: \(String(gestureID.uuidString.prefix(8)))")
                return
            }
            operation()
        }
    }
    
    func invalidate() {
        validationQueue.async(flags: .barrier) {
            self.isValid = false
            TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 무효화: \(String(self.gestureID.uuidString.prefix(8)))")
        }
    }
    
    deinit {
        TabPersistenceManager.debugMessages.append("🧵 제스처 컨텍스트 해제: \(String(gestureID.uuidString.prefix(8)))")
    }
}

// MARK: - 🔥 **메시지 브리지 시스템**
private class JSMessageBridge: NSObject, WKScriptMessageHandler {
    private let onMessage: (String, Any?) -> Void
    
    init(_ onMessage: @escaping (String, Any?) -> Void) {
        self.onMessage = onMessage
        super.init()
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message.name, message.body)
    }
}

// MARK: - 🔥 **전면 리팩토링된 BFCache 전환 시스템**
final class BFCacheTransitionSystem: NSObject {
    
    // MARK: - 싱글톤
    static let shared = BFCacheTransitionSystem()
    private override init() {
        super.init()
        // 앱 시작시 디스크 캐시 로드
        loadDiskCacheIndex()
        setupMemoryWarningObserver()
    }
    
    // MARK: - 📸 **직렬화 큐 시스템**
    private let serialQueue = DispatchQueue(label: "bfcache.serial", qos: .userInitiated)
    private let diskIOQueue = DispatchQueue(label: "bfcache.disk", qos: .background)
    
    // MARK: - 💾 스레드 안전 캐시 시스템
    private let cacheAccessQueue = DispatchQueue(label: "bfcache.access", attributes: .concurrent)
    private var _memoryCache: [UUID: BFCacheSnapshot] = [:]
    private var _diskCacheIndex: [UUID: String] = [:]
    private var _cacheVersion: [UUID: Int] = [:]
    
    // 🔥 **네비게이션 델리게이트 관리**
    private var _navigationDelegates: [UUID: BFCacheNavigationDelegate] = [:]
    
    // 🔥 **상태머신 관리**
    private var _stateMachines: [UUID: RestoreStateMachine] = [:]
    
    // 스레드 안전 액세서
    private var memoryCache: [UUID: BFCacheSnapshot] {
        get { cacheAccessQueue.sync { _memoryCache } }
    }
    
    private func setMemoryCache(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache[pageID] = snapshot
        }
    }
    
    private func removeFromMemoryCache(_ pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._memoryCache.removeValue(forKey: pageID)
        }
    }
    
    private var diskCacheIndex: [UUID: String] {
        get { cacheAccessQueue.sync { _diskCacheIndex } }
    }
    
    private func setDiskIndex(_ path: String, for pageID: UUID) {
        cacheAccessQueue.async(flags: .barrier) {
            self._diskCacheIndex[pageID] = path
        }
    }
    
    // MARK: - 📁 파일 시스템 경로
    private var bfCacheDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("BFCache", isDirectory: true)
    }
    
    private func tabDirectory(for tabID: UUID) -> URL {
        return bfCacheDirectory.appendingPathComponent("Tab_\(tabID.uuidString)", isDirectory: true)
    }
    
    private func pageDirectory(for pageID: UUID, tabID: UUID, version: Int) -> URL {
        return tabDirectory(for: tabID).appendingPathComponent("Page_\(pageID.uuidString)_v\(version)", isDirectory: true)
    }
    
    // MARK: - 🧵 **제스처 전환 상태 (리팩토링된 스레드 안전 관리)**
    private let gestureQueue = DispatchQueue(label: "gesture.management", attributes: .concurrent)
    private var _activeTransitions: [UUID: TransitionContext] = [:]
    private var _gestureContexts: [UUID: GestureContext] = [:]
    
    // 🧵 **스레드 안전 activeTransitions 접근**
    private var activeTransitions: [UUID: TransitionContext] {
        get { gestureQueue.sync { _activeTransitions } }
    }
    
    private func setActiveTransition(_ context: TransitionContext, for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions[tabID] = context
        }
    }
    
    private func removeActiveTransition(for tabID: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._activeTransitions.removeValue(forKey: tabID)
        }
    }
    
    private func getActiveTransition(for tabID: UUID) -> TransitionContext? {
        return gestureQueue.sync { _activeTransitions[tabID] }
    }
    
    // 🧵 **제스처 컨텍스트 관리**
    private func setGestureContext(_ context: GestureContext, for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            self._gestureContexts[key] = context
        }
    }
    
    private func removeGestureContext(for key: UUID) {
        gestureQueue.async(flags: .barrier) {
            if let context = self._gestureContexts.removeValue(forKey: key) {
                context.invalidate()
            }
        }
    }
    
    private func getGestureContext(for key: UUID) -> GestureContext? {
        return gestureQueue.sync { _gestureContexts[key] }
    }
    
    // 전환 컨텍스트
    private struct TransitionContext {
        let tabID: UUID
        weak var webView: WKWebView?
        weak var stateModel: WebViewStateModel?
        var isGesture: Bool
        var direction: NavigationDirection
        var initialTransform: CGAffineTransform
        var previewContainer: UIView?
        var currentSnapshot: UIImage?
    }
    
    enum NavigationDirection {
        case back, forward
    }
    
    enum CaptureType {
        case immediate  // 현재 페이지 (높은 우선순위)
        case background // 과거 페이지 (일반 우선순위)
    }
    
    // MARK: - 🔥 **프리페인트 가드 스크립트**
    
    static func makePrepaintGuardScript() -> WKUserScript {
        let js = """
        (function(){
            try {
                // UA 자동 복원 끄기
                try { 
                    history.scrollRestoration = 'manual'; 
                } catch(_) {}

                // 프리페인트 가드 클래스 부여 (첫 페인트 이전)
                document.documentElement.classList.add('__restore_hold','__noanchor');

                // 스타일 주입: 스크롤/앵커/전환/애니메이션 차단
                var style = document.createElement('style');
                style.setAttribute('data-restore-style','true');
                style.textContent = `
                    html.__restore_hold { visibility:hidden !important; }
                    html { scroll-behavior:auto !important; }
                    html.__noanchor, body.__noanchor, * { overflow-anchor:none !important; }
                    *,*::before,*::after { transition:none !important; animation:none !important; }
                    * { scroll-margin-top:0 !important; }
                `;
                (document.head || document.documentElement).appendChild(style);

                // 스크롤 명령/앵커 점프/해시 점프 임시 봉인
                window.__restore_hold_flag__ = true;
                (function(){
                    const _scrollTo = window.scrollTo;
                    window.scrollTo = function(){
                        if(!window.__restore_hold_flag__) return _scrollTo.apply(this, arguments);
                    };
                    const _siv = Element.prototype.scrollIntoView;
                    Element.prototype.scrollIntoView = function(){
                        if(!window.__restore_hold_flag__) return _siv.apply(this, arguments);
                    };
                    window.addEventListener('hashchange', function(e){
                        if(window.__restore_hold_flag__) e.stopImmediatePropagation();
                    }, true);
                })();

                // 초기 포커스 해제: 키보드/포커스 스크롤 방지
                try { 
                    document.activeElement && document.activeElement.blur(); 
                } catch(_) {}
                
                console.log('🛡️ 프리페인트 가드 활성화');
            } catch(e) {
                console.error('프리페인트 가드 실패:', e);
            }
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 🔥 **도메인 특화 DOM 캡처 시스템**
    
    private func performAtomicCapture(_ task: CaptureTask) {
        let pageID = task.pageRecord.id
        
        // 중복 캡처 방지 (진행 중인 것만)
        guard !pendingCaptures.contains(pageID) else {
            dbg("⏸️ 중복 캡처 방지: \(task.pageRecord.title)")
            return
        }
        
        guard let webView = task.webView else {
            dbg("❌ 웹뷰 해제됨 - 캡처 취소: \(task.pageRecord.title)")
            return
        }
        
        // 진행 중 표시
        pendingCaptures.insert(pageID)
        dbg("🎯 도메인 특화 DOM 직렬 캡처 시작: \(task.pageRecord.title) (\(task.type))")
        
        // 메인 스레드에서 웹뷰 상태 확인
        let captureData = DispatchQueue.main.sync { () -> CaptureData? in
            // 웹뷰가 준비되었는지 확인
            guard webView.window != nil, !webView.bounds.isEmpty else {
                self.dbg("⚠️ 웹뷰 준비 안됨 - 캡처 스킵: \(task.pageRecord.title)")
                return nil
            }
            
            // 실제 스크롤 가능한 최대 크기 감지
            let actualScrollableWidth = max(webView.scrollView.contentSize.width, webView.scrollView.bounds.width)
            let actualScrollableHeight = max(webView.scrollView.contentSize.height, webView.scrollView.bounds.height)
            
            return CaptureData(
                scrollPosition: webView.scrollView.contentOffset,
                contentSize: webView.scrollView.contentSize,
                viewportSize: webView.bounds.size,
                actualScrollableSize: CGSize(width: actualScrollableWidth, height: actualScrollableHeight),
                bounds: webView.bounds,
                isLoading: webView.isLoading
            )
        }
        
        guard let data = captureData else {
            pendingCaptures.remove(pageID)
            return
        }
        
        // 🔧 **도메인 특화 캡처 로직 - 실패 시 재시도**
        let captureResult = performRobustDOMCapture(
            pageRecord: task.pageRecord,
            webView: webView,
            captureData: data,
            retryCount: task.type == .immediate ? 2 : 0
        )
        
        // 캡처 완료 후 저장
        if let tabID = task.tabID {
            saveToDisk(snapshot: captureResult, tabID: tabID)
        } else {
            storeInMemory(captureResult.snapshot, for: pageID)
        }
        
        // 진행 중 해제
        pendingCaptures.remove(pageID)
        dbg("✅ 도메인 특화 DOM 직렬 캡처 완료: \(task.pageRecord.title)")
    }
    
    private struct CaptureData {
        let scrollPosition: CGPoint
        let contentSize: CGSize
        let viewportSize: CGSize
        let actualScrollableSize: CGSize
        let bounds: CGRect
        let isLoading: Bool
    }
    
    private struct CaptureTask {
        let pageRecord: PageRecord
        let tabID: UUID?
        let type: CaptureType
        weak var webView: WKWebView?
        let requestedAt: Date = Date()
    }
    
    // 중복 방지를 위한 진행 중인 캡처 추적
    private var pendingCaptures: Set<UUID> = []
    
    // 🔧 **도메인 특화 DOM 캡처 - 안정화 대기 + 정밀 앵커 수집**
    private func performRobustDOMCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData, retryCount: Int = 0) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        
        for attempt in 0...retryCount {
            let result = attemptDOMCapture(pageRecord: pageRecord, webView: webView, captureData: captureData)
            
            // 성공하거나 마지막 시도면 결과 반환
            if result.snapshot.captureStatus != .failed || attempt == retryCount {
                if attempt > 0 {
                    dbg("🔄 재시도 후 DOM 캡처 성공: \(pageRecord.title) (시도: \(attempt + 1))")
                }
                return result
            }
            
            // 재시도 전 대기
            dbg("⏳ DOM 캡처 실패 - 재시도 (\(attempt + 1)/\(retryCount + 1)): \(pageRecord.title)")
            Thread.sleep(forTimeInterval: 0.08)
        }
        
        // 여기까지 오면 모든 시도 실패
        return (BFCacheSnapshot(pageRecord: pageRecord, scrollPosition: captureData.scrollPosition, actualScrollableSize: captureData.actualScrollableSize, timestamp: Date(), captureStatus: .failed, version: 1), nil)
    }
    
    private func attemptDOMCapture(pageRecord: PageRecord, webView: WKWebView, captureData: CaptureData) -> (snapshot: BFCacheSnapshot, image: UIImage?) {
        var visualSnapshot: UIImage? = nil
        var domSnapshot: String? = nil
        var anchors: [BFCacheSnapshot.AnchorInfo] = []
        var landmarks: [BFCacheSnapshot.LandmarkInfo] = []
        var stickyTop: CGFloat = 0
        var virtualList: BFCacheSnapshot.VirtualListInfo? = nil
        var loadTriggers: [BFCacheSnapshot.LoadTriggerInfo] = []
        var iframesV2: [BFCacheSnapshot.IFrameScrollInfo] = []
        var layoutKey: String = ""
        
        let semaphore = DispatchSemaphore(value: 0)
        
        // 1. 비주얼 스냅샷 (메인 스레드)
        DispatchQueue.main.sync {
            let config = WKSnapshotConfiguration()
            config.rect = captureData.bounds
            config.afterScreenUpdates = false
            
            webView.takeSnapshot(with: config) { image, error in
                if let error = error {
                    self.dbg("📸 스냅샷 실패, fallback 사용: \(error.localizedDescription)")
                    visualSnapshot = self.renderWebViewToImage(webView)
                } else {
                    visualSnapshot = image
                }
                semaphore.signal()
            }
        }
        
        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut {
            dbg("⏰ 스냅샷 캡처 타임아웃: \(pageRecord.title)")
            visualSnapshot = renderWebViewToImage(webView)
        }
        
        // 2. 🔥 **도메인 특화 DOM 정밀 캡처** - 안정화 대기 + 정밀 수집
        let domSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            let domScript = generateAdvancedDOMCaptureScript()
            
            webView.evaluateJavaScript(domScript) { result, error in
                if let resultString = result as? String,
                   let data = resultString.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    // DOM HTML
                    domSnapshot = parsed["domSnapshot"] as? String
                    
                    // 앵커 정보 파싱
                    if let anchorArray = parsed["anchors"] as? [[String: Any]] {
                        anchors = anchorArray.compactMap { anchorDict in
                            guard let selector = anchorDict["selector"] as? String,
                                  let role = anchorDict["role"] as? String,
                                  let absTop = anchorDict["absTop"] as? Double,
                                  let absLeft = anchorDict["absLeft"] as? Double,
                                  let offsetFromTop = anchorDict["offsetFromTop"] as? Double,
                                  let offsetFromLeft = anchorDict["offsetFromLeft"] as? Double,
                                  let width = anchorDict["width"] as? Double,
                                  let height = anchorDict["height"] as? Double,
                                  let textHead = anchorDict["textHead"] as? String,
                                  let textHash = anchorDict["textHash"] as? String else { return nil }
                            
                            return BFCacheSnapshot.AnchorInfo(
                                selector: selector,
                                role: role,
                                absTop: CGFloat(absTop),
                                absLeft: CGFloat(absLeft),
                                offsetFromTop: CGFloat(offsetFromTop),
                                offsetFromLeft: CGFloat(offsetFromLeft),
                                width: CGFloat(width),
                                height: CGFloat(height),
                                textHead: textHead,
                                textHash: textHash
                            )
                        }
                    }
                    
                    // 랜드마크 정보 파싱
                    if let landmarkArray = parsed["landmarks"] as? [[String: Any]] {
                        landmarks = landmarkArray.compactMap { landmarkDict in
                            guard let selector = landmarkDict["selector"] as? String,
                                  let role = landmarkDict["role"] as? String,
                                  let absTop = landmarkDict["absTop"] as? Double,
                                  let textHash = landmarkDict["textHash"] as? String else { return nil }
                            
                            return BFCacheSnapshot.LandmarkInfo(
                                selector: selector,
                                role: role,
                                absTop: CGFloat(absTop),
                                textHash: textHash
                            )
                        }
                    }
                    
                    // 기타 정보
                    stickyTop = CGFloat(parsed["stickyTop"] as? Double ?? 0)
                    layoutKey = parsed["layoutKey"] as? String ?? ""
                    
                    // 가상 리스트 정보
                    if let vlDict = parsed["virtualList"] as? [String: Any] {
                        virtualList = BFCacheSnapshot.VirtualListInfo(
                            type: vlDict["type"] as? String ?? "unknown",
                            beforePx: CGFloat(vlDict["beforePx"] as? Double ?? 0),
                            afterPx: CGFloat(vlDict["afterPx"] as? Double ?? 0),
                            itemHeightAvg: CGFloat(vlDict["itemHeightAvg"] as? Double ?? 0)
                        )
                    }
                    
                    // 로드 트리거 정보
                    if let triggerArray = parsed["loadTriggers"] as? [[String: Any]] {
                        loadTriggers = triggerArray.compactMap { triggerDict in
                            guard let selector = triggerDict["selector"] as? String,
                                  let label = triggerDict["label"] as? String else { return nil }
                            
                            return BFCacheSnapshot.LoadTriggerInfo(
                                selector: selector,
                                label: label
                            )
                        }
                    }
                    
                    // iframe 정보
                    if let iframeArray = parsed["iframesV2"] as? [[String: Any]] {
                        iframesV2 = iframeArray.compactMap { iframeDict in
                            guard let selector = iframeDict["selector"] as? String,
                                  let crossOrigin = iframeDict["crossOrigin"] as? Bool,
                                  let scrollX = iframeDict["scrollX"] as? Double,
                                  let scrollY = iframeDict["scrollY"] as? Double,
                                  let src = iframeDict["src"] as? String,
                                  let dataAttrs = iframeDict["dataAttrs"] as? [String: String] else { return nil }
                            
                            return BFCacheSnapshot.IFrameScrollInfo(
                                selector: selector,
                                crossOrigin: crossOrigin,
                                scrollX: CGFloat(scrollX),
                                scrollY: CGFloat(scrollY),
                                src: src,
                                dataAttrs: dataAttrs
                            )
                        }
                    }
                    
                    self.dbg("🎯 DOM 정보 파싱 완료 - 앵커: \(anchors.count), 랜드마크: \(landmarks.count), 트리거: \(loadTriggers.count)")
                }
                domSemaphore.signal()
            }
        }
        _ = domSemaphore.wait(timeout: .now() + 2.0)
        
        // 캡처 상태 결정
        let captureStatus: BFCacheSnapshot.CaptureStatus
        if visualSnapshot != nil && domSnapshot != nil && !anchors.isEmpty {
            captureStatus = .complete
        } else if visualSnapshot != nil {
            captureStatus = !anchors.isEmpty ? .partial : .visualOnly
        } else {
            captureStatus = .failed
        }
        
        // 버전 증가 (스레드 안전)
        let version: Int = cacheAccessQueue.sync(flags: .barrier) { [weak self] in
            guard let self = self else { return 1 }
            let currentVersion = self._cacheVersion[pageRecord.id] ?? 0
            let newVersion = currentVersion + 1
            self._cacheVersion[pageRecord.id] = newVersion
            return newVersion
        }
        
        // 상대적 위치 계산 (백분율)
        let scrollPercent: CGPoint
        if captureData.actualScrollableSize.width > captureData.viewportSize.width && captureData.actualScrollableSize.height > captureData.viewportSize.height {
            let maxScrollX = captureData.actualScrollableSize.width - captureData.viewportSize.width
            let maxScrollY = captureData.actualScrollableSize.height - captureData.viewportSize.height
            
            scrollPercent = CGPoint(
                x: maxScrollX > 0 ? (captureData.scrollPosition.x / maxScrollX * 100.0) : 0,
                y: maxScrollY > 0 ? (captureData.scrollPosition.y / maxScrollY * 100.0) : 0
            )
        } else {
            scrollPercent = CGPoint.zero
        }
        
        let snapshot = BFCacheSnapshot(
            pageRecord: pageRecord,
            domSnapshot: domSnapshot,
            scrollPosition: captureData.scrollPosition,
            scrollPositionPercent: scrollPercent,
            contentSize: captureData.contentSize,
            viewportSize: captureData.viewportSize,
            actualScrollableSize: captureData.actualScrollableSize,
            anchors: anchors,
            landmarks: landmarks,
            stickyTop: stickyTop,
            virtualList: virtualList,
            loadTriggers: loadTriggers,
            iframesV2: iframesV2,
            layoutKey: layoutKey,
            schemaVersion: 2,
            jsState: nil,
            timestamp: Date(),
            webViewSnapshotPath: nil,
            captureStatus: captureStatus,
            version: version
        )
        
        return (snapshot, visualSnapshot)
    }
    
    // 🔥 **도메인 특화 DOM 캡처 JavaScript 생성 - 안정화 대기 + 정밀 수집**
    private func generateAdvancedDOMCaptureScript() -> String {
        return """
        (function() {
            try {
                console.log('🎯 도메인 특화 DOM 캡처 시작');
                
                // 🔥 **1단계: 안정화 대기 (최대 0.5초)**
                return waitForStabilization().then(performPreciseCapture);
                
            } catch(e) {
                console.error('🎯 DOM 캡처 실패:', e);
                return JSON.stringify({
                    domSnapshot: null,
                    anchors: [],
                    landmarks: [],
                    stickyTop: 0,
                    layoutKey: '',
                    virtualList: null,
                    loadTriggers: [],
                    iframesV2: []
                });
            }
            
            // 🔥 **안정화 대기 함수**
            function waitForStabilization() {
                return new Promise((resolve) => {
                    let lastHeight = document.documentElement.scrollHeight;
                    let stableFrames = 0;
                    let frameCount = 0;
                    const maxFrames = 30; // 약 0.5초
                    
                    function checkStability() {
                        const currentHeight = document.documentElement.scrollHeight;
                        
                        if (Math.abs(currentHeight - lastHeight) < 1) {
                            stableFrames++;
                            if (stableFrames >= 2) {
                                console.log('🎯 안정화 완료 - 프레임:', frameCount);
                                resolve();
                                return;
                            }
                        } else {
                            stableFrames = 0;
                            lastHeight = currentHeight;
                        }
                        
                        frameCount++;
                        if (frameCount >= maxFrames) {
                            console.log('🎯 안정화 타임아웃 - 즉시 캡처');
                            resolve();
                            return;
                        }
                        
                        requestAnimationFrame(checkStability);
                    }
                    
                    requestAnimationFrame(checkStability);
                });
            }
            
            // 🔥 **정밀 캡처 함수**
            function performPreciseCapture() {
                const result = {
                    domSnapshot: null,
                    anchors: [],
                    landmarks: [],
                    stickyTop: 0,
                    layoutKey: '',
                    virtualList: null,
                    loadTriggers: [],
                    iframesV2: []
                };
                
                try {
                    // DOM 스냅샷
                    if (document.readyState === 'complete') {
                        const html = document.documentElement.outerHTML;
                        result.domSnapshot = html.length > 100000 ? html.substring(0, 100000) : html;
                    }
                    
                    // 텍스트 해시 함수 추가
                    if (!String.prototype.hash64) {
                        String.prototype.hash64 = function(){
                            let h1=0xdeadbeef|0, h2=0x41c6ce57|0;
                            for (let i=0;i<this.length;i++){
                                const ch=this.charCodeAt(i);
                                h1 = Math.imul(h1 ^ ch, 2654435761);
                                h2 = Math.imul(h2 ^ ch, 1597334677);
                            }
                            h1 = (h1 ^ (h1>>>16)) + (h2 ^ (h2>>>13)) | 0;
                            h2 = (h2 ^ (h2>>>16)) + (h1 ^ (h1>>>13)) | 0;
                            return (BigInt.asUintN(64, (BigInt(h1>>>0)<<32n) | BigInt(h2>>>0))).toString(16);
                        };
                    }
                    
                    // 📍 **앵커 후보 수집 (최대 5개)**
                    result.anchors = collectAnchors();
                    
                    // 🗺️ **랜드마크 수집 (최대 12개)**
                    result.landmarks = collectLandmarks();
                    
                    // 📌 **상단 고정 헤더 측정**
                    result.stickyTop = measureStickyTop();
                    
                    // 🔑 **레이아웃 서명 생성**
                    result.layoutKey = generateLayoutKey();
                    
                    // 🔄 **가상 리스트 감지**
                    result.virtualList = detectVirtualList();
                    
                    // ♾️ **로드 트리거 수집**
                    result.loadTriggers = collectLoadTriggers();
                    
                    // 🖼️ **iframe 스크롤 상태 수집**
                    result.iframesV2 = collectIFrameScrolls();
                    
                } catch(e) {
                    console.error('정밀 캡처 에러:', e);
                }
                
                console.log('🎯 정밀 캡처 완료:', {
                    anchors: result.anchors.length,
                    landmarks: result.landmarks.length,
                    stickyTop: result.stickyTop,
                    triggers: result.loadTriggers.length,
                    iframes: result.iframesV2.length
                });
                
                return JSON.stringify(result);
            }
            
            // 🎯 **앵커 후보 수집 함수**
            function collectAnchors() {
                const candidates = Array.from(document.querySelectorAll(
                    'h1,h2,h3,article,main,[role="main"],.post,.article,.card,.list-item,section'
                ));
                
                const viewportHeight = window.innerHeight;
                const viewportWidth = window.innerWidth;
                const scrollY = window.scrollY || window.pageYOffset || 0;
                const scrollX = window.scrollX || window.pageXOffset || 0;
                
                function bestSelector(el){
                    if (!el || el.nodeType!==1) return null;
                    if (el.id) return '#' + CSS.escape(el.id);
                    
                    // data-* 조합 유니크
                    const dataAttrs = Array.from(el.attributes).filter(a=>a.name.startsWith('data-'));
                    if (dataAttrs.length){
                        const sel = el.tagName.toLowerCase() + dataAttrs.map(a=>'[' + CSS.escape(a.name) + '="' + CSS.escape(a.value) + '"]').join('');
                        if (document.querySelectorAll(sel).length===1) return sel;
                    }
                    
                    // class 조합 유니크
                    const classes = (el.className||'').trim().split(/\\s+/).filter(Boolean);
                    if (classes.length){
                        const sel = el.tagName.toLowerCase()+'.'+classes.map(c=>CSS.escape(c)).join('.');
                        if (document.querySelectorAll(sel).length===1) return sel;
                    }
                    
                    // 짧은 경로(최대 4단계)
                    let path=[], cur=el, depth=0;
                    while (cur && cur!==document.documentElement && depth<4){
                        let seg = cur.tagName.toLowerCase();
                        if (cur.id) { seg = '#' + CSS.escape(cur.id); path.unshift(seg); break; }
                        const cls = (cur.className||'').trim().split(/\\s+/).filter(Boolean).slice(0,2).map(c=>'.'+CSS.escape(c)).join('');
                        seg += cls;
                        path.unshift(seg);
                        cur = cur.parentElement; depth++;
                    }
                    return path.join(' > ') || null;
                }
                
                const validCandidates = candidates.filter(el => {
                    const rect = el.getBoundingClientRect();
                    // 뷰포트에 부분이라도 걸치는 요소만
                    return rect.bottom > 0 && rect.top < viewportHeight && 
                           rect.right > 0 && rect.left < viewportWidth;
                }).map(el => {
                    const rect = el.getBoundingClientRect();
                    const centerY = rect.top + rect.height / 2;
                    const centerX = rect.left + rect.width / 2;
                    
                    // 뷰포트 중앙에 가까울수록 + 적당한 크기일수록 높은 점수
                    const distanceFromCenter = Math.sqrt(
                        Math.pow(centerX - viewportWidth / 2, 2) + 
                        Math.pow(centerY - viewportHeight / 2, 2)
                    );
                    
                    const sizeScore = Math.min(rect.width * rect.height / (viewportWidth * viewportHeight), 1);
                    const idealSizeRatio = 0.3;
                    const sizePenalty = Math.abs(sizeScore - idealSizeRatio);
                    
                    const score = (viewportWidth + viewportHeight - distanceFromCenter) * (1 - sizePenalty);
                    
                    return {
                        element: el,
                        rect: rect,
                        score: score
                    };
                }).sort((a, b) => b.score - a.score).slice(0, 5); // 상위 5개
                
                return validCandidates.map(item => {
                    const el = item.element;
                    const rect = item.rect;
                    
                    const absTop = scrollY + rect.top;
                    const absLeft = scrollX + rect.left;
                    
                    const offsetFromTop = scrollY - absTop;
                    const offsetFromLeft = scrollX - absLeft;
                    
                    const textContent = (el.innerText || '').slice(0, 60);
                    const textHash = textContent.toLowerCase().hash64();
                    
                    const role = el.tagName.toLowerCase();
                    
                    return {
                        selector: bestSelector(el) || '',
                        role: role,
                        absTop: absTop,
                        absLeft: absLeft,
                        offsetFromTop: offsetFromTop,
                        offsetFromLeft: offsetFromLeft,
                        width: rect.width,
                        height: rect.height,
                        textHead: textContent,
                        textHash: textHash
                    };
                });
            }
            
            // 🗺️ **랜드마크 수집 함수**
            function collectLandmarks() {
                const landmarkCandidates = Array.from(document.querySelectorAll(
                    'header,nav,main,article,section,aside,footer,h1,h2,h3,.navigation,.sidebar,.content,.main-content'
                ));
                
                const scrollY = window.scrollY || window.pageYOffset || 0;
                
                function bestSelector(el){
                    if (!el || el.nodeType!==1) return null;
                    if (el.id) return '#' + CSS.escape(el.id);
                    const classes = (el.className||'').trim().split(/\\s+/).filter(Boolean);
                    if (classes.length){
                        const sel = el.tagName.toLowerCase()+'.'+classes.map(c=>CSS.escape(c)).join('.');
                        if (document.querySelectorAll(sel).length===1) return sel;
                    }
                    return el.tagName.toLowerCase();
                }
                
                return landmarkCandidates.slice(0, 12).map(el => {
                    const rect = el.getBoundingClientRect();
                    const absTop = scrollY + rect.top;
                    const txt = (el.innerText || '').slice(0, 60);
                    const textHash = txt.toLowerCase().hash64();
                    const role = el.tagName.toLowerCase();
                    
                    return {
                        selector: bestSelector(el) || '',
                        role: role,
                        absTop: absTop,
                        textHash: textHash
                    };
                });
            }
            
            // 📌 **상단 고정 헤더 측정**
            function measureStickyTop(){
                let maxH = 0;
                const els = Array.from(document.querySelectorAll('body *'));
                for (const el of els){
                    const cs = getComputedStyle(el);
                    const sticky = (cs.position==='fixed' || cs.position==='sticky');
                    if (!sticky) continue;
                    const r = el.getBoundingClientRect();
                    const visible = r.bottom > 0 && r.top < 0.5*window.innerHeight; // 화면 위쪽에 걸치면 고려
                    if (!visible) continue;
                    const h = Math.min(r.bottom, 0) < 0 ? 0 : Math.max(0, r.bottom - Math.max(r.top, 0));
                    maxH = Math.max(maxH, h);
                }
                return Math.min(maxH, 240); // 비정상 값 상한
            }
            
            // 🔑 **레이아웃 서명 생성**
            function generateLayoutKey(){
                const heads = Array.from(document.querySelectorAll('h1,h2,.title')).slice(0,3).map(el=>(el.innerText||'').trim().slice(0,40)).join('|').toLowerCase();
                const cls = Array.from(document.body.classList).slice(0,4).join('.');
                return (heads + '#' + cls).hash64();
            }
            
            // 🔄 **가상 리스트 감지**
            function detectVirtualList(){
                const before = document.querySelector('[data-testid="before"],[data-rv="before"],.virtual-before');
                const after  = document.querySelector('[data-testid="after"],[data-rv="after"],.virtual-after');
                const item   = document.querySelector('[data-virt-item],.virtual-item,.rv-item');
                const r = { type:'unknown', beforePx:0, afterPx:0, itemHeightAvg:0 };
                if (before) r.beforePx = Math.max(0, before.getBoundingClientRect().height);
                if (after)  r.afterPx  = Math.max(0, after.getBoundingClientRect().height);
                if (item)   r.itemHeightAvg = Math.max(0, item.getBoundingClientRect().height);
                if (before || after || item) r.type = 'virtual-list';
                return r;
            }
            
            // ♾️ **로드 트리거 수집**
            function collectLoadTriggers(){
                return Array.from(document.querySelectorAll(
                    '.load-more,.show-more,[data-testid*="load"],[class*="load"][class*="more"],[aria-label*="더보기"],[aria-label*="more"]'
                )).slice(0,6).map(b=>({
                    selector: b.id ? '#' + CSS.escape(b.id) : b.tagName.toLowerCase() + (b.className ? '.' + Array.from(b.classList).map(c=>CSS.escape(c)).slice(0,2).join('.') : ''),
                    label: (b.getAttribute('aria-label')||b.innerText||'').trim().slice(0,40)
                }));
            }
            
            // 🖼️ **iframe 스크롤 상태 수집**
            function collectIFrameScrolls(){
                const out=[];
                document.querySelectorAll('iframe').forEach(ifr=>{
                    let cross=false, sx=0, sy=0;
                    try {
                        const cw=ifr.contentWindow, doc=cw.document;
                        const se = doc.scrollingElement || doc.documentElement;
                        sx = se.scrollLeft; sy = se.scrollTop;
                    } catch(e) { cross=true; }
                    
                    const dataAttrs = {};
                    Array.from(ifr.attributes).filter(a=>a.name.startsWith('data-')).forEach(a => dataAttrs[a.name] = a.value);
                    
                    out.push({ 
                        selector: ifr.id ? '#' + CSS.escape(ifr.id) : 'iframe', 
                        crossOrigin: cross, 
                        scrollX: sx, 
                        scrollY: sy, 
                        src: ifr.src||'', 
                        dataAttrs: dataAttrs 
                    });
                });
                return out;
            }
        })()
        """
    }
    
    private func renderWebViewToImage(_ webView: WKWebView) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        return renderer.image { context in
            webView.layer.render(in: context.cgContext)
        }
    }
    
    // MARK: - 🔥 **오버레이 시스템 (완전 무음 공개)**
    
    func overlay_begin(_ webView: WKWebView) {
        guard webView.viewWithTag(998877) == nil else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = webView.bounds
        cfg.afterScreenUpdates = true
        webView.takeSnapshot(with: cfg) { [weak webView] image, _ in
            guard let webView = webView else { return }
            let overlay = UIImageView(frame: webView.bounds)
            overlay.tag = 998877
            overlay.image = image ?? self.renderWebViewToImage(webView)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.isUserInteractionEnabled = false
            overlay.alpha = 1.0
            webView.addSubview(overlay)
            self.dbg("🔥 오버레이 설치 완료")
        }
    }
    
    func overlay_end(_ webView: WKWebView) {
        guard let overlay = webView.viewWithTag(998877) else { return }
        UIView.animate(withDuration: 0.08, delay: 0, options: [.curveEaseOut], animations: {
            overlay.alpha = 0
        }, completion: { _ in 
            overlay.removeFromSuperview()
            self.dbg("🔥 오버레이 제거 완료")
        })
    }
    
    func overlay_forceRemove(_ webView: WKWebView) {
        webView.viewWithTag(998877)?.removeFromSuperview()
        dbg("🔥 오버레이 강제 제거")
    }
    
    // MARK: - 🔥 **스크롤 차단 시스템**
    
    func scrollLock_begin(_ webView: WKWebView) {
        webView.scrollView.isScrollEnabled = false
        // iOS safe area/URL bar 보정: 복원 중 inset 자동 조정 금지
        let sv = webView.scrollView
        objc_setAssociatedObject(webView, "bfcache_prevInsetAdj", sv.contentInsetAdjustmentBehavior, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        sv.contentInsetAdjustmentBehavior = .never
        dbg("🔒 스크롤 잠금 시작")
    }
    
    func scrollLock_end(_ webView: WKWebView) {
        webView.scrollView.isScrollEnabled = true
        if let old = objc_getAssociatedObject(webView, "bfcache_prevInsetAdj") as? UIScrollView.ContentInsetAdjustmentBehavior {
            webView.scrollView.contentInsetAdjustmentBehavior = old
        }
        dbg("🔓 스크롤 잠금 해제")
    }
    
    // MARK: - 🔥 **메시지 브리지 기반 복원 파이프라인**
    
    private var messageBridges: [String: JSMessageBridge] = [:]
    
    func setupMessageBridges(for webView: WKWebView, tabID: UUID) {
        let ucc = webView.configuration.userContentController
        
        // 기존 브리지 제거
        ["bfcache_restore_done", "bfcache_progressive_done", "bfcache_iframe_done"].forEach { channel in
            ucc.removeScriptMessageHandler(forName: channel)
        }
        
        // 새 브리지 설치
        let restoreBridge = JSMessageBridge { [weak self] name, body in
            self?.handleRestoreMessage(name: name, body: body, tabID: tabID)
        }
        
        let progressiveBridge = JSMessageBridge { [weak self] name, body in
            self?.handleProgressiveMessage(name: name, body: body, tabID: tabID)
        }
        
        let iframeBridge = JSMessageBridge { [weak self] name, body in
            self?.handleIFrameMessage(name: name, body: body, tabID: tabID)
        }
        
        ucc.add(restoreBridge, name: "bfcache_restore_done")
        ucc.add(progressiveBridge, name: "bfcache_progressive_done")
        ucc.add(iframeBridge, name: "bfcache_iframe_done")
        
        messageBridges["restore"] = restoreBridge
        messageBridges["progressive"] = progressiveBridge
        messageBridges["iframe"] = iframeBridge
        
        dbg("🔗 메시지 브리지 설치 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    private func handleRestoreMessage(name: String, body: Any?, tabID: UUID) {
        guard let messageDict = body as? [String: Any] else { return }
        
        let success = messageDict["ok"] as? Bool ?? false
        let method = messageDict["method"] as? String ?? "unknown"
        
        dbg("📨 복원 메시지 수신: \(method), 성공: \(success)")
        
        // 상태머신으로 전달
        if let stateMachine = _stateMachines[tabID] {
            stateMachine.handleEvent(.jsMessage(name: name, body: body))
        }
    }
    
    private func handleProgressiveMessage(name: String, body: Any?, tabID: UUID) {
        guard let messageDict = body as? [String: Any] else { return }
        
        let success = messageDict["ok"] as? Bool ?? false
        let cycles = messageDict["cycles"] as? Int ?? 0
        let reason = messageDict["reason"] as? String ?? "unknown"
        
        dbg("📨 버스트 로딩 메시지 수신: \(reason), 사이클: \(cycles)")
        
        // 상태머신으로 전달
        if let stateMachine = _stateMachines[tabID] {
            stateMachine.handleEvent(.jsMessage(name: name, body: body))
        }
    }
    
    private func handleIFrameMessage(name: String, body: Any?, tabID: UUID) {
        guard let messageDict = body as? [String: Any] else { return }
        
        let success = messageDict["ok"] as? Bool ?? false
        let restored = messageDict["restored"] as? Int ?? 0
        
        dbg("📨 iframe 복원 메시지 수신: 복원됨 \(restored)개")
        
        // 상태머신으로 전달
        if let stateMachine = _stateMachines[tabID] {
            stateMachine.handleEvent(.jsMessage(name: name, body: body))
        }
    }
    
    // MARK: - 🔧 **핵심 개선: 원자적 캡처 작업**
    
    func captureSnapshot(pageRecord: PageRecord, webView: WKWebView?, type: CaptureType = .immediate, tabID: UUID? = nil) {
        guard let webView = webView else {
            dbg("❌ 캡처 실패: 웹뷰 없음 - \(pageRecord.title)")
            return
        }
        
        let task = CaptureTask(pageRecord: pageRecord, tabID: tabID, type: type, webView: webView)
        
        dbg("🎯 도메인 특화 캡처 대상: \(pageRecord.url.host ?? "unknown") - \(pageRecord.title)")
        
        // 🔧 **직렬화 큐로 모든 캡처 작업 순서 보장**
        serialQueue.async { [weak self] in
            self?.performAtomicCapture(task)
        }
    }
    
    // MARK: - 💾 **개선된 디스크 저장 시스템**
    
    private func saveToDisk(snapshot: (snapshot: BFCacheSnapshot, image: UIImage?), tabID: UUID) {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            let pageID = snapshot.snapshot.pageRecord.id
            let version = snapshot.snapshot.version
            let pageDir = self.pageDirectory(for: pageID, tabID: tabID, version: version)
            
            // 디렉토리 생성
            self.createDirectoryIfNeeded(at: pageDir)
            
            var finalSnapshot = snapshot.snapshot
            
            // 1. 이미지 저장 (JPEG 압축)
            if let image = snapshot.image {
                let imagePath = pageDir.appendingPathComponent("snapshot.jpg")
                if let jpegData = image.jpegData(compressionQuality: 0.7) {
                    do {
                        try jpegData.write(to: imagePath)
                        finalSnapshot.webViewSnapshotPath = imagePath.path
                        self.dbg("💾 이미지 저장 성공: \(imagePath.lastPathComponent)")
                    } catch {
                        self.dbg("❌ 이미지 저장 실패: \(error.localizedDescription)")
                    }
                }
            }
            
            // 2. 상태 데이터 저장 (JSON)
            let statePath = pageDir.appendingPathComponent("state.json")
            if let stateData = try? JSONEncoder().encode(finalSnapshot) {
                do {
                    try stateData.write(to: statePath)
                    self.dbg("💾 상태 저장 성공: \(statePath.lastPathComponent)")
                } catch {
                    self.dbg("❌상태 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 3. 메타데이터 저장
            let metadata = CacheMetadata(
                pageID: pageID,
                tabID: tabID,
                version: version,
                timestamp: Date(),
                url: snapshot.snapshot.pageRecord.url.absoluteString,
                title: snapshot.snapshot.pageRecord.title
            )
            
            let metadataPath = pageDir.appendingPathComponent("metadata.json")
            if let metadataData = try? JSONEncoder().encode(metadata) {
                do {
                    try metadataData.write(to: metadataPath)
                } catch {
                    self.dbg("❌ 메타데이터 저장 실패: \(error.localizedDescription)")
                }
            }
            
            // 4. 인덱스 업데이트 (원자적)
            self.setDiskIndex(pageDir.path, for: pageID)
            self.setMemoryCache(finalSnapshot, for: pageID)
            
            self.dbg("💾 디스크 저장 완료: \(snapshot.snapshot.pageRecord.title) [v\(version)]")
            
            // 5. 이전 버전 정리 (최신 3개만 유지)
            self.cleanupOldVersions(pageID: pageID, tabID: tabID, currentVersion: version)
        }
    }
    
    private struct CacheMetadata: Codable {
        let pageID: UUID
        let tabID: UUID
        let version: Int
        let timestamp: Date
        let url: String
        let title: String
    }
    
    private func createDirectoryIfNeeded(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    private func cleanupOldVersions(pageID: UUID, tabID: UUID, currentVersion: Int) {
        let tabDir = tabDirectory(for: tabID)
        let pagePrefix = "Page_\(pageID.uuidString)_v"
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil)
            let pageDirs = contents.filter { $0.lastPathComponent.hasPrefix(pagePrefix) }
                .sorted { url1, url2 in
                    // 버전 번호 추출하여 정렬
                    let v1 = Int(url1.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    let v2 = Int(url2.lastPathComponent.replacingOccurrences(of: pagePrefix, with: "")) ?? 0
                    return v1 > v2  // 최신 버전부터
                }
            
            // 최신 3개 제외하고 삭제
            if pageDirs.count > 3 {
                for i in 3..<pageDirs.count {
                    try FileManager.default.removeItem(at: pageDirs[i])
                    dbg("🗑️ 이전 버전 삭제: \(pageDirs[i].lastPathComponent)")
                }
            }
        } catch {
            dbg("⚠️ 이전 버전 정리 실패: \(error)")
        }
    }
    
    // MARK: - 💾 **개선된 디스크 캐시 로딩**
    
    private func loadDiskCacheIndex() {
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            
            // BFCache 디렉토리 생성
            self.createDirectoryIfNeeded(at: self.bfCacheDirectory)
            
            var loadedCount = 0
            
            // 모든 탭 디렉토리 스캔
            do {
                let tabDirs = try FileManager.default.contentsOfDirectory(at: self.bfCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                
                for tabDir in tabDirs {
                    if tabDir.lastPathComponent.hasPrefix("Tab_") {
                        // 각 페이지 디렉토리 스캔
                        let pageDirs = try FileManager.default.contentsOfDirectory(at: tabDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        
                        for pageDir in pageDirs {
                            if pageDir.lastPathComponent.hasPrefix("Page_") {
                                // metadata.json 로드
                                let metadataPath = pageDir.appendingPathComponent("metadata.json")
                                if let data = try? Data(contentsOf: metadataPath),
                                   let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data) {
                                    
                                    // 스레드 안전하게 인덱스 업데이트
                                    self.setDiskIndex(pageDir.path, for: metadata.pageID)
                                    self.cacheAccessQueue.async(flags: .barrier) {
                                        self._cacheVersion[metadata.pageID] = metadata.version
                                    }
                                    loadedCount += 1
                                }
                            }
                        }
                    }
                }
                
                self.dbg("💾 디스크 캐시 인덱스 로드 완료: \(loadedCount)개 항목")
            } catch {
                self.dbg("❌ 디스크 캐시 로드 실패: \(error)")
            }
        }
    }
    
    // MARK: - 🔍 **개선된 스냅샷 조회 시스템**
    
    private func retrieveSnapshot(for pageID: UUID) -> BFCacheSnapshot? {
        // 1. 먼저 메모리 캐시 확인 (스레드 안전)
        if let snapshot = cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) {
            dbg("💭 메모리 캐시 히트: \(snapshot.pageRecord.title)")
            return snapshot
        }
        
        // 2. 디스크 캐시 확인 (스레드 안전)
        if let diskPath = cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) {
            let statePath = URL(fileURLWithPath: diskPath).appendingPathComponent("state.json")
            
            if let data = try? Data(contentsOf: statePath),
               let snapshot = try? JSONDecoder().decode(BFCacheSnapshot.self, from: data) {
                
                // 메모리 캐시에도 저장 (최적화)
                setMemoryCache(snapshot, for: pageID)
                
                dbg("💾 디스크 캐시 히트: \(snapshot.pageRecord.title)")
                return snapshot
            }
        }
        
        dbg("❌ 캐시 미스: \(pageID)")
        return nil
    }
    
    // MARK: - 🔧 **수정: hasCache 메서드 추가**
    func hasCache(for pageID: UUID) -> Bool {
        // 메모리 캐시 체크
        if cacheAccessQueue.sync(execute: { _memoryCache[pageID] }) != nil {
            return true
        }
        
        // 디스크 캐시 인덱스 체크
        if cacheAccessQueue.sync(execute: { _diskCacheIndex[pageID] }) != nil {
            return true
        }
        
        return false
    }
    
    // MARK: - 메모리 캐시 관리
    
    private func storeInMemory(_ snapshot: BFCacheSnapshot, for pageID: UUID) {
        setMemoryCache(snapshot, for: pageID)
        dbg("💭 메모리 캐시 저장: \(snapshot.pageRecord.title) [v\(snapshot.version)]")
    }
    
    // MARK: - 🧹 **개선된 캐시 정리**
    
    func clearCacheForTab(_ tabID: UUID, pageIDs: [UUID]) {
        // 🧵 제스처 컨텍스트 정리
        removeGestureContext(for: tabID)
        removeActiveTransition(for: tabID)
        
        // 🔥 네비게이션 델리게이트 정리
        _navigationDelegates.removeValue(forKey: tabID)
        
        // 🔥 상태머신 정리
        _stateMachines.removeValue(forKey: tabID)
        
        // 메모리에서 제거 (스레드 안전)
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            for pageID in pageIDs {
                self._memoryCache.removeValue(forKey: pageID)
                self._diskCacheIndex.removeValue(forKey: pageID)
                self._cacheVersion.removeValue(forKey: pageID)
            }
        }
        
        // 디스크에서 제거
        diskIOQueue.async { [weak self] in
            guard let self = self else { return }
            let tabDir = self.tabDirectory(for: tabID)
            do {
                try FileManager.default.removeItem(at: tabDir)
                self.dbg("🗑️ 탭 캐시 완전 삭제: \(tabID.uuidString)")
            } catch {
                self.dbg("⚠️ 탭 캐시 삭제 실패: \(error)")
            }
        }
    }
    
    // 메모리 경고 처리 (메모리 캐시만 일부 정리)
    private func setupMemoryWarningObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }
    
    private func handleMemoryWarning() {
        cacheAccessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let beforeCount = self._memoryCache.count
            
            // 메모리 캐시의 절반 정리 (오래된 것부터)
            let sorted = self._memoryCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let removeCount = sorted.count / 2
            
            sorted.prefix(removeCount).forEach { item in
                self._memoryCache.removeValue(forKey: item.key)
            }
            
            self.dbg("⚠️ 메모리 경고 - 메모리 캐시 정리: \(beforeCount) → \(self._memoryCache.count)")
        }
    }
    
    // MARK: - 🧵 **리팩토링된 제스처 시스템 (먹통 방지)**
    
    func setupGestures(for webView: WKWebView, stateModel: WebViewStateModel) {
        // 네이티브 제스처 비활성화
        webView.allowsBackForwardNavigationGestures = false
        
        guard let tabID = stateModel.tabID else {
            dbg("🧵 탭 ID 없음 - 제스처 설정 스킵")
            return
        }
        
        // 🧵 **기존 제스처 정리 (중복 방지)**
        cleanupExistingGestures(for: webView, tabID: tabID)
        
        // 🧵 **새로운 제스처 컨텍스트 생성**
        let gestureContext = GestureContext(tabID: tabID, webView: webView, stateModel: stateModel)
        setGestureContext(gestureContext, for: tabID)
        
        // 🧵 **메인 스레드에서 제스처 생성 및 설정**
        DispatchQueue.main.async { [weak self] in
            self?.createAndAttachGestures(webView: webView, tabID: tabID)
        }
        
        // 📸 **메시지 브리지 설치**
        setupMessageBridges(for: webView, tabID: tabID)
        
        dbg("🔥 완전 무음 복원 BFCache 제스처 설정 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **기존 제스처 정리**
    private func cleanupExistingGestures(for webView: WKWebView, tabID: UUID) {
        // 기존 제스처 컨텍스트 무효화
        removeGestureContext(for: tabID)
        
        // 웹뷰에서 기존 BFCache 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if let edgeGesture = gesture as? UIScreenEdgePanGestureRecognizer,
               edgeGesture.edges == .left || edgeGesture.edges == .right {
                webView.removeGestureRecognizer(gesture)
                dbg("🧵 기존 제스처 제거: \(edgeGesture.edges)")
            }
        }
    }
    
    // 🧵 **제스처 생성 및 연결**
    private func createAndAttachGestures(webView: WKWebView, tabID: UUID) {
        // 왼쪽 엣지 - 뒤로가기
        let leftEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        leftEdge.edges = .left
        leftEdge.delegate = self
        
        // 오른쪽 엣지 - 앞으로가기  
        let rightEdge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        rightEdge.edges = .right
        rightEdge.delegate = self
        
        // 🧵 **제스처에 탭 ID 연결 (컨텍스트 검색용)**
        objc_setAssociatedObject(leftEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(rightEdge, "bfcache_tab_id", tabID.uuidString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        webView.addGestureRecognizer(leftEdge)
        webView.addGestureRecognizer(rightEdge)
        
        dbg("🧵 제스처 연결 완료: 탭 \(String(tabID.uuidString.prefix(8)))")
    }
    
    // 🧵 **리팩토링된 제스처 핸들러 (메인 스레드 최적화)**
    @objc private func handleGesture(_ gesture: UIScreenEdgePanGestureRecognizer) {
        // 🧵 **메인 스레드 확인 및 강제 이동**
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleGesture(gesture)
            }
            return
        }
        
        // 🧵 **제스처에서 탭 ID 조회**
        guard let tabIDString = objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String,
              let tabID = UUID(uuidString: tabIDString) else {
            dbg("🧵 제스처에서 탭 ID 조회 실패")
            gesture.state = .cancelled
            return
        }
        
        // 🧵 **컨텍스트 유효성 검사 및 조회**
        guard let context = getGestureContext(for: tabID) else {
            dbg("🧵 제스처 컨텍스트 없음 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
            gesture.state = .cancelled
            return
        }
        
        // 🧵 **컨텍스트 내에서 안전하게 실행**
        context.validateAndExecute { [weak self] in
            guard let self = self,
                  let webView = context.webView,
                  let stateModel = context.stateModel else {
                TabPersistenceManager.debugMessages.append("🧵 컨텍스트 무효 - 제스처 취소: \(String(tabID.uuidString.prefix(8)))")
                gesture.state = .cancelled
                return
            }
            
            self.processGestureState(
                gesture: gesture,
                tabID: tabID,
                webView: webView,
                stateModel: stateModel
            )
        }
    }
    
    // 🧵 **제스처 상태 처리 (기존 로직 유지)**
    private func processGestureState(gesture: UIScreenEdgePanGestureRecognizer, tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel) {
        let translation = gesture.translation(in: gesture.view)
        let velocity = gesture.velocity(in: gesture.view)
        let isLeftEdge = (gesture.edges == .left)
        let width = gesture.view?.bounds.width ?? 1
        
        // 수직 슬롭/부호 반대 방지
        let absX = abs(translation.x), absY = abs(translation.y)
        let horizontalEnough = absX > 8 && absX > absY
        let signOK = isLeftEdge ? (translation.x >= 0) : (translation.x <= 0)
        
        switch gesture.state {
        case .began:
            // 🛡️ **전환 중이면 새 제스처 무시**
            guard getActiveTransition(for: tabID) == nil else { 
                dbg("🛡️ 전환 중 - 새 제스처 무시")
                gesture.state = .cancelled
                return 
            }
            
            let direction: NavigationDirection = isLeftEdge ? .back : .forward
            let canNavigate = isLeftEdge ? stateModel.canGoBack : stateModel.canGoForward
            
            if canNavigate {
                // 현재 페이지 즉시 캡처 (높은 우선순위)
                if let currentRecord = stateModel.dataModel.currentPageRecord {
                    captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
                }
                
                // 현재 웹뷰 스냅샷을 먼저 캡처한 후 전환 시작
                captureCurrentSnapshot(webView: webView) { [weak self] snapshot in
                    DispatchQueue.main.async {
                        self?.beginGestureTransitionWithSnapshot(
                            tabID: tabID,
                            webView: webView,
                            stateModel: stateModel,
                            direction: direction,
                            currentSnapshot: snapshot
                        )
                    }
                }
            } else {
                gesture.state = .cancelled
            }
            
        case .changed:
            guard horizontalEnough && signOK else { return }
            updateGestureProgress(tabID: tabID, translation: translation.x, isLeftEdge: isLeftEdge)
            
        case .ended:
            let progress = min(1.0, absX / width)
            let shouldComplete = progress > 0.3 || abs(velocity.x) > 800
            if shouldComplete {
                completeGestureTransition(tabID: tabID)
            } else {
                cancelGestureTransition(tabID: tabID)
            }
            
        case .cancelled, .failed:
            cancelGestureTransition(tabID: tabID)
            
        default:
            break
        }
    }
    
    private func captureCurrentSnapshot(webView: WKWebView, completion: @escaping (UIImage?) -> Void) {
        let captureConfig = WKSnapshotConfiguration()
        captureConfig.rect = webView.bounds
        captureConfig.afterScreenUpdates = false
        
        webView.takeSnapshot(with: captureConfig) { image, error in
            if let error = error {
                self.dbg("📸 현재 페이지 스냅샷 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let fallbackImage = self.renderWebViewToImage(webView)
                    completion(fallbackImage)
                }
            } else {
                completion(image)
            }
        }
    }
    
    private func beginGestureTransitionWithSnapshot(tabID: UUID, webView: WKWebView, stateModel: WebViewStateModel, direction: NavigationDirection, currentSnapshot: UIImage?) {
        let initialTransform = webView.transform
        
        let previewContainer = createPreviewContainer(
            webView: webView,
            direction: direction,
            stateModel: stateModel,
            currentSnapshot: currentSnapshot
        )
        
        let context = TransitionContext(
            tabID: tabID,
            webView: webView,
            stateModel: stateModel,
            isGesture: true,
            direction: direction,
            initialTransform: initialTransform,
            previewContainer: previewContainer,
            currentSnapshot: currentSnapshot
        )
        setActiveTransition(context, for: tabID)
        
        dbg("🎬 직접 전환 시작: \(direction == .back ? "뒤로가기" : "앞으로가기")")
    }
    
    private func updateGestureProgress(tabID: UUID, translation: CGFloat, isLeftEdge: Bool) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentWebView = previewContainer.viewWithTag(1001)
        let targetPreview = previewContainer.viewWithTag(1002)
        
        if isLeftEdge {
            let moveDistance = max(0, min(screenWidth, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = -screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (moveDistance / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        } else {
            let moveDistance = max(-screenWidth, min(0, translation))
            currentWebView?.frame.origin.x = moveDistance
            targetPreview?.frame.origin.x = screenWidth + moveDistance
            
            let shadowOpacity = Float(0.3 * (abs(moveDistance) / screenWidth))
            currentWebView?.layer.shadowOpacity = shadowOpacity
        }
    }
    
    private func createPreviewContainer(webView: WKWebView, direction: NavigationDirection, stateModel: WebViewStateModel, currentSnapshot: UIImage? = nil) -> UIView {
        let container = UIView(frame: webView.bounds)
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        
        // 현재 웹뷰 스냅샷 사용
        let currentView: UIView
        if let snapshot = currentSnapshot {
            let imageView = UIImageView(image: snapshot)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            currentView = imageView
        } else {
            if let fallbackImage = renderWebViewToImage(webView) {
                let imageView = UIImageView(image: fallbackImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                currentView = imageView
            } else {
                currentView = UIView(frame: webView.bounds)
                currentView.backgroundColor = .systemBackground
            }
        }
        
        currentView.frame = webView.bounds
        currentView.tag = 1001
        
        // 그림자 설정
        currentView.layer.shadowColor = UIColor.black.cgColor
        currentView.layer.shadowOpacity = 0.3
        currentView.layer.shadowOffset = CGSize(width: direction == .back ? -5 : 5, height: 0)
        currentView.layer.shadowRadius = 10
        
        container.addSubview(currentView)
        
        // 타겟 페이지 미리보기
        let targetIndex = direction == .back ?
            stateModel.dataModel.currentPageIndex - 1 :
            stateModel.dataModel.currentPageIndex + 1
        
        var targetView: UIView
        
        if targetIndex >= 0, targetIndex < stateModel.dataModel.pageHistory.count {
            let targetRecord = stateModel.dataModel.pageHistory[targetIndex]
            
            if let snapshot = retrieveSnapshot(for: targetRecord.id),
               let targetImage = snapshot.loadImage() {
                let imageView = UIImageView(image: targetImage)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                targetView = imageView
                dbg("📸 타겟 페이지 BFCache 스냅샷 사용: \(targetRecord.title)")
            } else {
                targetView = createInfoCard(for: targetRecord, in: webView.bounds)
                dbg("ℹ️ 타겟 페이지 정보 카드 생성: \(targetRecord.title)")
            }
        } else {
            targetView = UIView()
            targetView.backgroundColor = .systemBackground
        }
        
        targetView.frame = webView.bounds
        targetView.tag = 1002
        
        if direction == .back {
            targetView.frame.origin.x = -webView.bounds.width
        } else {
            targetView.frame.origin.x = webView.bounds.width
        }
        
        container.insertSubview(targetView, at: 0)
        webView.addSubview(container)
        return container
    }
    
    private func createInfoCard(for record: PageRecord, in bounds: CGRect) -> UIView {
        let card = UIView(frame: bounds)
        card.backgroundColor = .systemBackground
        
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 12
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0.1
        contentView.layer.shadowOffset = CGSize(width: 0, height: 2)
        contentView.layer.shadowRadius = 8
        card.addSubview(contentView)
        
        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "globe")
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        contentView.addSubview(iconView)
        
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = record.title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        contentView.addSubview(titleLabel)
        
        let urlLabel = UILabel()
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.text = record.url.host ?? record.url.absoluteString
        urlLabel.font = .systemFont(ofSize: 14)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 1
        contentView.addSubview(urlLabel)
        
        let timeLabel = UILabel()
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        timeLabel.text = formatter.string(from: record.lastAccessed)
        timeLabel.font = .systemFont(ofSize: 12)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.textAlignment = .center
        contentView.addSubview(timeLabel)
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: min(300, bounds.width - 60)),
            contentView.heightAnchor.constraint(equalToConstant: 180),
            
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),
            
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            urlLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            
            timeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            timeLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
        
        return card
    }
    
    // 🔥 **완전 무음 복원을 적용한 제스처 완료**
    private func completeGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                if context.direction == .back {
                    currentView?.frame.origin.x = screenWidth
                    targetView?.frame.origin.x = 0
                } else {
                    currentView?.frame.origin.x = -screenWidth
                    targetView?.frame.origin.x = 0
                }
                currentView?.layer.shadowOpacity = 0
            },
            completion: { [weak self] _ in
                // 🔥 **완전 무음 복원 시스템으로 네비게이션 수행**
                self?.performNavigationWithSilentRestore(context: context, previewContainer: previewContainer)
            }
        )
    }
    
    // 🔥 **완전 무음 복원 시스템을 적용한 네비게이션 수행**
    private func performNavigationWithSilentRestore(context: TransitionContext, previewContainer: UIView) {
        guard let stateModel = context.stateModel,
              let webView = context.webView else {
            // 실패 시 즉시 정리
            previewContainer.removeFromSuperview()
            removeActiveTransition(for: context.tabID)
            return
        }
        
        // 네비게이션 먼저 수행
        switch context.direction {
        case .back:
            stateModel.goBack()
            dbg("🔥 완전 무음 뒤로가기 완료")
        case .forward:
            stateModel.goForward()
            dbg("🔥 완전 무음 앞으로가기 완료")
        }
        
        // 🔥 **완전 무음 BFCache 복원**
        trySilentBFCacheRestore(stateModel: stateModel, webView: webView, tabID: context.tabID) { [weak self] success in
            // BFCache 복원 완료 시 정리
            DispatchQueue.main.async {
                previewContainer.removeFromSuperview()
                self?.removeActiveTransition(for: context.tabID)
                
                self?.dbg("🔥 미리보기 정리 완료 - 완전 무음 BFCache \(success ? "성공" : "실패")")
            }
        }
    }
    
    // 🔥 **완전 무음 BFCache 복원** 
    private func trySilentBFCacheRestore(stateModel: WebViewStateModel, webView: WKWebView, tabID: UUID, completion: @escaping (Bool) -> Void) {
        guard let currentRecord = stateModel.dataModel.currentPageRecord else {
            completion(false)
            return
        }
        
        // BFCache에서 스냅샷 가져오기
        if let snapshot = retrieveSnapshot(for: currentRecord.id) {
            // BFCache 히트 - 완전 무음 복원
            let stateMachine = RestoreStateMachine(webView: webView, system: self)
            _stateMachines[tabID] = stateMachine
            
            stateMachine.startRestore(snapshot: snapshot) { [weak self] success in
                self?._stateMachines.removeValue(forKey: tabID)
                completion(success)
                if success {
                    self?.dbg("🔥 완전 무음 BFCache 복원 성공: \(currentRecord.title)")
                } else {
                    self?.dbg("⚠️ 완전 무음 BFCache 복원 실패: \(currentRecord.title)")
                }
            }
        } else {
            // BFCache 미스 - 기존 대기
            dbg("❌ BFCache 미스: \(currentRecord.title)")
            
            // 기존 대기 시간 (250ms)
            let waitTime: TimeInterval = 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTime) {
                completion(false)
            }
        }
    }

    private func cancelGestureTransition(tabID: UUID) {
        guard let context = getActiveTransition(for: tabID),
              let webView = context.webView,
              let previewContainer = context.previewContainer else { return }
        
        let screenWidth = webView.bounds.width
        let currentView = previewContainer.viewWithTag(1001)
        let targetView = previewContainer.viewWithTag(1002)
        
        UIView.animate(
            withDuration: 0.25,
            animations: {
                currentView?.frame.origin.x = 0
                
                if context.direction == .back {
                    targetView?.frame.origin.x = -screenWidth
                } else {
                    targetView?.frame.origin.x = screenWidth
                }
                
                currentView?.layer.shadowOpacity = 0.3
            },
            completion: { _ in
                previewContainer.removeFromSuperview()
                self.removeActiveTransition(for: context.tabID)
            }
        )
    }
    
    // MARK: - 버튼 네비게이션 (즉시 전환)
    
    func navigateBack(stateModel: WebViewStateModel) {
        guard stateModel.canGoBack,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goBack()
        trySilentBFCacheRestore(stateModel: stateModel, webView: webView, tabID: tabID) { [weak self] success in
            self?.dbg("🔥 버튼 뒤로가기 완료: \(success ? "성공" : "실패")")
        }
    }
    
    func navigateForward(stateModel: WebViewStateModel) {
        guard stateModel.canGoForward,
              let tabID = stateModel.tabID,
              let webView = stateModel.webView else { return }
        
        // 현재 페이지 즉시 캡처 (높은 우선순위)
        if let currentRecord = stateModel.dataModel.currentPageRecord {
            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .immediate, tabID: tabID)
        }
        
        stateModel.goForward()
        trySilentBFCacheRestore(stateModel: stateModel, webView: webView, tabID: tabID) { [weak self] success in
            self?.dbg("🔥 버튼 앞으로가기 완료: \(success ? "성공" : "실패")")
        }
    }
    
    // MARK: - 🔥 **봉인 해제 JavaScript 스크립트**
    
    static func makeGuardReleaseScript() -> WKUserScript {
        let js = """
        (function(){
            try {
                // 프리페인트 가드 해제
                window.__restore_hold_flag__ = false;
                document.documentElement.classList.remove('__restore_hold','__noanchor');
                
                // 봉인된 함수들 복구
                // (이미 기본 함수들로 복구되어 있음)
                
                // 스타일 제거
                var s = document.querySelector('style[data-restore-style="true"]');
                if (s && s.parentNode) s.parentNode.removeChild(s);
                
                console.log('🛡️ 모든 가드 해제 완료');
            } catch(e) {
                console.error('가드 해제 실패:', e);
            }
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }
    
    // MARK: - 🌐 **BFCache JavaScript 스크립트 (기존 유지)**
    
    static func makeBFCacheScript() -> WKUserScript {
        let scriptSource = """
        window.addEventListener('pageshow', function(event) {
            if (event.persisted) {
                console.log('🔥 완전 무음 복원 BFCache 페이지 복원');
                
                // 🌐 동적 콘텐츠 새로고침 (필요시)
                if (window.location.pathname.includes('/feed') ||
                    window.location.pathname.includes('/timeline') ||
                    window.location.hostname.includes('twitter') ||
                    window.location.hostname.includes('facebook') ||
                    window.location.hostname.includes('dcinside') ||
                    window.location.hostname.includes('cafe.naver')) {
                    if (window.refreshDynamicContent) {
                        window.refreshDynamicContent();
                    }
                }
            }
        });
        
        window.addEventListener('pagehide', function(event) {
            if (event.persisted) {
                console.log('📸 완전 무음 복원 BFCache 페이지 저장');
            }
        });
        
        // 🔥 Cross-origin iframe 완전 무음 복원 스크롤 복원 리스너
        window.addEventListener('message', function(event) {
            if (event.data && event.data.type === 'restoreScroll') {
                try {
                    const targetX = parseFloat(event.data.scrollX) || 0;
                    const targetY = parseFloat(event.data.scrollY) || 0;
                    const silentRestore = event.data.silentRestore || false;
                    
                    console.log('🔥 Cross-origin iframe 완전 무음 복원 스크롤 복원:', targetX, targetY, silentRestore ? '(완전 무음 복원 모드)' : '');
                    
                    if (silentRestore) {
                        // 🔥 완전 무음 복원 모드
                        // 스크롤 이벤트 차단
                        let scrollBlocked = true;
                        const blockScrollEvents = (e) => {
                            if (scrollBlocked) {
                                e.preventDefault();
                                e.stopPropagation();
                                return false;
                            }
                        };
                        
                        document.addEventListener('scroll', blockScrollEvents, { capture: true, passive: false });
                        window.addEventListener('scroll', blockScrollEvents, { capture: true, passive: false });
                        
                        // requestAnimationFrame으로 한 번에 스크롤
                        requestAnimationFrame(() => {
                            const se = document.scrollingElement || document.documentElement;
                            se.scrollTo({left: targetX, top: targetY, behavior: 'auto'});
                            
                            // 스크롤 이벤트 차단 해제
                            setTimeout(() => {
                                scrollBlocked = false;
                                document.removeEventListener('scroll', blockScrollEvents, { capture: true });
                                window.removeEventListener('scroll', blockScrollEvents, { capture: true });
                            }, 100);
                        });
                    } else {
                        // 기본 스크롤
                        const se = document.scrollingElement || document.documentElement;
                        se.scrollTo({left: targetX, top: targetY, behavior: 'auto'});
                    }
                    
                } catch(e) {
                    console.error('Cross-origin iframe 스크롤 복원 실패:', e);
                }
            }
        });
        """
        return WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
    
    // MARK: - 스와이프 제스처 감지 처리 (DataModel에서 이관)
    
    static func handleSwipeGestureDetected(to url: URL, stateModel: WebViewStateModel) {
        // 복원 중이면 무시
        if stateModel.dataModel.isHistoryNavigationActive() {
            TabPersistenceManager.debugMessages.append("🤫 복원 중 스와이프 무시: \(url.absoluteString)")
            return
        }
        
        // 절대 원칙: 히스토리에서 찾더라도 무조건 새 페이지로 추가
        // 세션 점프 완전 방지
        stateModel.dataModel.addNewPage(url: url, title: "")
        stateModel.syncCurrentURL(url)
        TabPersistenceManager.debugMessages.append("👆 스와이프 - 새 페이지로 추가 (과거 점프 방지): \(url.absoluteString)")
    }
    
    // MARK: - 디버그
    
    func dbg(_ msg: String) {
        TabPersistenceManager.debugMessages.append("[BFCache🔥] \(msg)")
    }
}

// MARK: - UIGestureRecognizerDelegate
extension BFCacheTransitionSystem: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - CustomWebView 통합 인터페이스
extension BFCacheTransitionSystem {
    
    // CustomWebView의 makeUIView에서 호출
    static func install(on webView: WKWebView, stateModel: WebViewStateModel) {
        // 🔥 **프리페인트 가드 스크립트 설치 (최우선)**
        webView.configuration.userContentController.addUserScript(makePrepaintGuardScript())
        
        // BFCache 스크립트 설치
        webView.configuration.userContentController.addUserScript(makeBFCacheScript())
        
        // 가드 해제 스크립트 설치 (문서 끝에서)
        webView.configuration.userContentController.addUserScript(makeGuardReleaseScript())
        
        // 🔥 **네비게이션 델리게이트 교체**
        guard let tabID = stateModel.tabID else {
            TabPersistenceManager.debugMessages.append("❌ 탭 ID 없음 - BFCache 델리게이트 설치 스킵")
            return
        }
        
        let bfcacheDelegate = BFCacheNavigationDelegate(
            system: shared,
            stateModel: stateModel,
            dataModel: stateModel.dataModel
        )
        
        shared._navigationDelegates[tabID] = bfcacheDelegate
        webView.navigationDelegate = bfcacheDelegate
        
        // 제스처 설치 + 메시지 브리지
        shared.setupGestures(for: webView, stateModel: stateModel)
        
        TabPersistenceManager.debugMessages.append("✅ 🔥 완전 무음 복원 BFCache 시스템 설치 완료")
    }
    
    // CustomWebView의 dismantleUIView에서 호출
    static func uninstall(from webView: WKWebView) {
        // 🧵 제스처 해제
        if let tabIDString = webView.gestureRecognizers?.compactMap({ gesture in
            objc_getAssociatedObject(gesture, "bfcache_tab_id") as? String
        }).first, let tabID = UUID(uuidString: tabIDString) {
            shared.removeGestureContext(for: tabID)
            shared.removeActiveTransition(for: tabID)
            
            // 🔥 네비게이션 델리게이트 제거
            shared._navigationDelegates.removeValue(forKey: tabID)
            
            // 🔥 상태머신 제거
            shared._stateMachines.removeValue(forKey: tabID)
        }
        
        // 제스처 제거
        webView.gestureRecognizers?.forEach { gesture in
            if gesture is UIScreenEdgePanGestureRecognizer {
                webView.removeGestureRecognizer(gesture)
            }
        }
        
        // 메시지 핸들러 제거
        ["bfcache_restore_done", "bfcache_progressive_done", "bfcache_iframe_done"].forEach { channel in
            webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
        }
        
        // 오버레이 강제 제거
        shared.overlay_forceRemove(webView)
        
        TabPersistenceManager.debugMessages.append("🔥 완전 무음 복원 BFCache 시스템 제거 완료")
    }
    
    // 버튼 네비게이션 래퍼
    static func goBack(stateModel: WebViewStateModel) {
        shared.navigateBack(stateModel: stateModel)
    }
    
    static func goForward(stateModel: WebViewStateModel) {
        shared.navigateForward(stateModel: stateModel)
    }
}

// MARK: - 퍼블릭 래퍼: WebViewDataModel 델리게이트에서 호출
extension BFCacheTransitionSystem {

    /// 사용자가 링크/폼으로 **떠나기 직전** 현재 페이지를 저장
    func storeLeavingSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 즉시 캡처 (최고 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .immediate, tabID: tabID)
        dbg("📸 떠나기 스냅샷 캡처 시작: \(rec.title)")
    }

    /// 📸 **페이지 로드 완료 후 자동 캐시 강화 - 🚀 도착 스냅샷 최적화**
    func storeArrivalSnapshotIfPossible(webView: WKWebView, stateModel: WebViewStateModel) {
        guard let rec = stateModel.dataModel.currentPageRecord,
              let tabID = stateModel.tabID else { return }
        
        // 현재 페이지 캡처 (백그라운드 우선순위)
        captureSnapshot(pageRecord: rec, webView: webView, type: .background, tabID: tabID)
        dbg("📸 도착 스냅샷 캡처 시작: \(rec.title)")
        
        // 이전 페이지들도 순차적으로 캐시 확인 및 캡처
        if stateModel.dataModel.currentPageIndex > 0 {
            // 최근 3개 페이지만 체크 (성능 고려)
            let checkCount = min(3, stateModel.dataModel.currentPageIndex)
            let startIndex = max(0, stateModel.dataModel.currentPageIndex - checkCount)
            
            for i in startIndex..<stateModel.dataModel.currentPageIndex {
                let previousRecord = stateModel.dataModel.pageHistory[i]
                
                // 캐시가 없는 경우만 메타데이터 저장
                if !hasCache(for: previousRecord.id) {
                    // 메타데이터만 저장 (이미지는 없음)
                    let metadataSnapshot = BFCacheSnapshot(
                        pageRecord: previousRecord,
                        scrollPosition: .zero,
                        timestamp: Date(),
                        captureStatus: .failed,
                        version: 1
                    )
                    
                    // 디스크에 메타데이터만 저장
                    saveToDisk(snapshot: (metadataSnapshot, nil), tabID: tabID)
                    dbg("📸 이전 페이지 메타데이터 저장: '\(previousRecord.title)' [인덱스: \(i)]")
                }
            }
        }
    }
}
