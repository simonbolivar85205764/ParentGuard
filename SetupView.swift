// SetupView.swift — ParentGuard iOS
// 4-step parent-run onboarding wizard.

import SwiftUI
import FamilyControls

struct SetupView: View {
    var onComplete: () -> Void

    @EnvironmentObject var familyManager: FamilyControlsManager
    @State private var step            = 1
    @State private var familyCode      = ""
    @State private var childName       = ""
    @State private var isAuthorizing   = false
    @State private var errorText: String?

    private let totalSteps = 4

    var body: some View {
        ZStack {
            Color(hex: "#07090F").ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ──────────────────────────────────────────────────
                headerBar

                // ── Progress ────────────────────────────────────────────────
                ProgressView(value: Double(step), total: Double(totalSteps))
                    .tint(Color(hex: "#6366F1"))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                // ── Step content ─────────────────────────────────────────────
                ScrollView {
                    VStack(spacing: 28) {
                        switch step {
                        case 1: stepFamily
                        case 2: stepChildName
                        case 3: stepFamilyControls
                        case 4: stepNotifications
                        default: EmptyView()
                        }

                        if let err = errorText {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#EF4444"))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        // ── Navigation buttons ───────────────────────────────
                        HStack(spacing: 12) {
                            if step > 1 {
                                Button("← Back") { withAnimation { step -= 1 } }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                            Button(step == totalSteps ? "Finish Setup" : "Continue →") {
                                advance()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(isAuthorizing)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                    .padding(.top, 32)
                }
            }
        }
    }

    // ── Step 1: Family Code ────────────────────────────────────────────────────

    private var stepFamily: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepIcon("🔗")
            stepTitle("Link to Family")
            stepBody("Enter the Family Code from the parent's ParentGuard dashboard. This links this device to your family's monitoring account.")

            PGTextField("Family Code e.g. PG-7X4K2M", text: $familyCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

            infoBox(
                "The Family Code is your parent Firebase UID. Find it in the parent dashboard under Settings → Link Device."
            )
        }
        .padding(.horizontal, 24)
    }

    // ── Step 2: Child Name ────────────────────────────────────────────────────

    private var stepChildName: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepIcon("👤")
            stepTitle("Child's Name")
            stepBody("Enter the first name of the child who will use this iPhone. This is shown in the parent dashboard.")

            PGTextField("e.g. Emma", text: $childName)
                .textInputAutocapitalization(.words)
        }
        .padding(.horizontal, 24)
    }

    // ── Step 3: FamilyControls Authorization ─────────────────────────────────

    private var stepFamilyControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepIcon("🛡️")
            stepTitle("Allow Screen Time Access")
            stepBody("ParentGuard needs Screen Time permission to monitor app usage and enforce limits. iOS will show a system prompt — tap **Allow** to continue.")

            VStack(alignment: .leading, spacing: 10) {
                featureRow("✅", "Monitor time spent in apps")
                featureRow("✅", "Block specific apps or categories")
                featureRow("✅", "Enforce daily screen time limits")
                featureRow("✅", "Enforce bedtime restrictions")
                featureRow("❌", "Read messages or call history (iOS prevents this for privacy)")
            }
            .padding(16)
            .background(Color(hex: "#0C1220"))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#1A2640")))
            .cornerRadius(10)

            if familyManager.authorizationStatus == .approved {
                Label("Screen Time access granted ✓", systemImage: "checkmark.circle.fill")
                    .foregroundColor(Color(hex: "#10B981"))
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Button {
                    isAuthorizing = true
                    Task {
                        await familyManager.requestAuthorization()
                        isAuthorizing = false
                    }
                } label: {
                    if isAuthorizing {
                        ProgressView().tint(.white)
                    } else {
                        Text("Grant Screen Time Access")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 24)
    }

    // ── Step 4: Notifications ─────────────────────────────────────────────────

    private var stepNotifications: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepIcon("🔔")
            stepTitle("Allow Notifications")
            stepBody("ParentGuard shows the child a warning when screen time is almost up, and sends the parent an alert when limits are enforced.")

            infoBox("iOS will show a permission prompt. Tap **Allow** to enable notifications.")

            Button {
                Task {
                    await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .badge])
                }
            } label: {
                Text("Enable Notifications")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 24)
    }

    // ── Navigation logic ──────────────────────────────────────────────────────

    private func advance() {
        errorText = nil

        switch step {
        case 1:
            let trimmed = familyCode.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 4 else {
                errorText = "Please enter a valid Family Code."
                return
            }
            AppPreferences.shared.familyId = trimmed

        case 2:
            let trimmed = childName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                errorText = "Please enter the child's name."
                return
            }
            AppPreferences.shared.childName = trimmed

        case 3:
            guard familyManager.authorizationStatus == .approved else {
                errorText = "Screen Time access is required. Please tap 'Grant Screen Time Access' above."
                return
            }

        case 4:
            // Final step — mark setup complete and start monitoring
            AppPreferences.shared.isSetupComplete = true
            familyManager.startMonitoring()
            familyManager.startListeningForParentCommands()
            NotificationCenter.default.post(name: .setupDidComplete, object: nil)
            onComplete()
            return

        default: break
        }

        withAnimation { step += 1 }
    }

    // ── Sub-views ─────────────────────────────────────────────────────────────

    private var headerBar: some View {
        HStack {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [Color(hex: "#6366F1"), Color(hex: "#8B5CF6")],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                    Text("🛡️").font(.system(size: 18))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("ParentGuard").font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("iOS Setup").font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "#4A5C7A"))
                }
            }
            Spacer()
            Text("Step \(step) of \(totalSteps)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "#4A5C7A"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(hex: "#0C1220"))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(hex: "#1A2640")),
                 alignment: .bottom)
    }

    private func stepIcon(_ emoji: String) -> some View {
        Text(emoji).font(.system(size: 44))
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundColor(.white)
    }

    private func stepBody(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 14))
            .foregroundColor(Color(hex: "#7A90B3"))
            .lineSpacing(4)
    }

    private func featureRow(_ emoji: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(emoji).font(.system(size: 14))
            Text(text).font(.system(size: 13)).foregroundColor(Color(hex: "#7A90B3"))
        }
    }

    private func infoBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("ℹ️").font(.system(size: 13))
            Text(LocalizedStringKey(text))
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#7A90B3"))
                .lineSpacing(3)
        }
        .padding(12)
        .background(Color(hex: "#0C1220"))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#1A2640")))
        .cornerRadius(8)
    }
}
