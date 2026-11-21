import AppKit
import PusuCore

#if DEBUG
if let index = CommandLine.arguments.firstIndex(of: "--snapshot-ui") {
    let path = CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : "build/snapshots"
    UISnapshot.run(outputDirectory: URL(fileURLWithPath: path))
    exit(0)
}
#endif

if CLI.handleEarly() {
    exit(0)
}

let application = NSApplication.shared
let singleInstance = SingleInstance()
if !singleInstance.acquire() {
    // Başka bir Pusu zaten çalışıyor: komutu ona ilet ve çık.
    if let command = CLI.pendingCommand() {
        if !CLI.deliver(command) {
            fputs(L("Pusu komutu almadı. Uygulamanın açık olduğundan emin olup tekrar deneyin.\n",
                    "Pusu did not receive the command. Make sure the app is running and try again.\n"), stderr)
            exit(1)
        }
    }
    exit(0)
}

let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)

// `kill`/`pkill` (SIGTERM) gelirse de normal çıkış yolunu izle: açık oturum geçmişe
// yazılır, assertion'lar bırakılır, kapak modu geri alınır.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    NSApp.terminate(nil)
}
terminationSource.resume()

application.run()
