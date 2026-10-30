import SwiftUI

/// Launch and lock screen: pick who is using the phone, then enter their PIN.
struct ProfileSwitcherView: View {
    @Environment(ProfileStore.self) private var profiles
    @State private var pinFor: DeviceProfile?
    @State private var addingProfile = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Who's using MyMob?")
                            .font(.largeTitle.bold())
                        Text("Each person on this phone has their own PIN. Health information is only shown to the person it belongs to and the carers they choose.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                if !profiles.profiles.isEmpty {
                    Section("People on this phone") {
                        ForEach(profiles.profiles) { profile in
                            Button { pinFor = profile } label: {
                                HStack(spacing: 14) {
                                    InitialsAvatar(initials: profile.initials)
                                    VStack(alignment: .leading) {
                                        Text(profile.name).font(.headline)
                                        if profile.needsSignIn {
                                            Text("Sign in again needed").font(.caption).foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "lock.fill").foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("Enter PIN to open"))
                        }
                    }
                }

                Section {
                    Button { addingProfile = true } label: {
                        Label("Add a person", systemImage: "person.badge.plus")
                    }
                }
            }
            .navigationTitle("MyMob")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $pinFor) { profile in
                PINEntrySheet(profile: profile)
            }
            .sheet(isPresented: $addingProfile) {
                NavigationStack { SignInFlowView(mode: .newProfile) }
            }
        }
    }
}

struct PINEntrySheet: View {
    let profile: DeviceProfile
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                InitialsAvatar(initials: profile.initials, size: 72)
                Text("Enter PIN for \(profile.name)")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                PINPad(pin: $pin, failed: failed) { entered in
                    if profiles.verifyPIN(entered, for: profile.id) {
                        profiles.unlock(profile.id)
                        dismiss()
                    } else {
                        failed = true
                        pin = ""
                    }
                }
                if failed {
                    Text("That PIN didn't match. Try again.").foregroundStyle(.red).font(.callout)
                }
                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Four-digit PIN keypad with large, labelled buttons.
struct PINPad: View {
    @Binding var pin: String
    var failed = false
    var onComplete: (String) -> Void

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .strokeBorder(failed ? Color.red : Color.secondary, lineWidth: 1.5)
                        .background(Circle().fill(i < pin.count ? Color.primary : .clear))
                        .frame(width: 16, height: 16)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("\(pin.count) of 4 digits entered"))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 14) {
                ForEach(keys, id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(height: 64)
                    } else {
                        Button {
                            tap(key)
                        } label: {
                            Group {
                                if key == "⌫" { Image(systemName: "delete.left") } else { Text(key) }
                            }
                            .font(.title)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(Color(.secondarySystemBackground), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(key == "⌫" ? Text("Delete") : Text(verbatim: key))
                    }
                }
            }
            .frame(maxWidth: 300)
        }
    }

    private func tap(_ key: String) {
        if key == "⌫" {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        guard pin.count < 4 else { return }
        pin.append(key)
        if pin.count == 4 {
            let entered = pin
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { onComplete(entered) }
        }
    }
}
