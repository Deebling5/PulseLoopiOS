import SwiftUI
import AuthenticationServices

/// Strava detail screen. A master toggle gates uploading workouts to Strava; enabling it runs the
/// OAuth connect flow when no account is linked (cancel/failure → revert the toggle). An upload-mode
/// selector (manual per-workout vs automatic on finish) appears once connected, and a destructive
/// disconnect action revokes PulseLoop's access. When the build ships without StravaSecrets.plist
/// the whole screen degrades to an explanatory "not configured" state (mirrors the Apple Health
/// availability gate).
struct StravaSettingsView: View {
    @State private var auth = StravaAuthService.shared
    @State private var store = StravaPrefsStore.shared
    /// Confirmation before revoking Strava access.
    @State private var showDisconnectDialog = false
    /// Set when the connect flow fails for a reason other than the user cancelling.
    @State private var connectError: String?

    private var masterOn: Bool { store.prefs.masterEnabled }

    private var isConfigured: Bool {
        if case .missingCredentials = auth.state { return false }
        return true
    }

    private var isConnecting: Bool { auth.state == .connecting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatusCopy(title: status.title, body: status.body)

                masterGroup

                if let connectError {
                    Text(connectError)
                        .font(.caption)
                        .foregroundStyle(PulseColors.danger)
                        .padding(.horizontal, 4)
                }

                if masterOn && auth.isConnected {
                    modeGroup
                }

                dangerGroup
                    .disabled(!auth.isConnected)
                    .opacity(auth.isConnected ? 1 : 0.5)
            }
            .padding()
        }
        .background(PulseColors.background)
        .pageChrome("Strava")
        .confirmationDialog(
            "Disconnect from Strava?",
            isPresented: $showDisconnectDialog,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await auth.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PulseLoop stops uploading and revokes its access to your Strava account. "
                + "Workouts already uploaded stay on Strava.")
        }
    }

    // MARK: - Sections

    @ViewBuilder private var masterGroup: some View {
        SettingsGroup(
            footer: "When on, PulseLoop can push finished workouts to your Strava account. "
                + "Turning it off stops uploads — your Strava connection is kept."
        ) {
            FormToggleRow(title: "Upload to Strava", isOn: Binding(
                get: { store.prefs.masterEnabled },
                set: { setMaster($0) }
            ))
        }
        .disabled(!isConfigured || isConnecting)
        .opacity(isConfigured ? 1 : 0.5)
    }

    @ViewBuilder private var modeGroup: some View {
        SettingsGroup(
            header: "Upload mode",
            footer: "Automatic uploads new workouts as you finish them. Only workouts recorded "
                + "after enabling are uploaded. Manual lets you push each workout from its detail page."
        ) {
            FormMenuRow(title: "Upload mode", value: modeLabel(store.prefs.uploadMode)) {
                Picker("Upload mode", selection: modeBinding) {
                    Text("Manual").tag(StravaUploadMode.manual)
                    Text("Automatic").tag(StravaUploadMode.automatic)
                }
            }
        }
    }

    @ViewBuilder private var dangerGroup: some View {
        SettingsGroup(footer: "Workouts already uploaded stay on Strava.") {
            Button {
                showDisconnectDialog = true
            } label: {
                HStack {
                    Text("Disconnect from Strava")
                        .font(PulseFont.body)
                        .foregroundStyle(PulseColors.danger)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Status copy

    private var status: (title: String, body: String) {
        switch auth.state {
        case .missingCredentials:
            return ("Not configured", "Strava isn't configured in this build. Add StravaSecrets.plist "
                + "with your API application's client ID and secret.")
        case .disconnected:
            return ("Not connected", "Connect your Strava account to push workouts from PulseLoop.")
        case .connecting:
            return ("Connecting…", "Finish signing in to Strava to link your account.")
        case let .connected(athleteName):
            var text = "Connected as \(athleteName)."
            if let last = store.state.lastUploadAt {
                if let summary = store.state.lastUploadSummary {
                    text += " Last upload \(Self.relative(last)) — \(summary)."
                } else {
                    text += " Last upload \(Self.relative(last))."
                }
            }
            return ("Connected", text)
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func modeLabel(_ mode: StravaUploadMode) -> String {
        switch mode {
        case .manual:    return "Manual"
        case .automatic: return "Automatic"
        }
    }

    // MARK: - Bindings & actions

    /// Master toggle. Turning ON with no linked account runs the OAuth connect flow and only latches
    /// the toggle once it succeeds (mirrors the Apple Health authorization idiom); a user-cancelled
    /// sign-in reverts silently, any other failure reverts and surfaces the error. If tokens survive
    /// from a previous session the toggle just latches on. Turning OFF keeps the connection.
    private func setMaster(_ on: Bool) {
        guard on else {
            store.prefs.masterEnabled = false
            return
        }
        connectError = nil
        if auth.isConnected {
            store.prefs.masterEnabled = true
            return
        }
        Task {
            do {
                try await auth.connect()
                store.prefs.masterEnabled = true
            } catch {
                store.prefs.masterEnabled = false
                if !Self.isUserCancellation(error) {
                    connectError = error.localizedDescription
                }
            }
        }
    }

    /// Switching TO automatic stamps both upload watermarks to "now" so pre-existing workouts are
    /// treated as already handled — only workouts finished after this moment auto-upload.
    private var modeBinding: Binding<StravaUploadMode> {
        Binding(
            get: { store.prefs.uploadMode },
            set: { newMode in
                if newMode == .automatic && store.prefs.uploadMode != .automatic {
                    StravaPrefsStore.shared.stampWatermarks(to: Date())
                }
                store.prefs.uploadMode = newMode
            }
        )
    }

    /// The user dismissing the OAuth sheet isn't an error worth showing.
    private static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == ASWebAuthenticationSessionError.errorDomain
            && ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }
}
