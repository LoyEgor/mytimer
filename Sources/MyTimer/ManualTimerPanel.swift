import AppKit

final class ManualTimerPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let field = NSTextField(string: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let onAdd: (Date) -> Void

    init(onAdd: @escaping (Date) -> Void) {
        self.onAdd = onAdd
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 155),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Add Timer"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let prompt = NSTextField(labelWithString: "Enter minutes or a time such as 17:30")
        prompt.frame = NSRect(x: 24, y: 105, width: 292, height: 20)
        field.frame = NSRect(x: 24, y: 70, width: 292, height: 26)
        field.placeholderString = "90 or 17:30"
        errorLabel.frame = NSRect(x: 24, y: 47, width: 292, height: 18)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.frame = NSRect(x: 160, y: 12, width: 75, height: 28)
        let add = NSButton(title: "Add", target: self, action: #selector(addPressed))
        add.frame = NSRect(x: 241, y: 12, width: 75, height: 28)
        add.keyEquivalent = "\r"
        [prompt, field, errorLabel, cancel, add].forEach { panel.contentView?.addSubview($0) }
    }

    func show() {
        field.stringValue = ""
        errorLabel.stringValue = ""
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    @objc private func cancelPressed() { panel.close() }

    @objc private func addPressed() {
        guard let date = TimeFormat.parseManualEntry(field.stringValue) else {
            errorLabel.stringValue = "Enter positive minutes or a valid HH:MM time."
            return
        }
        onAdd(date)
        panel.close()
    }
}
