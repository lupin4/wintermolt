// Copyright The Fantastic Planet - By David Clabaugh
//
// wintermolt-menubar — macOS menu bar sidecar
//
// Runs as a subprocess of the Wintermolt Zig binary. Communicates via
// JSON lines over stdin/stdout. Displays a status icon in the macOS
// menu bar with options for quick chat, status display, and quit.
//
// Build: cd menubar && swift build -c release
// Binary: .build/release/wintermolt-menubar

import AppKit
import Foundation

// MARK: - JSON Protocol Types

struct StatusMessage: Codable {
    let type: String
    let model: String?
    let backend: String?
    let tokens: Int?
}

struct NotifyMessage: Codable {
    let type: String
    let title: String?
    let body: String?
}

struct IconMessage: Codable {
    let type: String
    let state: String?
}

struct ResponseMessage: Codable {
    let type: String
    let text: String?
}

struct TokenMessage: Codable {
    let type: String
    let text: String?
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!

    // State
    var currentModel = "claude"
    var currentBackend = "claude"
    var currentTokens = 0
    var lastResponse = ""
    var isWorking = false

    // Menu items
    var statusMenuItem: NSMenuItem!
    var responseMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "W"
        statusItem.button?.toolTip = "Wintermolt AI Assistant"

        // Build menu
        statusMenu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Wintermolt — idle", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        statusMenu.addItem(statusMenuItem)

        statusMenu.addItem(NSMenuItem.separator())

        // Quick prompt
        let promptItem = NSMenuItem(title: "Quick Prompt…", action: #selector(showPrompt), keyEquivalent: "p")
        promptItem.target = self
        statusMenu.addItem(promptItem)

        // New chat
        let newChatItem = NSMenuItem(title: "New Chat", action: #selector(newChat), keyEquivalent: "n")
        newChatItem.target = self
        statusMenu.addItem(newChatItem)

        statusMenu.addItem(NSMenuItem.separator())

        // Last response (truncated)
        responseMenuItem = NSMenuItem(title: "No response yet", action: nil, keyEquivalent: "")
        responseMenuItem.isEnabled = false
        statusMenu.addItem(responseMenuItem)

        statusMenu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem.menu = statusMenu

        // Start reading stdin in background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.readStdinLoop()
        }
    }

    // MARK: - Stdin Reader

    func readStdinLoop() {
        let handle = FileHandle.standardInput
        while true {
            guard let data = try? handle.availableData, !data.isEmpty else {
                // Parent process closed stdin — exit
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }

            guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                continue
            }

            // Handle multiple JSON lines in one read
            for jsonLine in line.components(separatedBy: "\n") {
                let trimmed = jsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                handleIncoming(trimmed)
            }
        }
    }

    func handleIncoming(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        // Determine message type
        if let msg = try? JSONDecoder().decode(StatusMessage.self, from: data), msg.type == "status" {
            DispatchQueue.main.async { [weak self] in
                self?.currentModel = msg.model ?? "unknown"
                self?.currentBackend = msg.backend ?? "unknown"
                self?.currentTokens = msg.tokens ?? 0
                self?.updateStatusDisplay()
            }
        } else if let msg = try? JSONDecoder().decode(IconMessage.self, from: data), msg.type == "set_icon" {
            DispatchQueue.main.async { [weak self] in
                self?.updateIcon(state: msg.state ?? "idle")
            }
        } else if let msg = try? JSONDecoder().decode(NotifyMessage.self, from: data), msg.type == "notify" {
            DispatchQueue.main.async {
                self.showNotification(title: msg.title ?? "Wintermolt", body: msg.body ?? "")
            }
        } else if let msg = try? JSONDecoder().decode(ResponseMessage.self, from: data), msg.type == "response" {
            DispatchQueue.main.async { [weak self] in
                self?.lastResponse = msg.text ?? ""
                self?.updateResponseDisplay()
            }
        } else if let msg = try? JSONDecoder().decode(TokenMessage.self, from: data), msg.type == "token" {
            // Streaming token — append to last response
            DispatchQueue.main.async { [weak self] in
                self?.lastResponse += msg.text ?? ""
                self?.updateResponseDisplay()
            }
        }
    }

    // MARK: - UI Updates

    func updateStatusDisplay() {
        let tokenStr = currentTokens > 0 ? " (\(currentTokens) tokens)" : ""
        statusMenuItem.title = "Wintermolt — \(currentBackend)/\(currentModel)\(tokenStr)"
    }

    func updateIcon(state: String) {
        isWorking = state == "working"
        switch state {
        case "working":
            statusItem.button?.title = "W⚡"
        case "error":
            statusItem.button?.title = "W⚠"
        default:
            statusItem.button?.title = "W"
        }
    }

    func updateResponseDisplay() {
        let maxLen = 80
        let display = lastResponse.count > maxLen
            ? String(lastResponse.prefix(maxLen)) + "…"
            : lastResponse
        responseMenuItem.title = display.isEmpty ? "No response yet" : display
    }

    func showNotification(title: String, body: String) {
        let center = NSUserNotificationCenter.default
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        center.deliver(notification)
    }

    // MARK: - Actions

    @objc func showPrompt() {
        let alert = NSAlert()
        alert.messageText = "Quick Prompt"
        alert.informativeText = "Enter your prompt for Wintermolt:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        input.placeholderString = "Ask me anything..."
        alert.accessoryView = input

        // Reset response for new prompt
        lastResponse = ""
        updateResponseDisplay()

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                sendMessage(text)
            }
        }
    }

    @objc func newChat() {
        sendCommand("/clear")
        lastResponse = ""
        updateResponseDisplay()
    }

    @objc func quitApp() {
        // Tell Zig side we're quitting
        sendQuit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Stdout Writer (to Zig)

    func sendMessage(_ text: String) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let json = "{\"type\":\"message\",\"text\":\"\(escaped)\"}\n"
        writeStdout(json)
    }

    func sendCommand(_ cmd: String) {
        let json = "{\"type\":\"command\",\"cmd\":\"\(cmd)\"}\n"
        writeStdout(json)
    }

    func sendQuit() {
        writeStdout("{\"type\":\"quit\"}\n")
    }

    func writeStdout(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
