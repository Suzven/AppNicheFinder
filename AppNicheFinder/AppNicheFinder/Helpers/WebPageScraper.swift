//
//  WebPageScraper.swift
//  AppNicheFinder
//
//  apps.apple.com теперь полностью клиентский SPA: всё рисуется JS на лету.
//  Эта реализация открывает страницу в скрытом WKWebView, прикрепляет его
//  к UIWindow (без этого layout не выполняется), ждёт пока DOM стабилизируется
//  и появится блок IAP, затем достаёт subtitle и список покупок через
//  evaluateJavaScript.
//

import Foundation
import WebKit
import UIKit
import OSLog

@MainActor
final class WebPageScraper: NSObject {

    static let shared = WebPageScraper()
    private static let logger = Logger(subsystem: "AppNicheFinder", category: "Scraper")

    struct ScrapedPage {
        let html: String
        let subtitle: String
        let iaps: [AppIAP]
    }

    enum ScrapeError: LocalizedError {
        case loadFailed
        case timeout
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .loadFailed:    return "Не удалось загрузить страницу App Store."
            case .timeout:       return "Страница не отрисовалась за отведённое время."
            case .alreadyRunning: return "Скрейпер уже занят другим запросом."
            }
        }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<ScrapedPage, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private let navDelegate = NavDelegate()

    override init() {
        super.init()
        navDelegate.owner = self
    }

    func scrape(url: URL) async throws -> ScrapedPage {
        if continuation != nil {
            print("🟥 Scraper: alreadyRunning (продолжение уже занято)")
            throw ScrapeError.alreadyRunning
        }
        print("🟢 Scraper: scrape() called for \(url.absoluteString)")

        // Цепляем webView к уже существующему окну приложения — без этого
        // в iOS WKWebView не получает layout и navigation никогда не завершается.
        guard let hostView = Self.hostViewForScraper() else {
            print("🟥 Scraper: не нашёл host UIWindow — приложение ещё не активно")
            throw ScrapeError.loadFailed
        }
        print("🟢 Scraper: host view found = \(type(of: hostView))")

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let frame = CGRect(x: -2000, y: -2000, width: 1100, height: 2400) // за пределами экрана
        let webView = WKWebView(frame: frame, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = navDelegate
        webView.isHidden = false
        webView.alpha = 0.01
        hostView.addSubview(webView)
        self.webView = webView

        print("🟢 Scraper: webView attached, loading…")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScrapedPage, Error>) in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s hard cap
                print("🟥 Scraper: TIMEOUT")
                await self?.finish(with: .failure(ScrapeError.timeout))
            }
            webView.load(URLRequest(url: url))
        }
    }

    /// Находит view ключевого окна приложения, к которому можно прикрепить скрытый webView.
    private static func hostViewForScraper() -> UIView? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        for scene in scenes {
            if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return keyWindow
            }
        }
        // Запасной вариант: любое окно
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first }
            .first
    }

    // MARK: - Navigation callbacks

    fileprivate func didStartNavigation() {
        print("🟢 Scraper: navigation STARTED")
    }

    fileprivate func didFinishNavigation() {
        print("🟢 Scraper: navigation FINISHED, starting DOM polling")
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            guard let self else { return }
            // Долгий warm-up: React/Svelte монтируется и подгружает IAP отдельной XHR.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for attempt in 0..<14 {
                if Task.isCancelled { return }
                let result = await self.tryExtract(attempt: attempt)
                // Принимаем как успешный, если есть IAP ИЛИ subtitle и прошли минимум 4 попытки
                if !result.iaps.isEmpty {
                    await self.finish(with: .success(result))
                    return
                }
                if attempt >= 8 && !result.subtitle.isEmpty {
                    await self.finish(with: .success(result))
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // Финальная попытка: отдаём что есть, даже если пусто
            let last = await self.tryExtract(attempt: 99)
            await self.finish(with: .success(last))
        }
    }

    fileprivate func didFailNavigation(_ error: Error) {
        print("🟥 Scraper: navigation FAILED — \(error.localizedDescription)")
        Task { await finish(with: .failure(error)) }
    }

    private func finish(with result: Result<ScrapedPage, Error>) async {
        timeoutTask?.cancel()
        settleTask?.cancel()
        timeoutTask = nil
        settleTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil

        guard let cont = continuation else { return }
        continuation = nil
        switch result {
        case .success(let value): cont.resume(returning: value)
        case .failure(let err):   cont.resume(throwing: err)
        }
    }

    // MARK: - DOM extraction
    private func tryExtract(attempt: Int) async -> ScrapedPage {
        guard let webView else {
            return ScrapedPage(html: "", subtitle: "", iaps: [])
        }
        let js = Self.extractionJS
        do {
            let raw = try await webView.evaluateJavaScript(js)
            guard let str = raw as? String,
                  let data = str.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                Self.logger.debug("Scraper attempt \(attempt): JS returned non-string")
                return ScrapedPage(html: "", subtitle: "", iaps: [])
            }

            let subtitle = (dict["subtitle"] as? String) ?? ""
            let rawIAPs = (dict["iaps"] as? [[String: Any]]) ?? []
            let debugInfo = (dict["debug"] as? String) ?? ""

            Self.logger.debug("Scraper attempt \(attempt): subtitle=\(subtitle.isEmpty ? "EMPTY" : subtitle, privacy: .public), iaps=\(rawIAPs.count), debug=\(debugInfo, privacy: .public)")
            print("🔎 Scraper attempt \(attempt): subtitle=\(subtitle.isEmpty ? "EMPTY" : "\"\(subtitle)\"")  iaps=\(rawIAPs.count)  debug=\(debugInfo)")

            let iaps: [AppIAP] = rawIAPs.compactMap { item in
                guard let name = item["name"] as? String,
                      let priceFmt = item["priceFormatted"] as? String,
                      let price = AppLookupService.extractAmount(from: priceFmt),
                      price > 0
                else { return nil }
                let lowName = name.lowercased()
                let subscriptionMarkers = ["subscription", "подписк", "weekly", "monthly", "yearly", "annual",
                                           "ежемес", "годов", "недельн", "premium", "премиум"]
                let isSub = subscriptionMarkers.contains(where: { lowName.contains($0) })
                return AppIAP(
                    id: name + "|" + priceFmt,
                    name: name,
                    priceFormatted: priceFmt,
                    price: price,
                    isSubscription: isSub
                )
            }

            return ScrapedPage(html: "", subtitle: subtitle, iaps: iaps)
        } catch {
            Self.logger.debug("Scraper attempt \(attempt): JS error \(error.localizedDescription, privacy: .public)")
            return ScrapedPage(html: "", subtitle: "", iaps: [])
        }
    }

    // MARK: - The JS itself
    // Slепой и устойчивый к смене классов: ищем по тексту-маяку, потом собираем
    // все «пары» нейм+цена в соседних элементах.
    private static let extractionJS: String = #"""
    (function() {
        function txt(el){ return ((el && (el.innerText || el.textContent)) || "").trim().replace(/\s+/g, " "); }

        // ---------- SUBTITLE ----------
        let subtitle = "";

        // a) Текущая разметка
        const sel1 = document.querySelector('h2.product-header__subtitle, .product-header__subtitle');
        if (sel1) subtitle = txt(sel1);

        // b) Свежие веб-компоненты
        if (!subtitle) {
            const meta = document.querySelector('meta[name="apple:subtitle"], meta[property="og:description"]');
            if (meta) subtitle = (meta.getAttribute('content') || '').trim();
        }

        // c) Универсальный fallback: первый h2 рядом с h1 в шапке
        if (!subtitle) {
            const h1 = document.querySelector('h1');
            if (h1) {
                let cur = h1.nextElementSibling;
                for (let i = 0; cur && i < 5; i++, cur = cur.nextElementSibling) {
                    if (cur.tagName === 'H2') { subtitle = txt(cur); break; }
                    const inner = cur.querySelector && cur.querySelector('h2');
                    if (inner) { subtitle = txt(inner); break; }
                }
            }
        }

        // ---------- IAPs ----------
        const iapHeadings = ['in-app purchases', 'in‑app purchases', 'встроенные покупки',
                             'compras dentro de la app', 'käufe in der app', 'achats intégrés',
                             'acquisti in-app', '应用内购买', '앱 내 구입', '内蔵購入'];
        const subscriptionMarkers = ['subscription', 'подписк', 'weekly', 'monthly', 'yearly',
                                     'ежемес', 'годов', 'недельн', 'premium', 'премиум'];

        function looksLikePrice(s) {
            if (!s) return false;
            return /[\d][\d.,]{0,12}/.test(s) &&
                   /(\$|€|£|₽|¥|USD|EUR|RUB|GBP|JPY|CNY|UAH|PLN|TRY|INR|BRL|CAD|AUD|KRW|MXN|ARS|HKD)/i.test(s);
        }

        const out = [];
        const seen = new Set();

        // 1) Найти узел-якорь по тексту "Встроенные покупки" / "In-App Purchases"
        const all = document.querySelectorAll('h1, h2, h3, h4, dt, p, span, div');
        let anchor = null;
        for (const el of all) {
            const t = (txt(el) || '').toLowerCase();
            if (!t) continue;
            for (const needle of iapHeadings) {
                if (t === needle || t.startsWith(needle)) { anchor = el; break; }
            }
            if (anchor) break;
        }

        // 2) Поднимаемся к контейнеру (section/dl/ul/div) и собираем элементы
        if (anchor) {
            let container = anchor;
            for (let i = 0; i < 6 && container.parentElement; i++) {
                container = container.parentElement;
                // Если внутри уже виден список — стоп
                if (container.querySelectorAll('li, dl > div, .information-list__item').length >= 2) break;
            }

            // Пробуем структурный список
            const itemSelectors = [
                '.information-list__item',
                'li',
                'dl > div',
                '.we-modal__inappprods__list__item'
            ];
            let items = [];
            for (const s of itemSelectors) {
                const found = container.querySelectorAll(s);
                if (found.length >= 1) { items = Array.from(found); break; }
            }

            for (const it of items) {
                // У Apple обычно: первый <span>/<dt> — название, последний — цена.
                const candidates = it.querySelectorAll('span, dt, dd, div, p');
                let name = '', price = '';
                // Берём первый текстовый, который не цена, и последний, который похож на цену
                for (const c of candidates) {
                    const t = txt(c);
                    if (!t) continue;
                    if (!name && !looksLikePrice(t) && t.length < 120) name = t;
                    if (looksLikePrice(t)) price = t;
                }
                if (!name) name = txt(it).split('\n')[0];
                if (!name || !price) continue;

                const key = name + '|' + price;
                if (seen.has(key)) continue;
                seen.add(key);
                out.push({ name, priceFormatted: price });
            }
        }

        // 3) Fallback: парные dt/dd по всему документу — берём только те, где цена.
        if (out.length === 0) {
            const dts = document.querySelectorAll('dt');
            for (const dt of dts) {
                const dd = dt.nextElementSibling;
                if (!dd || dd.tagName !== 'DD') continue;
                const name = txt(dt), price = txt(dd);
                if (!name || !looksLikePrice(price)) continue;
                const key = name + '|' + price;
                if (seen.has(key)) continue;
                seen.add(key);
                out.push({ name, priceFormatted: price });
            }
        }

        // 4) Fallback: ищем "ценовые" узлы и берём ближайший текстовый сосед как имя.
        if (out.length === 0) {
            const allNodes = document.querySelectorAll('span, p, div');
            for (const node of allNodes) {
                const price = txt(node);
                if (!looksLikePrice(price) || price.length > 30) continue;
                const parent = node.parentElement;
                if (!parent) continue;
                // имя = первый осмысленный текст в этом же li/row
                const row = parent.closest('li, .information-list__item, dl > div, tr') || parent;
                const rowText = txt(row);
                if (!rowText || rowText === price) continue;
                let name = rowText.replace(price, '').trim();
                if (!name || name.length > 120) continue;
                const key = name + '|' + price;
                if (seen.has(key)) continue;
                seen.add(key);
                out.push({ name, priceFormatted: price });
                if (out.length >= 20) break;
            }
        }

        return JSON.stringify({
            subtitle: subtitle,
            iaps: out,
            debug: 'len=' + document.documentElement.outerHTML.length + ',anchor=' + (anchor ? 'yes' : 'no')
        });
    })();
    """#
}

// MARK: - Navigation Delegate
private final class NavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: WebPageScraper?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in owner?.didStartNavigation() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in owner?.didFinishNavigation() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in owner?.didFailNavigation(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in owner?.didFailNavigation(error) }
    }
}
