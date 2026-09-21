import AppKit
import Foundation
import NetmonCore

@main
struct NetmonMenubarMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--render-fixture" {
            do {
                let request = try FixtureRequest(arguments: arguments)
                try request.render()
                return
            } catch {
                FileHandle.standardError.write(Data("render-fixture failed: \(error)\n".utf8))
                exit(2)
            }
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = MenubarApplicationDelegate()
        application.delegate = delegate
        application.run()
    }
}
