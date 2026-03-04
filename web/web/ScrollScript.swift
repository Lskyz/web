import WebKit

// MARK: - 스크롤 보호 스크립트 (SPA 네비게이션 중 scroll-to-top 방지)
extension WebViewDataModel {

    static func makeScrollProtectionScript() -> WKUserScript {
        let source = """
        (function() {
            'use strict';

            // scrollRestoration 고정: WebKit BFCache가 자동 복원하도록
            try {
                Object.defineProperty(history, 'scrollRestoration', {
                    get: () => 'auto',
                    set: () => {},
                    configurable: true
                });
            } catch (e) {}

            const TOP_Y_THRESHOLD = 2;
            const PROTECT_TRIGGER_Y = 50;
            const PROTECT_MS = 260;

            let protectUntil = 0;
            let protectStartY = 0;
            let protectBlockCount = 0;
            let pendingRestoreY = 0;
            let pendingRestoreUntil = 0;
            let restoreTaskActive = false;
            let isInternalRestoreApply = false;
            let pendingRestoreElement = null;
            let pendingRestoreElementY = 0;
            let lastActiveScrollableElement = null;
            let lastActiveScrollableY = 0;
            let lastActiveScrollableAt = 0;

            function currentScrollY() {
                return window.pageYOffset || document.documentElement.scrollTop || document.body.scrollTop || 0;
            }

            function toFiniteNumber(v) {
                const n = Number(v);
                return Number.isFinite(n) ? n : null;
            }

            function parseTargetY(args) {
                if (!args || args.length === 0) return null;
                if (typeof args[0] === 'object' && args[0] !== null) return toFiniteNumber(args[0].top);
                return toFiniteNumber(args[1]);
            }

            function isRootScroller(el) {
                return el === document.scrollingElement || el === document.documentElement || el === document.body;
            }

            function isScrollableElement(el) {
                if (!el || !(el instanceof Element)) return false;
                return ((el.scrollHeight || 0) - (el.clientHeight || 0)) > 40;
            }

            function getElementScrollY(el) {
                if (!el || !(el instanceof Element)) return 0;
                return toFiniteNumber(el.scrollTop) || 0;
            }

            function startProtect(triggerY, sourceEl) {
                const y = Number.isFinite(triggerY) ? triggerY : currentScrollY();
                protectStartY = Math.max(currentScrollY(), y, protectStartY);
                protectUntil = Date.now() + PROTECT_MS;
                protectBlockCount = 0;
                pendingRestoreY = Math.max(pendingRestoreY, y);
                pendingRestoreUntil = Date.now() + 700;

                if (sourceEl && isScrollableElement(sourceEl)) {
                    pendingRestoreElement = sourceEl;
                    pendingRestoreElementY = Math.max(pendingRestoreElementY, getElementScrollY(sourceEl));
                } else if (lastActiveScrollableElement && Date.now() - lastActiveScrollableAt < 1500) {
                    pendingRestoreElement = lastActiveScrollableElement;
                    pendingRestoreElementY = Math.max(pendingRestoreElementY, lastActiveScrollableY);
                }
            }

            function isProtecting() {
                return Date.now() < protectUntil && protectStartY > PROTECT_TRIGGER_Y;
            }

            function shouldBlockTopJump(targetY) {
                if (!Number.isFinite(targetY)) return false;
                if (targetY > TOP_Y_THRESHOLD) return false;
                if (!isProtecting()) return false;
                return protectBlockCount < 16;
            }

            function shouldBlockTopJumpOnElement(el, targetY) {
                if (!shouldBlockTopJump(targetY)) return false;
                if (isRootScroller(el)) return true;
                if (pendingRestoreElement && el === pendingRestoreElement) return true;
                if (lastActiveScrollableElement && el === lastActiveScrollableElement) return true;
                return false;
            }

            function applyRestoreScroll(targetY) {
                const rootTargetY = Number.isFinite(targetY) ? targetY : 0;
                const elementTargetY = Number.isFinite(pendingRestoreElementY) ? pendingRestoreElementY : 0;
                if (rootTargetY <= PROTECT_TRIGGER_Y && elementTargetY <= PROTECT_TRIGGER_Y) return;
                isInternalRestoreApply = true;
                try {
                    const root = document.scrollingElement || document.documentElement || document.body;
                    if (rootTargetY > PROTECT_TRIGGER_Y && root) {
                        root.scrollTop = rootTargetY;
                    }
                    if (pendingRestoreElement && isScrollableElement(pendingRestoreElement) && elementTargetY > PROTECT_TRIGGER_Y) {
                        pendingRestoreElement.scrollTop = elementTargetY;
                    }
                } finally {
                    requestAnimationFrame(() => { isInternalRestoreApply = false; });
                }
            }

            function scheduleRestoreRetry() {
                if (restoreTaskActive) return;
                restoreTaskActive = true;
                [24, 72, 160, 280].forEach((delay) => {
                    setTimeout(() => {
                        if (Date.now() > pendingRestoreUntil) return;
                        const needRoot = currentScrollY() <= TOP_Y_THRESHOLD && pendingRestoreY > PROTECT_TRIGGER_Y;
                        const needEl = pendingRestoreElement && getElementScrollY(pendingRestoreElement) <= TOP_Y_THRESHOLD && pendingRestoreElementY > PROTECT_TRIGGER_Y;
                        if (needRoot || needEl) applyRestoreScroll(pendingRestoreY);
                    }, delay);
                });
                setTimeout(() => { restoreTaskActive = false; }, 360);
            }

            // window.scrollTo 보호
            const origWindowScrollTo = window.scrollTo.bind(window);
            window.scrollTo = function(...args) {
                const targetY = parseTargetY(args);
                if (!isInternalRestoreApply && targetY !== null && targetY > PROTECT_TRIGGER_Y) {
                    startProtect(targetY, null); scheduleRestoreRetry();
                }
                if (shouldBlockTopJump(targetY)) { protectBlockCount += 1; return; }
                return origWindowScrollTo(...args);
            };
            window.scroll = window.scrollTo;

            // Element.prototype.scrollTo 보호
            const origElemScrollTo = Element.prototype.scrollTo;
            if (typeof origElemScrollTo === 'function') {
                Element.prototype.scrollTo = function(...args) {
                    if (isRootScroller(this) || isScrollableElement(this)) {
                        const targetY = parseTargetY(args);
                        if (!isInternalRestoreApply && targetY !== null && targetY > PROTECT_TRIGGER_Y) {
                            startProtect(targetY, this); scheduleRestoreRetry();
                        }
                        if (shouldBlockTopJumpOnElement(this, targetY)) { protectBlockCount += 1; return; }
                    }
                    return origElemScrollTo.apply(this, args);
                };
            }

            // scrollTop setter 보호
            const scrollTopDesc = Object.getOwnPropertyDescriptor(Element.prototype, 'scrollTop')
                || Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'scrollTop');
            const patchedSet = new WeakSet();

            function patchScrollTopForElement(el) {
                if (!el || !isScrollableElement(el) || patchedSet.has(el)) return;
                if (!scrollTopDesc?.get || !scrollTopDesc?.set) return;
                try {
                    Object.defineProperty(el, 'scrollTop', {
                        configurable: true,
                        get: function() { return scrollTopDesc.get.call(this); },
                        set: function(v) {
                            const targetY = toFiniteNumber(v);
                            if (!isInternalRestoreApply && targetY !== null && targetY > PROTECT_TRIGGER_Y) {
                                startProtect(targetY, this); scheduleRestoreRetry();
                            }
                            if (shouldBlockTopJumpOnElement(this, targetY)) { protectBlockCount += 1; return; }
                            scrollTopDesc.set.call(this, v);
                        }
                    });
                    patchedSet.add(el);
                } catch (_) {}
            }

            [document.scrollingElement, document.documentElement, document.body]
                .filter(Boolean)
                .forEach(el => patchScrollTopForElement(el));

            document.addEventListener('scroll', (e) => {
                const t = e?.target;
                if (t instanceof Element && isScrollableElement(t)) {
                    const y = getElementScrollY(t);
                    if (y > PROTECT_TRIGGER_Y) {
                        lastActiveScrollableElement = t;
                        lastActiveScrollableY = y;
                        lastActiveScrollableAt = Date.now();
                        patchScrollTopForElement(t);
                    }
                }
            }, { capture: true, passive: true });

        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
