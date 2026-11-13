import Foundation
import VelumStatus

// `velumctl`: Velum's status for scripts, Raycast and backup jobs (card T1). It only reads the status file the
// running Velum writes after every refresh; it changes nothing. See docs/velumctl.md.

/// The version of the Velum.app this copy sits in (`Velum.app/Contents/MacOS/velumctl`), found through any
/// symlink on the PATH; "dev build" outside an app.
func appVersion() -> String {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev build" }
    let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
    guard let info = NSDictionary(contentsOf: plist),
          let version = info["CFBundleShortVersionString"] as? String else { return "dev build" }
    return (info["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
}

let output = VelumCtl.run(Array(CommandLine.arguments.dropFirst()), version: appVersion()) { StatusReading.read() }
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.code)
