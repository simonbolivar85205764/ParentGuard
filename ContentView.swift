// ContentView.swift — ParentGuard iOS
// Main tab-bar navigation and all dashboard sub-views.

import SwiftUI
import FamilyControls
import DeviceActivity
import ManagedSettings

// ─── Tab navigation ────────────────────────────────────────────────────────────

struct ContentView: View {
    @EnvironmentObject var familyManager: FamilyControlsManager
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Overview",  systemImage: "chart.bar.fill")  }
                .tag(0)

            AppUsageView()
                .tabItem { Label("Usage",     systemImage: "clock.fill")      }
                .tag(1)

            AppBlockingView()
                .tabItem { Label("Blocking",  systemImage: "nosign")          }
                .tag(2)

            AlertsView()
                .tabItem { Label("Alerts",    systemImage: "bell.badge.fill") }
                .tag(3)
        }
        .accentColor(Color(hex: "#6366F1"))
        .preferredColorScheme(.dark)
        .onAppear {
            // Sync with Firestore when the app opens
            Task {
                await familyManager.syncAndApplyBlockedApps()
            }
        }
    }
}

// ─── Dashboard / Overview ─────────────────────────────────────────────────────

struct DashboardView: View {
    @EnvironmentObject var familyManager: FamilyControlsManager

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#07090F").ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {

                        // Status card
                        StatusCard(familyManager: familyManager)

                        // Quick stats grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            StatCard(label: "Monitoring",
                                     value: familyManager.isMonitoringActive ? "Active" : "Paused",
                                     sub: "Screen Time",
                                     accent: familyManager.isMonitoringActive ? "#10B981" : "#F59E0B",
                                     icon: "🛡️")
                            StatCard(label: "Apps Blocked",
                                     value: "\(familyManager.blockedApps.count)",
                                     sub: "by parent",
                                     accent: "#EF4444",
                                     icon: "🚫")
                            StatCard(label: "Daily Limit",
                                     value: "\(familyManager.screenTimeLimit.dailyLimitMinutes)m",
                                     sub: "screen time",
                                     accent: "#F59E0B",
                                     icon: "⏱")
                            StatCard(label: "Bedtime",
                                     value: familyManager.screenTimeLimit.bedtimeStart,
                                     sub: "→ \(familyManager.screenTimeLimit.bedtimeEnd)",
                                     accent: "#6366F1",
                                     icon: "🌙")
                        }
                        .padding(.horizontal, 16)

                        // iOS capability notice
                        PlatformCapabilitiesCard()

                        Spacer(minLength: 20)
                    }
                    .padding(.top, 16)
                }
            }
            .navigationTitle("ParentGuard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await familyManager.syncAndApplyBlockedApps() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(Color(hex: "#6366F1"))
                    }
                }
            }
        }
    }
}

// ─── App Usage View ───────────────────────────────────────────────────────────

struct AppUsageView: View {
    @EnvironmentObject var familyManager: FamilyControlsManager

    // DeviceActivityReport is shown using Apple's official DeviceActivityReport view
    // It respects user privacy — bundle IDs are opaque tokens, not readable strings.
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#07090F").ignoresSafeArea()
                VStack(spacing: 0) {
                    // Screen time limit summary
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Daily Limit")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color(hex: "#4A5C7A"))
                            Text("\(familyManager.screenTimeLimit.dailyLimitMinutes) minutes")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Bedtime")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color(hex: "#4A5C7A"))
                            Text("\(familyManager.screenTimeLimit.bedtimeStart) – \(familyManager.screenTimeLimit.bedtimeEnd)")
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(hex: "#6366F1"))
                        }
                    }
                    .padding(20)
                    .background(Color(hex: "#0C1220"))
                    .overlay(Rectangle().frame(height: 1).foregroundColor(Color(hex: "#1A2640")),
                             alignment: .bottom)

                    // Apple's DeviceActivityReport SwiftUI view
                    // This renders usage data in a privacy-preserving way.
                    // Context token must match what you configured in DeviceActivitySchedule.
                    if familyManager.isMonitoringActive {
                        DeviceActivityReport(.init("parentguard.daily"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "Monitoring Not Active",
                            systemImage: "clock.badge.xmark",
                            description: Text("Complete setup and grant Screen Time access to see usage data.")
                        )
                        .foregroundColor(Color(hex: "#4A5C7A"))
                    }
                }
            }
            .navigationTitle("App Usage")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// ─── App Blocking View ────────────────────────────────────────────────────────

struct AppBlockingView: View {
    @EnvironmentObject var familyManager: FamilyControlsManager
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#07090F").ignoresSafeArea()
                List {
                    // ── Current selection ───────────────────────────────────
                    Section {
                        if familyManager.appSelection.applicationTokens.isEmpty &&
                           familyManager.appSelection.categoryTokens.isEmpty {
                            Text("No apps blocked. Tap 'Choose Apps' to select apps to restrict.")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#4A5C7A"))
                                .padding(.vertical, 8)
                        } else {
                            // Show a summary — Apple doesn't let us enumerate specific app names
                            // from tokens for privacy reasons.
                            HStack {
                                Image(systemName: "nosign")
                                    .foregroundColor(Color(hex: "#EF4444"))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(familyManager.appSelection.applicationTokens.count) app(s) blocked")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("\(familyManager.appSelection.categoryTokens.count) category(ies) blocked")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: "#7A90B3"))
                                }
                                Spacer()
                                Button("Remove") {
                                    familyManager.appSelection = FamilyActivitySelection()
                                    familyManager.removeAllBlocks()
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(hex: "#EF4444"))
                            }
                        }
                    } header: {
                        Text("Blocked Apps").font(.system(size: 11, design: .monospaced))
                    }

                    // ── Select button ─────────────────────────────────────
                    Section {
                        Button {
                            showPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(Color(hex: "#6366F1"))
                                Text("Choose Apps to Block")
                                    .foregroundColor(Color(hex: "#6366F1"))
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }

                        if !familyManager.appSelection.applicationTokens.isEmpty ||
                           !familyManager.appSelection.categoryTokens.isEmpty {
                            Button {
                                familyManager.applyBlock()
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundColor(Color(hex: "#10B981"))
                                    Text("Apply Restrictions")
                                        .foregroundColor(Color(hex: "#10B981"))
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                        }
                    }

                    // ── Privacy note ──────────────────────────────────────
                    Section {
                        Text("iOS app tokens are privacy-preserving — the system does not expose app bundle IDs to third-party apps. Selected apps appear as opaque tokens. The block is enforced by iOS's ManagedSettings framework, which is operated by Apple directly.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#4A5C7A"))
                    } header: {
                        Text("Privacy Note").font(.system(size: 11, design: .monospaced))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color(hex: "#07090F"))
            }
            .navigationTitle("App Blocking")
            .navigationBarTitleDisplayMode(.inline)
            // FamilyActivityPicker: Apple's system UI for selecting apps to restrict
            .familyActivityPicker(
                isPresented: $showPicker,
                selection:   $familyManager.appSelection
            )
        }
    }
}

// ─── Alerts View ──────────────────────────────────────────────────────────────

struct AlertsView: View {
    @EnvironmentObject var familyManager: FamilyControlsManager
    @State private var alerts: [AlertRecord] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#07090F").ignoresSafeArea()
                if alerts.isEmpty {
                    ContentUnavailableView(
                        "No Alerts Yet",
                        systemImage: "bell.slash",
                        description: Text("Alerts will appear here when screen time limits are reached or apps are blocked.")
                    )
                    .foregroundColor(Color(hex: "#4A5C7A"))
                } else {
                    List(alerts) { alert in
                        AlertRow(alert: alert)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(hex: "#07090F"))
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // In production: query Firestore for recent alerts
                alerts = sampleAlerts
            }
        }
    }

    private var sampleAlerts: [AlertRecord] {
        [
            AlertRecord(type: .screenTimeLimitHit,
                        message: "Daily screen time limit reached (120 min)",
                        timestamp: .init(date: Date().addingTimeInterval(-3600))),
            AlertRecord(type: .appBlocked,
                        message: "Tried to open a blocked app",
                        timestamp: .init(date: Date().addingTimeInterval(-7200))),
            AlertRecord(type: .bedtimeViolation,
                        message: "Device used after bedtime (9:00 PM)",
                        timestamp: .init(date: Date().addingTimeInterval(-86400))),
        ]
    }
}

struct AlertRow: View {
    let alert: AlertRecord

    var body: some View {
        HStack(spacing: 14) {
            Text(alertIcon(alert.type))
                .font(.system(size: 22))
                .frame(width: 36, height: 36)
                .background(alertBg(alert.type))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(relativeTime(alert.timestamp.dateValue()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#4A5C7A"))
            }
        }
        .padding(.vertical, 8)
        .listRowBackground(Color(hex: "#0C1220"))
    }

    private func alertIcon(_ type: AlertRecord.AlertType) -> String {
        switch type {
        case .appBlocked:          return "🚫"
        case .screenTimeLimitHit:  return "⏱"
        case .bedtimeViolation:    return "🌙"
        case .usageThreshold:      return "⚠️"
        }
    }

    private func alertBg(_ type: AlertRecord.AlertType) -> Color {
        switch type {
        case .appBlocked:          return Color(hex: "#EF4444").opacity(0.15)
        case .screenTimeLimitHit:  return Color(hex: "#F59E0B").opacity(0.15)
        case .bedtimeViolation:    return Color(hex: "#6366F1").opacity(0.15)
        case .usageThreshold:      return Color(hex: "#EC4899").opacity(0.15)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter       = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// ─── Shared UI components ──────────────────────────────────────────────────────

struct StatusCard: View {
    let familyManager: FamilyControlsManager

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(familyManager.isMonitoringActive
                          ? Color(hex: "#10B981").opacity(0.15)
                          : Color(hex: "#F59E0B").opacity(0.15))
                    .frame(width: 48, height: 48)
                Text(familyManager.isMonitoringActive ? "🛡️" : "⚠️")
                    .font(.system(size: 24))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(familyManager.isMonitoringActive ? "Monitoring Active" : "Setup Required")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Text(familyManager.isMonitoringActive
                     ? "Screen Time controls are enforced"
                     : "Complete setup to enable monitoring")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#7A90B3"))
            }
            Spacer()
            Circle()
                .fill(familyManager.isMonitoringActive
                      ? Color(hex: "#10B981")
                      : Color(hex: "#F59E0B"))
                .frame(width: 8, height: 8)
        }
        .padding(16)
        .background(Color(hex: "#0C1220"))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: "#1A2640")))
        .cornerRadius(14)
        .padding(.horizontal, 16)
    }
}

struct StatCard: View {
    let label: String
    let value: String
    let sub:   String
    let accent: String
    let icon:  String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#4A5C7A"))
                    .textCase(.uppercase)
                Spacer()
                Text(icon).font(.system(size: 16)).opacity(0.3)
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(sub)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#4A5C7A"))
        }
        .padding(16)
        .background(Color(hex: "#0C1220"))
        .overlay(
            VStack {
                Rectangle()
                    .fill(Color(hex: accent))
                    .frame(height: 2)
                Spacer()
            }
            .cornerRadius(12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#1A2640")))
        .cornerRadius(12)
    }
}

struct PlatformCapabilitiesCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iOS Monitoring Capabilities")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)

            capRow("✅", "App usage time by category", available: true)
            capRow("✅", "Block specific apps & categories", available: true)
            capRow("✅", "Daily screen time limit",    available: true)
            capRow("✅", "Bedtime enforcement",        available: true)
            capRow("✅", "Push alerts to parent",     available: true)
            capRow("❌", "SMS / iMessage content",    available: false)
            capRow("❌", "WhatsApp / Telegram messages", available: false)
            capRow("❌", "Call log",                  available: false)

            Text("iOS sandboxing prevents third-party apps from reading messages or call history. Use Android for full message monitoring.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#4A5C7A"))
                .lineSpacing(3)
        }
        .padding(16)
        .background(Color(hex: "#0C1220"))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#1A2640")))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }

    private func capRow(_ emoji: String, _ label: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Text(emoji).font(.system(size: 13))
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(available ? Color(hex: "#7A90B3") : Color(hex: "#4A5C7A"))
        }
    }
}

// ─── Button styles ─────────────────────────────────────────────────────────────

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(hex: "#6366F1").opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundColor(.white)
            .font(.system(size: 14, weight: .semibold))
            .cornerRadius(10)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(hex: "#1A2640").opacity(configuration.isPressed ? 0.6 : 1))
            .foregroundColor(Color(hex: "#7A90B3"))
            .font(.system(size: 14, weight: .semibold))
            .cornerRadius(10)
    }
}

struct PGTextField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .padding(12)
            .background(Color(hex: "#0C1220"))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#1A2640")))
            .cornerRadius(8)
            .foregroundColor(.white)
            .font(.system(size: 14))
    }
}

// ─── Color from hex ───────────────────────────────────────────────────────────

extension Color {
    init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
