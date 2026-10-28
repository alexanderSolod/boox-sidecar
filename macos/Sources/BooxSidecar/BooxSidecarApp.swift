import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct BooxSidecarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var host = HostModel()
    var body: some Scene {
        WindowGroup("BOOX Sidecar") {
            HostView(host: host)
                .frame(minWidth: 640, minHeight: 510)
                .onAppear { NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true) }
        }.defaultSize(width: 710, height: 730)
    }
}

struct HostView: View {
    @ObservedObject var host: HostModel
    @State private var advanced = false
    @State private var confirmForget = false
    private var fpsChoices: [Int] { Array(Set([5, 15, 30, 60, host.fps])).sorted() }
    private var widthChoices: [Int] { Array(Set([930, 1240, 1860, 2480, host.maxWidth])).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "display.2").font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text("BOOX Sidecar").font(.title.bold())
                        Text("Your Mac desktop, extended onto your BOOX").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(host.developmentBrowser ? "DEVELOPMENT HTTP" : host.demo ? "DEMO" : host.capturing ? "SHARING" : "READY").font(.caption.bold()).padding(8).background(.quaternary, in: Capsule())
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if host.connectionRequested || host.connecting {
                                Button("Disconnect") { host.disconnect() }.buttonStyle(.borderedProminent).controlSize(.large)
                                if host.connecting { ProgressView().controlSize(.small) }
                            } else {
                                Button("Connect") { host.connect() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(host.token.isEmpty)
                            }
                            Spacer()
                            Text(host.wirelessEnabled ? "USB + encrypted Wi-Fi ready" : "USB / Wi-Fi").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(host.connectionMessage).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text("First time: plug in USB and approve USB debugging. After pairing, open both apps and click Connect. Your BOOX remembers this Mac.").font(.caption).foregroundStyle(.secondary)
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Picture quality") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ForEach(["Speed", "Balanced", "Sharp text"], id: \.self) { profile in Button(profile) { host.applyProfile(profile) } }
                            Spacer()
                        }
                        Text("\(host.maxWidth) px · \(host.fps) capture FPS · \(host.grayscale ? "Grayscale" : "Color") · JPEG \(Int(host.jpegQuality * 100))%")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("1240 px matches the panel's color resolution. Sharp text uses the full 2480 px black-and-white resolution. E-ink refresh speed depends on the BOOX refresh mode; capture FPS is not panel FPS.").font(.caption).foregroundStyle(.secondary)
                    }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle("Allow BOOX taps and scrolling to control this Mac", isOn: Binding(get: { host.inputEnabled }, set: { host.enableInput($0) }))
                Text(host.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Advanced controls", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Picker("Display", selection: Binding(get: { host.displayID }, set: { host.displayID = $0; host.applySettings() })) {
                                ForEach(host.displays) { display in Text("\(display.name) · \(display.width) × \(display.height)").tag(display.id) }
                            }
                            Button { host.refreshDisplays() } label: { Image(systemName: "arrow.clockwise") }
                        }
                        HStack {
                            Picker("FPS", selection: Binding(get: { host.fps }, set: { host.fps = $0; host.applySettings() })) { ForEach(fpsChoices, id: \.self) { Text("\($0)").tag($0) } }.frame(width: 150)
                            Picker("Width", selection: Binding(get: { host.maxWidth }, set: { host.maxWidth = $0; host.applySettings() })) { ForEach(widthChoices, id: \.self) { Text("\($0) px").tag($0) } }.frame(width: 180)
                            Toggle("Grayscale", isOn: Binding(get: { host.grayscale }, set: { host.grayscale = $0; host.applySettings() }))
                        }
                        HStack {
                            Text("JPEG quality")
                            Slider(value: Binding(get: { host.jpegQuality }, set: { host.jpegQuality = $0 }), in: 0.4...0.95, step: 0.01, onEditingChanged: { editing in if !editing { host.applySettings() } })
                            Text("\(Int(host.jpegQuality * 100))%").monospacedDigit().frame(width: 45)
                        }
                        HStack {
                            Button("Start capture") { host.start() }.disabled(host.capturing || host.starting || !host.serverReady)
                            Button("Stop capture") { host.stop() }.disabled(!host.capturing && !host.starting)
                            Button("Create BOOX display") { Task { await host.createExtendedDisplay() } }.disabled(host.creatingExtendedDisplay || host.demo || !host.virtualDisplay.available)
                            Button("Remove display") { host.removeExtendedDisplay() }.disabled(host.virtualDisplayID == 0 || host.creatingExtendedDisplay)
                        }
                        Text("The separate desktop uses experimental private macOS display APIs. You can also select an existing display above.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Enable encrypted Wi-Fi (port 8788)", isOn: Binding(get: { host.wirelessEnabled || host.wirelessStarting }, set: { host.enableWireless($0) })).disabled(host.browserEnabled)
                        if !host.wirelessMessage.isEmpty { Text(host.wirelessMessage).font(.caption).textSelection(.enabled) }
                        HStack {
                            Button("Pair app for USB") { host.pairBOOX(useWiFi: false) }.disabled(host.pairingDevice || host.browserEnabled)
                            Button("Pair app for Wi-Fi") { host.pairBOOX(useWiFi: true) }.disabled(host.pairingDevice || host.browserEnabled || !host.wirelessEnabled)
                            Button("Copy certificate fingerprint") { host.copyFingerprint() }.disabled(host.fingerprint.isEmpty)
                        }
                        if let address = host.wirelessAddresses.first { Text("Wi-Fi address: \(address):8788").font(.caption).textSelection(.enabled) }
                        HStack {
                            if host.browserEnabled { Button("Copy browser link") { host.copyLink() } }
                            Button("Copy pairing token") { host.copyToken() }
                            Spacer()
                            Button("Forget pairing…", role: .destructive) { confirmForget = true }
                        }
                        Text("Manual USB: adb reverse tcp:\(String(host.port)) tcp:\(String(host.port))").font(.system(.caption, design: .monospaced)).textSelection(.enabled)

                    }.padding(.top, 12)
                }
            }.padding(24)
        }
        .confirmationDialog("Forget this Mac's BOOX pairing?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget pairing", role: .destructive) { host.forgetPairing() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This stops sharing and replaces the saved credential. Previously paired devices must be paired again over USB.") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in host.refreshDisplays() }
    }
}
