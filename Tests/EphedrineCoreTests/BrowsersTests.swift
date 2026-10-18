import Testing
import Foundation
@testable import EphedrineCore

@Test func flagDetection() {
    #expect(hasUnthrottleFlags(args: "/Applications/Google Chrome.app/Contents/MacOS/Google\\ Chrome --disable-backgrounding-occluded-windows --disable-renderer-backgrounding"))
    #expect(!hasUnthrottleFlags(args: "Chrome --disable-renderer-backgrounding"))
    #expect(hasUnthrottleFlags(args: "Chrome --disable-backgrounding-occluded-windows=1 --disable-renderer-backgrounding"))
}
@Test func relaunchKeepsProfile() {
    #expect(relaunchArguments(args: "Chrome --user-data-dir='/Users/x/My Profile' --profile-directory=Default --foo")
            == unthrottleFlags + ["--user-data-dir=/Users/x/My Profile", "--profile-directory=Default"])
}
@Test func throttleWording() {
    #expect(throttleWarning([]) == nil)
    #expect(throttleWarning(["Chrome"]) == "Chrome is throttled with the lid shut")
    #expect(throttleWarning(["Chrome", "Arc", "Brave"]) == "Chrome, Arc and Brave are throttled with the lid shut")
}
@Test func throttleWordingTwo() {
    #expect(throttleWarning(["Chrome", "Arc"]) == "Chrome and Arc are throttled with the lid shut")
}
@Test func shellWordParsing() {
    #expect(shellWords(#"a "b c" 'd e' f\ g  h"i j"k"#) == ["a", "b c", "d e", "f g", "hi jk"])
    #expect(shellWords(#""a \"q\" \\ \x""#) == [#"a "q" \ \x"#])
    #expect(shellWords("'a\\b'") == ["a\\b"])
    #expect(shellWords("  ") == [])
    #expect(shellWords("a ''") == ["a", ""])
    #expect(shellWords("'' b") == ["", "b"])
}
// `ps -o args=` joins argv with plain spaces, so a path with spaces arrives unquoted.
@Test func relaunchKeepsUnquotedPsPaths() {
    let ps = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser --user-data-dir=/Users/x/Library/Application Support/My Profile --profile-directory=Profile 1 --remote-debugging-port=9222 https://a.b/c d"
    #expect(relaunchArguments(args: ps)
            == unthrottleFlags + ["--user-data-dir=/Users/x/Library/Application Support/My Profile", "--profile-directory=Profile 1"])
}
@Test func relaunchStopsAtPositionalArguments() {
    #expect(relaunchArguments(args: "Chrome --profile-directory=Profile 1 https://a.b/c")
            == unthrottleFlags + ["--profile-directory=Profile 1"])
    #expect(relaunchArguments(args: "Chrome --user-data-dir=/a b /tmp/page.html")
            == unthrottleFlags + ["--user-data-dir=/a b"])
}
@Test func relaunchWithoutProfileFlags() {
    #expect(relaunchArguments(args: "Chrome --foo") == unthrottleFlags)
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
