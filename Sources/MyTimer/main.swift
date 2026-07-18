import AppKit
import Foundation

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    exit(runSelfTest())
}
if let index = arguments.firstIndex(of: "--send-add-seconds"), arguments.indices.contains(index + 1),
   let seconds = Double(arguments[index + 1]) {
    postDebugCommand(["command": "add-seconds", "seconds": seconds])
    exit(0)
}
if let index = arguments.firstIndex(of: "--send-delete-id"), arguments.indices.contains(index + 1) {
    postDebugCommand(["command": "delete-id", "prefix": arguments[index + 1]])
    exit(0)
}
if arguments.contains("--send-clear") {
    postDebugCommand(["command": "clear"])
    exit(0)
}
if arguments.contains("--send-write-frame") {
    postDebugCommand(["command": "write-frame"])
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
