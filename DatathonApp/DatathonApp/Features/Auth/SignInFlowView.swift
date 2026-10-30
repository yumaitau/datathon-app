import SwiftUI

/// Phone + SMS code sign-in, then (for a new profile) choosing a 4-digit PIN.
struct SignInFlowView: View {
    enum Mode {
        case newProfile
        case reauth(DeviceProfile)
    }

    let mode: Mode
    @Environment(AppEnvironment.self) private var env
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss

    private enum Step { case phone, code, pin, confirmPin }

    @State private var step: Step = .phone
    @State private var phone = ""
    @State private var name = ""
    @State private var code = ""
    @State private var pin = ""
    @State private var firstPin = ""
    @State private var pinMismatch = false
    @State private var busy = false
    @State private var error: String?
    @State private var auth: AuthResponse?

    private struct DemoAccount: Identifiable {
        let phone: String
        let label: String
        var id: String { phone }
    }

    private let demoAccounts = [
        DemoAccount(phone: "+61400000001", label: "Aunty Grace Walker · Elder, Saltbush Creek"),
        DemoAccount(phone: "+61400000002", label: "Uncle Tom Baker · Elder, Ironbark Ridge"),
        DemoAccount(phone: "+61400000003", label: "Jordan Miller · new member"),
        DemoAccount(phone: "+61400000004", label: "Leah Thompson · patient"),
        DemoAccount(phone: "+61400000005", label: "Sam Thompson · Leah's carer"),
    ]

    var body: some View {
        Form {
            switch step {
            case .phone: phoneStep
            case .code: codeStep
            case .pin: pinStep(title: "Choose a 4-digit PIN", binding: $pin)
            case .confirmPin: pinStep(title: "Enter the PIN again", binding: $pin)
            }
        }
        .navigationTitle(isReauth ? "Sign in again" : "Add a person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if isReauth { profiles.lock() } else { dismiss() }
                }
            }
        }
        .disabled(busy)
        .onAppear {
            if case .reauth(let p) = mode, phone.isEmpty { phone = p.phoneNumber }
        }
    }

    private var isReauth: Bool {
        if case .reauth = mode { return true }
        return false
    }

    @ViewBuilder private var phoneStep: some View {
        Section {
            TextField("Mobile number", text: $phone, prompt: Text("0400 000 000"))
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .font(.title3)
            if !isReauth {
                TextField("Your name (if you're new to MyMob)", text: $name)
                    .textContentType(.name)
            }
        } header: {
            Text("Your mobile number")
        } footer: {
            Text("We'll text you a 6-digit code. Your number is never shown to other members.")
        }

        Section {
            Button {
                Task { await sendCode() }
            } label: {
                HStack { Text("Send code"); Spacer(); if busy { ProgressView() } }
            }
            .disabled(normalizePhone(phone).count < 10)
            ErrorBanner(message: error)
        }

        if !isReauth {
            Section("Demo accounts") {
                ForEach(demoAccounts) { account in
                    Button { phone = account.phone } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: account.label)
                            Text(verbatim: account.phone).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var codeStep: some View {
        Section {
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit())
        } header: {
            Text("Enter the code sent to \(normalizePhone(phone))")
        } footer: {
            Text("Demo numbers accept 123456.")
        }
        Section {
            Button {
                Task { await verify() }
            } label: {
                HStack { Text("Verify"); Spacer(); if busy { ProgressView() } }
            }
            .disabled(code.count < 4)
            Button("Use a different number") { step = .phone; code = "" }
            ErrorBanner(message: error)
        }
    }

    private func pinStep(title: LocalizedStringKey, binding: Binding<String>) -> some View {
        Section {
            VStack(spacing: 16) {
                Text(title).font(.title3.bold())
                Text("Your PIN stops other people using this phone from opening your profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PINPad(pin: binding, failed: pinMismatch) { entered in pinEntered(entered) }
                if pinMismatch {
                    Text("PINs didn't match. Choose your PIN again.").foregroundStyle(.red).font(.callout)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
    }

    private func sendCode() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let _: OKResponse = try await env.api.post("/api/auth/otp/send", ["phoneNumber": normalizePhone(phone)])
            step = .code
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        busy = true; error = nil
        defer { busy = false }
        struct Body: Encodable { let phoneNumber: String; let code: String; let name: String? }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        do {
            let response: AuthResponse = try await env.api.post(
                "/api/auth/otp/verify",
                Body(phoneNumber: normalizePhone(phone), code: code, name: trimmedName.isEmpty ? nil : trimmedName))
            if case .reauth(let profile) = mode {
                profiles.reauthenticate(profile.id, token: response.token, user: response.user)
                await env.refresh()
            } else {
                auth = response
                step = .pin
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pinEntered(_ entered: String) {
        if step == .pin {
            firstPin = entered
            pin = ""
            pinMismatch = false
            step = .confirmPin
        } else if entered == firstPin, let auth {
            profiles.addProfile(user: auth.user, token: auth.token, pin: entered)
            dismiss()
        } else {
            pinMismatch = true
            pin = ""
            firstPin = ""
            step = .pin
        }
    }
}
