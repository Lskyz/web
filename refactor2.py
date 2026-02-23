import re

with open(r'web\web\BFCache UI.swift', 'r', encoding='utf-8') as f:
    ui = f.read()

old_nav_back = chr(10).join([
    '    func navigateBack(stateModel: WebViewStateModel) {',
    '        guard stateModel.canGoBack,',
    '              let tabID = stateModel.tabID,',
    '              let webView = stateModel.webView else { return }',
    '        ',
    '        if let currentRecord = stateModel.dataModel.currentPageRecord {',
    '            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .forceUpdate, tabID: tabID)',
    '        }',
    '        ',
    '        stateModel.goBack()',
    '        tryBrowserBlockingBFCacheRestore(stateModel: stateModel, direction: .back) { _ in }',
    '    }',
])

new_nav_back = chr(10).join([
    '    func navigateBack(stateModel: WebViewStateModel) {',
    '        guard stateModel.canGoBack,',
    '              let webView = stateModel.webView else { return }',
    '        stateModel.goBack()',
    '        tryBrowserBlockingBFCacheRestore(stateModel: stateModel, direction: .back) { _ in }',
    '    }',
])

old_nav_fwd = chr(10).join([
    '    func navigateForward(stateModel: WebViewStateModel) {',
    '        guard stateModel.canGoForward,',
    '              let tabID = stateModel.tabID,',
    '              let webView = stateModel.webView else { return }',
    '        ',
    '        if let currentRecord = stateModel.dataModel.currentPageRecord {',
    '            captureSnapshot(pageRecord: currentRecord, webView: webView, type: .forceUpdate, tabID: tabID)',
    '        }',
    '        ',
    '        stateModel.goForward()',
    '        tryBrowserBlockingBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in }',
    '    }',
])

new_nav_fwd = chr(10).join([
    '    func navigateForward(stateModel: WebViewStateModel) {',
    '        guard stateModel.canGoForward,',
    '              let webView = stateModel.webView else { return }',
    '        stateModel.goForward()',
    '        tryBrowserBlockingBFCacheRestore(stateModel: stateModel, direction: .forward) { _ in }',
    '    }',
])

ui = ui.replace(old_nav_back, new_nav_back)
ui = ui.replace(old_nav_fwd, new_nav_fwd)

ui = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🧵 제스치 콘텍스트 생성[^"]*"\)', '', ui)
ui = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🧵 무효한 콘텍스트[^"]*"\)', '', ui)
ui = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🧵 제스치 콘텍스트 무효화[^"]*"\)', '', ui)
ui = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🧵 제스치 콘텍스트 해제[^"]*"\)', '', ui)
ui = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ 통합 앙커 BFCache 시스템 설치 완료[^"]*"\)', '', ui)
ui = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🚫 BFCache 시스템 제거 완료[^"]*"\)', '', ui)
ui = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("👆 스와이프[^"]*"\)', '', ui)

with open(r'web\web\BFCache UI.swift', 'w', encoding='utf-8') as f:
    f.write(ui)
print("BFCache UI.swift done")

# BFCacheSwipeTransition.swift
with open(r'web\web\BFCacheSwipeTransition.swift', 'r', encoding='utf-8') as f:
    sw = f.read()

sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📊 복원 대상:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📊 목표 위치:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📊 목표 백분율:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📊 저장 콘텐츠 높이:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("⏱️ 전체 복원 소요 시간:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] 페이지 안정화 대기 중[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] JavaScript 생성 완료:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] 현재 높이:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] 저장 시점 높이:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] 복원된 높이:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] 복원률:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] 정적 사이트[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] JSON 파싱 실패[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] Error Domain:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] Error Code:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] JS Exception[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] JS Stack[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] JS Source[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📦 [Step 1] Full userInfo:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📏 [Step 2] 목표 백분율:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📏 [Step 2] 계산된 위치:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📏 [Step 2] 실제 위치:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📏 [Step 2] 위치 차이:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📏 [Step 2] ✅ 상대좌표 복원 성공[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🔍 [Step 3] 사용 가능한 앙커:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🔍 [Step 3] 매칭된 앙커 타입:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🔍 [Step 3] 매칭 방법:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🔍 [Step 3] 매칭 신뢰도:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🔍 [Step 3] 복원된 위치:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🔍 [Step 3] 목표와의 차이:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ [Step 4] 최종 위치:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ [Step 4] 목표 위치:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ [Step 4] 최종 차이:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ [Step 4] 허용 오차[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ [Step 4] 미세 볳정[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🔓 복원 완료[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📊 캐포 완료:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📊 스크롤 계산 정보:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📸 캐치 시도:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🌐 DOM 캐치 시작[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🌐 DOM 캐치 성공:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🚀 JS 앙커 캐치 시작[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ JS 앙커 캐치 성공[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("⚡ 부분 캐포 성공:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🚀 캐치 대상:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🚀 캐치 시작:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("⚠️ 웹븷 준비 안됨:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🚀 앙커:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📊 앙커 통계:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ 캐치 완료:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("⏳ 재시도[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🔄 재시도 성공:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📸 스냅샷 성공[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("💭 메모리 캐시 히트[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("💾 더 최신 버전 발견:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("💾 디스크 캐시 히트[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("💾 이미지 저장 성공[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("💾 상태 저장 성공[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("💾 디스크 저장 완료:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🗑️ 이전 버전 삭제:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🗑️ 탭 캐시 삭제[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("💾 디스크 캐시 로드 완료:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("💭 메모리 캐시 저장[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📸 도착 스냅샷 캐포[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📸 떠나기 스냅샷 캐포[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📸 BFCache 스냅샷 사용[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("ℹ️ 정보 카드 생성[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🎬 전환 시작:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📸 네비게이션 감지 등록:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📸 네비게이션 감지 해제 완료[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("📸 URL 변경 감지[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("⚠️ 메모리 경고[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🎯 통합 앙커 BFCache 제스치 설정 완료[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("⬅️ 뒤로가기 완료[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("➡️ 앞으로가기 완료[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("🎬 BFCache 복원[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("✅ BFCache 복원 성공[^"]*"\)', '', sw)
sw = re.sub(r'
\s*TabPersistenceManager\.debugMessages\.append\("⚠️ BFCache 복원 실패[^"]*"\)', '', sw)
sw = re.sub(r'
\s*self\.dbg\("\U0001F4F8 \uC2A4\uB0C5\uC0F7 \uC2E4\uD328:[^"]*"\)', '', sw)
sw = re.sub(r'
\s*self\.dbg\("[^"]*"\)', '', sw)

with open(r'web\web\BFCacheSwipeTransition.swift', 'w', encoding='utf-8') as f:
    f.write(sw)
print("BFCacheSwipeTransition.swift done")
