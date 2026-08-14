import Foundation
import AppKit

enum MailBridgeError: LocalizedError {
    case scriptFailed(String)
    case noComposer
    case mailNotRunning
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg):
            return "AppleScript error: \(msg)"
        case .noComposer:
            return "Open a compose window in Mail first, then try again."
        case .mailNotRunning:
            return "Mail is not running. Open Mail and try again."
        case .parseError(let msg):
            return "Failed to parse Mail context: \(msg)"
        }
    }
}

final class MailBridge {
    static func executeAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: MailBridgeError.scriptFailed("Failed to create script"))
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error = error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: MailBridgeError.scriptFailed(message))
                } else {
                    continuation.resume(returning: result.stringValue ?? "")
                }
            }
        }
    }

    static func isMailRunning() async -> Bool {
        do {
            let result = try await executeAppleScript(MailScripts.checkMailRunning)
            return result.lowercased() == "true"
        } catch {
            return false
        }
    }

    /// Pull context from the currently open Mail compose window, falling
    /// back to the Accessibility reader when Mail's `outgoing messages`
    /// AppleScript collection is empty (recent macOS versions). Never
    /// blocks on Accessibility permission: if AX isn't granted, the
    /// AppleScript context is returned as-is so the UI can offer a
    /// dismissible banner instead of a permission wall.
    ///
    /// Never reads from the message list — the compose window is the source
    /// of truth.
    static func fetchComposerContext() async throws -> ComposerContext {
        guard await isMailRunning() else {
            throw MailBridgeError.mailNotRunning
        }

        let raw = try await executeAppleScript(MailScripts.fetchComposerContext)

        if raw.hasPrefix("ERROR:NO_COMPOSER") {
            throw MailBridgeError.noComposer
        }

        let context = try MailThreadParser.parseComposerContext(raw)

        // If Pass 1 (outgoing messages) found nothing but Pass 2 identified
        // a compose window by name, the AppleScript path is broken (recent
        // macOS versions). Fall back to the Accessibility reader when
        // permission is granted; otherwise return the context as-is.
        if context.recipients.isEmpty && context.currentDraft.isEmpty {
            return await enrichViaAccessibility(context: context)
        }

        return context
    }

    /// Opportunistically enrich the context via the AX reader. If AX isn't
    /// trusted or no compose window is found, the original context is
    /// returned unchanged — never throws. When AX provides a subject that
    /// differs from the AppleScript one (e.g. the window name on broken
    /// macOS), re-run the thread search with the corrected subject so the
    /// thread is populated.
    private static func enrichViaAccessibility(context: ComposerContext) async -> ComposerContext {
        guard AXPermissionChecker.isGranted() else {
            return context
        }

        guard let ax = AccessibilityReader.readComposeWindow() else {
            // AX is granted but no compose window was found — return the
            // original (possibly empty) context rather than failing.
            return context
        }

        let subject = ax.subject.isEmpty ? context.subject : ax.subject

        // Re-fetch the thread when the AX reader corrected the subject and
        // the AppleScript path didn't already find a thread (it was skipped
        // because recipients and draft were empty).
        let thread: EmailThread?
        if subject != context.subject && context.thread == nil {
            thread = await fetchThread(subject: subject)
        } else {
            thread = context.thread
        }

        return ComposerContext(
            recipients: ax.recipients,
            subject: subject,
            currentDraft: ax.draftContent,
            thread: thread,
            composeWindowFrame: context.composeWindowFrame
        )
    }

    /// Search Mail's mailboxes for messages matching `subject` and build an
    /// `EmailThread`. Returns `nil` if no messages are found.
    private static func fetchThread(subject: String) async -> EmailThread? {
        let raw = (try? await executeAppleScript(
            MailScripts.fetchThreadMessages(baseSubject: subject)
        )) ?? ""
        let messages = MailThreadParser.parseThreadMessages(raw)
        guard !messages.isEmpty else { return nil }
        return EmailThread(subject: subject, messages: messages)
    }

    /// Write the reply directly into the current Mail compose window.
    /// Falls back to the clipboard if the AppleScript insert fails.
    @MainActor
    static func insertReply(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        _ = try? await executeAppleScript(MailScripts.insertReply(text))
        activateMail()
    }

    @MainActor
    private static func activateMail() {
        if let mailApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first {
            mailApp.activate()
        }
    }
}
