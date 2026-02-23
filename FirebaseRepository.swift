// FirebaseRepository.swift — ParentGuard iOS
// All Firestore reads and writes.  Mirrors FirebaseRepository.kt on Android.
//
// The Firestore schema is shared across both platforms:
//   families/{familyId}/children/{childId}/
//     profile/info      — DeviceProfile
//     appUsage/{date_pkg} — AppUsageRecord
//     blockedApps/{pkg}  — BlockedApp (parent writes, child reads)
//     screenTimeLimits/limits — ScreenTimeLimit (parent writes, child reads)
//     alerts/{id}        — AlertRecord

import Foundation
import FirebaseAuth
import FirebaseFirestore

final class FirebaseRepository {

    static let shared = FirebaseRepository()

    private let db   = Firestore.firestore()
    private let auth = Auth.auth()
    private let prefs = AppPreferences.shared

    private init() {}

    // ── Auth guard ────────────────────────────────────────────────────────────

    /// Every write path calls this first. Throws if unauthenticated or IDs are blank.
    private func requireAuth() throws {
        guard auth.currentUser != nil else {
            throw PGError.unauthenticated
        }
        guard !prefs.familyId.isEmpty else { throw PGError.missingFamilyId }
        guard !prefs.childId.isEmpty  else { throw PGError.missingChildId  }
    }

    // ── Paths ─────────────────────────────────────────────────────────────────

    private var childRef: DocumentReference {
        db.collection("families").document(prefs.familyId)
          .collection("children").document(prefs.childId)
    }

    // ── Upload ────────────────────────────────────────────────────────────────

    /// Upload the device profile (heartbeat — called every 15 minutes).
    func uploadDeviceProfile(_ profile: DeviceProfile) async throws {
        try requireAuth()
        let data = try Firestore.Encoder().encode(profile)
        try await childRef.collection("profile").document("info")
            .setData(data, merge: true)
    }

    /// Upload app usage records. Batched in groups of 400 (Firestore limit is 500).
    func uploadAppUsage(_ records: [AppUsageRecord]) async throws {
        guard !records.isEmpty else { return }
        try requireAuth()

        for chunk in records.chunked(into: 400) {
            let batch = db.batch()
            for record in chunk {
                let docId = "\(record.date)_\(record.bundleIdentifier.replacing(".", with: "_"))"
                let ref   = childRef.collection("appUsage").document(docId)
                let data  = try Firestore.Encoder().encode(record)
                batch.setData(data, forDocument: ref, merge: true)
            }
            try await batch.commit()
        }
    }

    /// Upload an alert (app blocked, bedtime violation, etc.).
    func uploadAlert(_ alert: AlertRecord) async throws {
        try requireAuth()
        let data = try Firestore.Encoder().encode(alert)
        try await childRef.collection("alerts").document(alert.id)
            .setData(data, merge: true)
    }

    // ── Download (parent commands) ────────────────────────────────────────────

    /// Fetch the current blocked apps list from Firestore.
    func fetchBlockedApps() async throws -> [BlockedApp] {
        try requireAuth()
        let snapshot = try await childRef.collection("blockedApps").getDocuments()
        return try snapshot.documents.compactMap {
            try $0.data(as: BlockedApp.self)
        }
    }

    /// Fetch screen time limits.
    func fetchScreenTimeLimits() async throws -> ScreenTimeLimit {
        try requireAuth()
        let doc = try await childRef.collection("screenTimeLimits").document("limits").getDocument()
        return try doc.data(as: ScreenTimeLimit.self) ?? ScreenTimeLimit()
    }

    // ── Real-time listener (parent command push) ──────────────────────────────

    /// Listen for changes to blocked apps in real time. Calls the handler whenever
    /// the parent adds or removes a blocked app from the dashboard.
    @discardableResult
    func listenForBlockedAppsChanges(
        handler: @escaping ([BlockedApp]) -> Void
    ) -> ListenerRegistration? {
        guard (try? requireAuth()) != nil else { return nil }

        return childRef.collection("blockedApps")
            .addSnapshotListener { snapshot, error in
                guard let snapshot, error == nil else { return }
                let apps = (try? snapshot.documents.compactMap {
                    try $0.data(as: BlockedApp.self)
                }) ?? []
                handler(apps)
            }
    }

    @discardableResult
    func listenForScreenTimeLimitChanges(
        handler: @escaping (ScreenTimeLimit) -> Void
    ) -> ListenerRegistration? {
        guard (try? requireAuth()) != nil else { return nil }

        return childRef.collection("screenTimeLimits").document("limits")
            .addSnapshotListener { snapshot, error in
                guard let snapshot, error == nil else { return }
                if let limit = try? snapshot.data(as: ScreenTimeLimit.self) {
                    handler(limit)
                }
            }
    }

    // ── Errors ────────────────────────────────────────────────────────────────

    enum PGError: LocalizedError {
        case unauthenticated
        case missingFamilyId
        case missingChildId

        var errorDescription: String? {
            switch self {
            case .unauthenticated: return "No authenticated Firebase user — cannot upload."
            case .missingFamilyId: return "familyId is blank — complete setup first."
            case .missingChildId:  return "childId is blank — should not happen."
            }
        }
    }
}

// ─── Array chunking helper ────────────────────────────────────────────────────

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// ─── String.replacing helper (backport for < iOS 16.0 regex syntax) ──────────

extension String {
    func replacing(_ char: Character, with replacement: String) -> String {
        self.replacingOccurrences(of: String(char), with: replacement)
    }
}
