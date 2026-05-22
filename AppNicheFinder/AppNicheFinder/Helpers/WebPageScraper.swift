//
//  WebPageScraper.swift
//  AppNicheFinder
//
//  Hybrid-парсер страницы App Store:
//
//  1) FAST PATH — прямой HTTP-запрос и парсинг встроенного JSON
//     `<script id="serialized-server-data">`. Гарантированно даёт subtitle
//     и top-1 IAP, который Apple рендерит на лендинге.
//
//  2) DEEP PATH — WKWebView (всегда форсим `us`-локаль для стабильности
//     английских селекторов). После загрузки страницы кликаем по строке
//     "In-App Purchases" в секции Information → открывается модалка с
//     ПОЛНЫМ списком IAP, которую парсим из DOM.
//
//  Результаты обоих путей мёрджатся; дубли убираются по productID / name+price.
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
            case .alreadyRunning: return "Скрейпер занят другим запросом — попробуйте чуть позже."
            }
        }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[AppIAP], Error>?
    private var timeoutTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var deepChain: Task<Void, Never> = Task {}
    private let navDelegate = NavDelegate()

    override init() {
        super.init()
        navDelegate.owner = self
    }

    // MARK: - Public entrypoint
    func scrape(url: URL) async throws -> ScrapedPage {
        // Принудительно us — английская локаль, стабильные селекторы.
        let usURL = forceUSLocale(url) ?? url

        // 1) Быстрый путь: SSD JSON (subtitle гарантировано, IAPs — частично)
        async let ssdResult: (subtitle: String, iaps: [AppIAP]) = fetchSSD(url: usURL)

        // 2) Глубокий путь: WKWebView. Сериализуем, чтобы при N приложениях
        //    parallel-таски не дрались за единственный WKWebView.
        let prevChain = deepChain
        let myDeepTask = Task<[AppIAP], Never> { [weak self] in
            _ = await prevChain.value
            guard let self else { return [] }
            do {
                return try await self.fetchDeepIAPs(url: usURL)
            } catch {
                print("🟥 Deep scraper failed: \(error.localizedDescription)")
                return []
            }
        }
        deepChain = Task { _ = await myDeepTask.value }

        let (subtitle, ssdIAPs) = await ssdResult
        let deep = await myDeepTask.value

        // Мёрж по productID / name+price
        var merged: [AppIAP] = []
        var seen = Set<String>()
        for source in [ssdIAPs, deep] {
            for iap in source {
                let key = iap.id.isEmpty ? "\(iap.name)|\(iap.priceFormatted)" : iap.id
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                merged.append(iap)
            }
        }

        print("🔎 Scraper FINAL: subtitle=\(subtitle.isEmpty ? "EMPTY" : "\"\(subtitle)\"")  iaps=\(merged.count) (ssd=\(ssdIAPs.count), deep=\(deep.count))")
        return ScrapedPage(subtitle: subtitle, iaps: merged)
    }

    private func forceUSLocale(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Заменяем /xx/ в начале пути на /us/
        let pathParts = comps.path.split(separator: "/", omittingEmptySubsequences: false)
        if pathParts.count > 1 && pathParts[1].count == 2 {
            comps.path = "/us/" + pathParts.dropFirst(2).joined(separator: "/")
        }
        // Удаляем параметр l=...
        comps.queryItems = comps.queryItems?.filter { $0.name != "l" }
        return comps.url
    }

    // MARK: - FAST PATH: SSD JSON
    private nonisolated func fetchSSD(url: URL) async -> (subtitle: String, iaps: [AppIAP]) {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        NetworkLogger.logRequest(request)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            NetworkLogger.logResponse(response, data: Data(), requestURL: url)
            guard let html = String(data: data, encoding: .utf8) else { return ("", []) }
            guard let ssdRaw = Self.extractSSD(from: html) else { return ("", []) }
            let decoded = Self.htmlDecode(ssdRaw)
            guard let jsonData = decoded.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return ("", []) }
            return (Self.extractSubtitle(from: json), Self.extractIAPsFromSSD(json: json))
        } catch {
            return ("", [])
        }
    }

    // MARK: - DEEP PATH: WKWebView click & scrape modal
    private func fetchDeepIAPs(url: URL) async throws -> [AppIAP] {
        if continuation != nil { throw ScrapeError.alreadyRunning }
        guard let hostView = Self.hostViewForScraper() else { throw ScrapeError.loadFailed }

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(
            frame: CGRect(x: -2000, y: -2000, width: 1200, height: 2400),
            configuration: config
        )
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = navDelegate
        webView.alpha = 0.01
        hostView.addSubview(webView)
        self.webView = webView

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[AppIAP], Error>) in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                print("🟥 Scraper: TIMEOUT")
                await self?.finish(with: .failure(ScrapeError.timeout))
            }
            webView.load(URLRequest(url: url))
            print("🟢 Scraper: WKWebView loading \(url.absoluteString)")
        }
    }

    fileprivate func didFinishNavigation() {
        print("🟢 Scraper: navigation finished, starting interaction")
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            guard let self else { return }
            // Дать странице 3 секунды на client-side гидрацию
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            // Сначала пробуем кликнуть по "In-App Purchases" в Information section.
            _ = await self.runJS(Self.clickIAPInfoRowJS)
            try? await Task.sleep(nanoseconds: 2_500_000_000)

            // Парсим DOM после клика
            var collected = await self.extractIAPsFromDOM()

            // Если модалка не открылась — пробуем парсить из текущего DOM как есть
            if collected.isEmpty {
                for _ in 0..<4 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    collected = await self.extractIAPsFromDOM()
                    if !collected.isEmpty { break }
                }
            }

            await self.finish(with: .success(collected))
        }
    }

    fileprivate func didFailNavigation(_ error: Error) {
        print("🟥 Scraper: nav failed — \(error.localizedDescription)")
        Task { await finish(with: .failure(error)) }
    }

    private func finish(with result: Result<[AppIAP], Error>) async {
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
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    private func runJS(_ js: String) async -> Any? {
        guard let webView else { return nil }
        return try? await webView.evaluateJavaScript(js)
    }

    private func extractIAPsFromDOM() async -> [AppIAP] {
        let raw = await runJS(Self.extractIAPsFromDOMJS) as? String ?? ""
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var out: [AppIAP] = []
        var seen = Set<String>()
        for item in arr {
            guard let name = item["name"] as? String, !name.isEmpty else { continue }
            guard let priceFmt = item["price"] as? String, !priceFmt.isEmpty else { continue }
            guard let priceVal = AppLookupService.extractAmount(from: priceFmt), priceVal > 0 else { continue }
            let lowName = name.lowercased()
            let isSub = ["subscription", "weekly", "monthly", "yearly", "annual", "premium"]
                .contains(where: { lowName.contains($0) })
            let key = "\(name)|\(priceFmt)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(AppIAP(
                id: key,
                name: name,
                priceFormatted: priceFmt,
                price: priceVal,
                isSubscription: isSub
            ))
        }
        return out
    }

    // MARK: - JS injections
    /// Находит в Information кнопку с текстом "In-App Purchases" и кликает её.
    private static let clickIAPInfoRowJS: String = #"""
    (function() {
        function clickIf(el) {
            if (!el) return false;
            // Ищем ближайший кликабельный (button или [role=button])
            let node = el;
            for (let i = 0; i < 5 && node; i++) {
                if (node.tagName === 'BUTTON' || node.getAttribute && node.getAttribute('role') === 'button') {
                    node.click();
                    return true;
                }
                node = node.parentElement;
            }
            // Иначе кликаем сам элемент
            try { el.click(); return true; } catch(e) { return false; }
        }
        // a) ищем кнопку с aria-label или текстом "In-App Purchases"
        const all = document.querySelectorAll('button, [role="button"], a, span, dt, dd');
        for (const el of all) {
            const txt = (el.textContent || '').trim();
            if (/^In[\u2010\u2011\u2012\u2013\-‑‒]App Purchases$/i.test(txt)
                || txt.toLowerCase() === 'in-app purchases'
                || txt.toLowerCase() === 'in‑app purchases') {
                // Найден заголовок — кликаем по нему или соседу с "Yes" / "See All"
                if (clickIf(el)) return 'clicked-header';
                let sib = el.nextElementSibling;
                if (sib && clickIf(sib)) return 'clicked-sibling';
                let parent = el.parentElement;
                if (parent) {
                    const btn = parent.querySelector('button, [role="button"], a');
                    if (clickIf(btn)) return 'clicked-parent-button';
                }
            }
        }
        // b) ищем кнопку "See All" рядом с любым "Subscriptions" заголовком
        const headings = document.querySelectorAll('h2, h3, h4');
        for (const h of headings) {
            const txt = (h.textContent || '').toLowerCase();
            if (txt.includes('subscription') || txt.includes('in-app') || txt.includes('in‑app')) {
                const container = h.closest('section') || h.parentElement;
                if (container) {
                    const btn = container.querySelector('button:not([disabled]), a[href]');
                    if (clickIf(btn)) return 'clicked-shelf-see-all';
                }
            }
        }
        return 'not-found';
    })();
    """#

    /// Извлекает IAP из DOM (после клика — модалка, либо из существующего шелфа).
    private static let extractIAPsFromDOMJS: String = #"""
    (function() {
        function txt(el){ return ((el && (el.innerText || el.textContent)) || '').trim().replace(/\s+/g, ' '); }
        function isPrice(s) {
            if (!s) return false;
            return /[\d][\d.,]{0,12}/.test(s) &&
                   /(\$|€|£|₽|¥|USD|EUR|RUB|GBP|JPY|CNY|UAH|PLN|TRY|INR|BRL|CAD|AUD|KRW|MXN|ARS|HKD)/i.test(s);
        }
        const out = [];
        const seen = new Set();

        // 1) Если открылась модалка — её содержимое имеет role=dialog или класс с modal/dialog
        let containers = Array.from(document.querySelectorAll(
            '[role="dialog"], .we-modal, .we-modal__content, [class*="dialog"], [class*="modal"]'
        ));

        // 2) Кроме модалки, всегда смотрим shelf с subscriptions/in-app-purchases на странице
        const shelves = document.querySelectorAll('section, ol, ul');
        for (const sec of shelves) {
            const head = sec.querySelector('h2, h3, h4');
            if (!head) continue;
            const t = (head.textContent || '').toLowerCase();
            if (t.includes('subscription') || t.includes('in-app') || t.includes('in‑app') || t.includes('purchases')) {
                containers.push(sec);
            }
        }

        // 3) Дефолт — весь body (на крайний случай)
        if (containers.length === 0) containers = [document.body];

        for (const container of containers) {
            // a) Структурный список: ищем элементы со связкой название + цена
            const items = container.querySelectorAll(
                'li, .we-modal__inappprods__list__item, .information-list__item, ol > div, dl > div, [class*="lockup"]'
            );
            for (const it of items) {
                // Берём первый осмысленный текст как имя, последний ценовой как цена
                const candidates = it.querySelectorAll('span, dt, dd, div, p, h3');
                let name = '', price = '';
                for (const c of candidates) {
                    const t = txt(c);
                    if (!t) continue;
                    if (!name && !isPrice(t) && t.length < 120 && t.length > 1) name = t;
                    if (isPrice(t) && t.length < 30) price = t;
                }
                if (!name) name = txt(it).split('\n')[0];
                if (!name || !price) continue;
                const key = name + '|' + price;
                if (seen.has(key)) continue;
                seen.add(key);
                out.push({ name, price });
            }
        }

        // 4) Fallback: ищем все «ценовые» узлы во всем документе и тащим соседа
        if (out.length === 0) {
            const all = document.querySelectorAll('span, p, div, td');
            for (const node of all) {
                const t = txt(node);
                if (!isPrice(t) || t.length > 30) continue;
                const row = node.closest('li, tr, dl > div, .information-list__item') || node.parentElement;
                if (!row) continue;
                let rowText = txt(row);
                if (!rowText) continue;
                let name = rowText.replace(t, '').trim();
                if (!name || name.length > 120 || name.length < 2) continue;
                const key = name + '|' + t;
                if (seen.has(key)) continue;
                seen.add(key);
                out.push({ name, price: t });
                if (out.length >= 30) break;
            }
        }

        return JSON.stringify(out);
    })();
    """#

    // MARK: - SSD helpers (pure functions — nonisolated for background SSD path)
    nonisolated private static func extractSSD(from html: String) -> String? {
        let pattern = #"<script[^>]*id="serialized-server-data"[^>]*>([\s\S]+?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    nonisolated private static func htmlDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    nonisolated private static func extractSubtitle(from root: [String: Any]) -> String {
        let dataArr = (root["data"] as? [[String: Any]]) ?? []
        guard let first = dataArr.first,
              let pageData = first["data"] as? [String: Any] else { return "" }
        if let lockup = pageData["lockup"] as? [String: Any],
           let subtitle = lockup["subtitle"] as? String, !subtitle.isEmpty {
            return subtitle
        }
        if let titleProps = pageData["titleOfferDisplayProperties"] as? [String: Any],
           let subtitles = titleProps["subtitles"] as? [String: Any],
           let std = subtitles["standard"] as? String, !std.isEmpty {
            return std
        }
        return ""
    }

    nonisolated private static func extractIAPsFromSSD(json root: [String: Any]) -> [AppIAP] {
        let dataArr = (root["data"] as? [[String: Any]]) ?? []
        guard let first = dataArr.first,
              let pageData = first["data"] as? [String: Any],
              let shelfMapping = pageData["shelfMapping"] as? [String: Any]
        else { return [] }
        var result: [AppIAP] = []
        var seen = Set<String>()
        for (shelfKey, shelfValue) in shelfMapping {
            guard let shelf = shelfValue as? [String: Any] else { continue }
            let contentType = (shelf["contentType"] as? String) ?? ""
            let isIAPShelf = contentType.lowercased().contains("inapppurchase")
                || shelfKey.lowercased().contains("subscription")
                || shelfKey.lowercased().contains("inapp")
            guard isIAPShelf else { continue }
            guard let items = shelf["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let iap = makeIAPFromSSDItem(item, shelfKey: shelfKey) else { continue }
                guard !seen.contains(iap.id) else { continue }
                seen.insert(iap.id)
                result.append(iap)
            }
        }
        return result
    }

    nonisolated private static func makeIAPFromSSDItem(_ item: [String: Any], shelfKey: String) -> AppIAP? {
        guard let name = (item["title"] as? String) ?? (item["productDescription"] as? String),
              !name.isEmpty else { return nil }
        guard let priceValue = findPrice(in: item), priceValue > 0 else { return nil }
        let productID: String = {
            if let action = item["buttonAction"] as? [String: Any],
               let pid = action["productIdentifier"] as? String { return pid }
            return ""
        }()
        let lowKey = shelfKey.lowercased()
        let lowPid = productID.lowercased()
        let lowName = name.lowercased()
        let isSub =
            lowKey.contains("subscription")
            || lowPid.contains("sub")
            || lowName.contains("subscription") || lowName.contains("подписк")
            || lowName.contains("weekly") || lowName.contains("monthly") || lowName.contains("yearly") || lowName.contains("annual")
        let priceFormatted = String(format: "$%.2f", priceValue)
        let id = productID.isEmpty ? "\(name)|\(priceValue)" : productID
        return AppIAP(id: id, name: name, priceFormatted: priceFormatted,
                      price: priceValue, isSubscription: isSub)
    }

    nonisolated private static func findPrice(in value: Any) -> Double? {
        if let dict = value as? [String: Any] {
            if let p = dict["price"] {
                if let d = p as? Double, d > 0 { return d }
                if let i = p as? Int { return Double(i) }
                if let s = p as? String, let d = Double(s), d > 0 { return d }
            }
            for (_, sub) in dict {
                if let found = findPrice(in: sub) { return found }
            }
        } else if let arr = value as? [Any] {
            for item in arr {
                if let found = findPrice(in: item) { return found }
            }
        }
        return nil
    }

    // MARK: - Host view
    private static func hostViewForScraper() -> UIView? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        for scene in scenes {
            if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return keyWindow
            }
        }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first }
            .first
    }
}

// MARK: - Navigation delegate
private final class NavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: WebPageScraper?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
           scheme != "http", scheme != "https", scheme != "about" {
            decisionHandler(.cancel)
            Task { @MainActor in
                owner?.didFailNavigation(NSError(domain: "WebPageScraper", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Blocked redirect to \(scheme)://"]))
            }
            return
        }
        decisionHandler(.allow)
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
