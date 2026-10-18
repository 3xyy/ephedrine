import Testing
import Foundation
@testable import EphedrineCore

@Test func flagDetection() {
    let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    #expect(hasUnthrottleFlags(argv: [chrome, "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]))
    #expect(!hasUnthrottleFlags(argv: [chrome, "--disable-renderer-backgrounding"]))
    #expect(hasUnthrottleFlags(argv: [chrome, "--disable-backgrounding-occluded-windows=1", "--disable-renderer-backgrounding"]))
    #expect(!hasUnthrottleFlags(argv: [chrome, "--disable-backgrounding-occluded-windows-x", "--disable-renderer-backgrounding"]))
}
@Test func relaunchKeepsProfile() {
    #expect(relaunchArguments(argv: ["Chrome", "--user-data-dir=/Users/x/My Profile", "--profile-directory=Default", "--foo"])
            == unthrottleFlags + ["--user-data-dir=/Users/x/My Profile", "--profile-directory=Default"])
}
@Test func relaunchKeepsApostropheAndDropsPositionals() {
    #expect(relaunchArguments(argv: ["Chrome", "--user-data-dir=/Users/x/Bob's Chrome", "--profile-directory=Default", "about:blank"])
            == unthrottleFlags + ["--user-data-dir=/Users/x/Bob's Chrome", "--profile-directory=Default"])
    #expect(relaunchArguments(argv: ["Chrome", "--profile-directory=Profile 1", "localhost:3000", "file.html"])
            == unthrottleFlags + ["--profile-directory=Profile 1"])
}
@Test func relaunchWithoutProfileFlags() {
    #expect(relaunchArguments(argv: ["Chrome", "--foo"]) == unthrottleFlags)
}
@Test func profileChecks() {
    #expect(profileDirectoriesToCheck(argv: ["C", "--foo"]) == [])
    #expect(profileDirectoriesToCheck(argv: ["C", "--user-data-dir=/a b"]) == ["/a b"])
    #expect(profileDirectoriesToCheck(argv: ["C", "--user-data-dir=/a b", "--profile-directory=Profile 1"]) == ["/a b", "/a b/Profile 1"])
    #expect(profileDirectoriesToCheck(argv: ["C", "--profile-directory=Default"]) == [])
    #expect(profileDirectoriesToCheck(argv: ["C", "--user-data-dir="]) == [""])
    #expect(profileDirectoriesToCheck(argv: ["C", "--user-data-dir=/old", "--user-data-dir=/new"]) == ["/new"])   // the browser honors the last
}
@Test func throttleWording() {
    #expect(throttleWarning([]) == nil)
    #expect(throttleWarning(["Chrome"]) == "Chrome is throttled with the lid shut")
    #expect(throttleWarning(["Chrome", "Arc", "Brave"]) == "Chrome, Arc and Brave are throttled with the lid shut")
}
@Test func throttleWordingTwo() {
    #expect(throttleWarning(["Chrome", "Arc"]) == "Chrome and Arc are throttled with the lid shut")
}
private func procArgs2(argc: Int32, exec: String, args: [String], env: [String] = ["HOME=/Users/x"], pad: Int = 3) -> [UInt8] {
    var d = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
    d += Array(exec.utf8) + [0] + [UInt8](repeating: 0, count: pad)
    for a in args + env { d += Array(a.utf8) + [0] }
    return d
}
@Test func procArgsParsing() {
    let exec = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    let args = [exec, "--user-data-dir=/Users/x/Bob's Chrome", "--profile-directory=Profile 1", "about:blank"]
    #expect(parseProcArgs2(procArgs2(argc: 4, exec: exec, args: args)) == args)
    #expect(parseProcArgs2(procArgs2(argc: 1, exec: exec, args: [exec], env: [])) == [exec])   // no environment at all
    #expect(parseProcArgs2(procArgs2(argc: 2, exec: exec, args: [exec, "--a", "--b"])) == [exec, "--a"])
}
@Test func procArgsGarbage() {
    let exec = "/bin/x"
    #expect(parseProcArgs2([]) == nil)
    #expect(parseProcArgs2([1, 0, 0]) == nil)
    #expect(parseProcArgs2(procArgs2(argc: 0, exec: exec, args: [exec])) == nil)
    #expect(parseProcArgs2(procArgs2(argc: -1, exec: exec, args: [exec])) == nil)
    #expect(parseProcArgs2(procArgs2(argc: 3, exec: exec, args: [exec, "--a"], env: [])) == nil)   // fewer args than argc
    #expect(parseProcArgs2(Array(procArgs2(argc: 2, exec: exec, args: [exec, "--abc"], env: []).dropLast())) == nil)   // cut mid-argument
    #expect(parseProcArgs2([1, 0, 0, 0] + Array("/bin/x".utf8)) == nil)   // nothing after the exec path
}
@Test func browserSettingDefault() {
    let d = UserDefaults(suiteName: "browsers-test-\(UUID().uuidString)")!
    let s = AppSettings(defaults: d)
    #expect(s.browserThrottleWarning)
    s.browserThrottleWarning = false
    #expect(!AppSettings(defaults: d).browserThrottleWarning)
}
@Test func browserList() {
    #expect(chromiumBrowsers.contains("com.google.Chrome") && chromiumBrowsers.count == 6)
}
