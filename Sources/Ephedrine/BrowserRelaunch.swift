import AppKit
import UserNotifications
import EphedrineCore

struct ThrottledBrowser: Equatable { let bundleID: String; let name: String }

/// `ps`'s own view of a process's command line; empty means unknown (never a guess).
private func browserArgs(pid: pid_t) -> String {
    let r = runProcess("/bin/ps", ["-ww", "-o", "args=", "-p", "\(pid)"], timeout: 3)
    guard !r.timedOut, !r.launchFailed, r.status == 0 else { return "" }
    return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func runningInstances(_ bundleID: String) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
}

extension AppController {
    /// The scan is wanted: lid mode is set up and the owner left the warning on.
    var browserScanWanted: Bool { lidSetupOK && settings.browserThrottleWarning }

    /// The menu's warning lines for browsers: the throttle warning, then each relaunch problem.
    func browserWarnings() -> [String] {
        guard browserScanWanted else { return [] }
        var out: [String] = []
        if let w = throttleWarning(throttledBrowsers.map(\.name)) { out.append(w) }
        out += relaunchProblems.keys.sorted().compactMap { relaunchProblems[$0] }
        return out
    }

    /// One "Relaunch <name> unthrottled" item per throttled browser.
    func addBrowserItems(to menu: NSMenu) {
        guard browserScanWanted else { return }
        for b in throttledBrowsers {
            let it = item("Relaunch \(b.name) unthrottled", #selector(relaunchBrowserChosen(_:)),
                          tip: "Quits \(b.name) and opens it again with the two flags that stop it slowing down hidden windows. Asks first.",
                          symbol: "arrow.clockwise")
            it.representedObject = b
            menu.addItem(it)
        }
    }

    @objc func relaunchBrowserChosen(_ sender: NSMenuItem) {
        guard let b = sender.representedObject as? ThrottledBrowser else { return }
        relaunchUnthrottled(b)
    }

    /// Clear everything the feature shows (setting off, or lid mode not set up).
    func clearBrowserState() {
        browserScanGeneration += 1
        throttledBrowsers = []
        relaunchProblems = [:]
    }

    /// Every 60 s, and when the setting turns on: look at running Chromium browsers.
    /// `ps` runs on its own queue; the result is published on main.
    func scanBrowsers() {
        guard browserScanWanted else {
            if !throttledBrowsers.isEmpty || !relaunchProblems.isEmpty { clearBrowserState() }
            return
        }
        guard !browserScanning else { return }
        browserScanning = true
        let generation = browserScanGeneration
        let found: [(id: String, name: String, pids: [pid_t])] = chromiumBrowsers.compactMap { id in
            let apps = runningInstances(id)
            return apps.isEmpty ? nil : (id, apps[0].localizedName ?? id, apps.map(\.processIdentifier))
        }
        browserQueue.async { [weak self] in
            var throttled: [ThrottledBrowser] = []
            var fine = Set(chromiumBrowsers)   // not running, or running with both flags
            for f in found {
                // Unknown (empty) args count as not throttled, and keep a problem line alive.
                let lines = f.pids.map { browserArgs(pid: $0) }.filter { !$0.isEmpty }
                if lines.contains(where: { !hasUnthrottleFlags(args: $0) }) {
                    throttled.append(ThrottledBrowser(bundleID: f.id, name: f.name)); fine.remove(f.id)
                } else if lines.isEmpty { fine.remove(f.id) }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.browserScanning = false
                guard generation == self.browserScanGeneration, self.browserScanWanted else { return }
                self.throttledBrowsers = throttled
                // A problem ends once its browser is gone or fixed; an unreadable one keeps its line.
                for id in fine { self.relaunchProblems[id] = nil }
            }
        }
    }

    private func browserProblem(_ b: ThrottledBrowser, _ text: String) {
        relaunchProblems[b.bundleID] = text
        logLine("browser relaunch: \(text)")
        let c = UNMutableNotificationContent(); c.title = "Browser not relaunched"; c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ka_browser", content: c, trigger: nil))
    }

    /// Ask, then quit the browser politely and open it again with the flags.
    /// Nothing is quit unless the owner confirms and the browser's settings were read.
    func relaunchUnthrottled(_ b: ThrottledBrowser) {
        guard !browserRelaunching.contains(b.bundleID) else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Quit and relaunch \(b.name)?"
        alert.informativeText = "Ephedrine quits \(b.name) and opens it again with the two flags that stop it slowing down hidden windows. Your windows and tabs come back only if \(b.name) reopens them on startup."
        alert.addButton(withTitle: "Quit and relaunch")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating   // an accessory app's alert can land behind other windows
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        browserRelaunching.insert(b.bundleID)
        browserScanGeneration += 1   // a scan already running saw the old state
        let apps = runningInstances(b.bundleID)
        let pids = apps.map(\.processIdentifier)
        browserQueue.async { [weak self] in
            let argLines = pids.map { browserArgs(pid: $0) }
            DispatchQueue.main.async { self?.finishRelaunch(b, apps: apps, argLines: argLines) }
        }
    }

    private func finishRelaunch(_ b: ThrottledBrowser, apps: [NSRunningApplication], argLines: [String]) {
        func done() { browserRelaunching.remove(b.bundleID) }
        guard !apps.isEmpty else { done(); return }   // already quit; the next scan settles the menu
        guard !argLines.contains("") else {
            browserProblem(b, "Couldn't read \(b.name)'s settings, so it wasn't quit")
            done(); return
        }
        logLine("browser relaunch: quitting \(b.name) (\(apps.count) instance\(apps.count == 1 ? "" : "s"))")
        for a in apps { a.terminate() }   // a polite quit, never a force
        waitForQuit(apps, deadline: Date().addingTimeInterval(10)) { [weak self] quit in
            guard let self = self else { return }
            guard quit else {
                self.browserProblem(b, "\(b.name) didn't quit within 10 seconds, so it wasn't reopened")
                done(); return
            }
            self.browserQueue.async {
                // The first instance reopens with -b; each further one needs its own (-n).
                var failure: String?
                for (i, line) in argLines.enumerated() {
                    let r = runProcess("/usr/bin/open", (i == 0 ? ["-b", b.bundleID] : ["-n", "-b", b.bundleID])
                                       + ["--args"] + relaunchArguments(args: line), timeout: 15)
                    if r.timedOut || r.launchFailed || r.status != 0 {
                        let why = r.timedOut ? "open didn't answer" : (r.err.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(r.status)")
                        failure = "\(b.name) quit but couldn't be reopened (\(String(why.prefix(120))))"
                        break
                    }
                }
                DispatchQueue.main.async {
                    if let failure = failure { self.browserProblem(b, failure) }
                    else {
                        logLine("browser relaunch: \(b.name) reopened unthrottled")
                        self.relaunchProblems[b.bundleID] = nil
                        self.throttledBrowsers.removeAll { $0.bundleID == b.bundleID }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.scanBrowsers() }   // confirm it took
                    }
                    done()
                }
            }
        }
    }

    /// Poll until every app is gone or the deadline passes; main thread.
    private func waitForQuit(_ apps: [NSRunningApplication], deadline: Date, _ completion: @escaping (Bool) -> Void) {
        if apps.allSatisfy(\.isTerminated) { completion(true); return }
        if Date() >= deadline { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard self != nil else { return }
            self?.waitForQuit(apps, deadline: deadline, completion)
        }
    }
}
