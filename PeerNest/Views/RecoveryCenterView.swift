//
//  RecoveryCenterView.swift
//  PeerNest
//

import AppKit
import SwiftUI

struct RecoveryCenterView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case pending = "Pending"
        case conflicts = "Conflicts"
        case trash = "Trash"
        case versions = "Versions"
        case storage = "Storage"
        var id: Self { self }
    }

    @Bindable var appState: AppState
    @State private var tab: Tab = .pending
    @State private var permanentDeletion: TrashRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Picker("Recovery view", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Group {
                switch tab {
                case .pending: pendingView
                case .conflicts: conflictsView
                case .trash: trashView
                case .versions: versionsView
                case .storage: storageView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(28)
        .confirmationDialog(
            "Delete this recovery item permanently?",
            isPresented: Binding(get: { permanentDeletion != nil }, set: { if !$0 { permanentDeletion = nil } })
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let permanentDeletion { appState.permanentlyDeleteTrashRecord(permanentDeletion) }
                permanentDeletion = nil
            }
            Button("Cancel", role: .cancel) { permanentDeletion = nil }
        } message: {
            Text("This removes the stored content. Residual copies may remain in filesystem snapshots or backups.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Sync & Recovery").font(.largeTitle).fontWeight(.semibold)
                Label(healthTitle, systemImage: healthIcon)
                    .foregroundStyle(healthColor)
            }
            Spacer()
            if appState.reconciliationProgress.state == .failed || appState.reconciliationProgress.state == .paused {
                Button("Retry Reconciliation") { appState.retryReconciliation() }
            } else if [.exchangingState, .comparing, .transferring, .resolvingConflicts, .verifying]
                .contains(appState.reconciliationProgress.state) {
                Button("Pause") { appState.cancelReconciliation() }
            }
        }
    }

    private var pendingView: some View {
        recoveryList(emptyTitle: "No Pending Operations", emptyIcon: "checkmark.circle") {
            ForEach(appState.journalOperations.filter { !$0.state.isTerminal }) { operation in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(operation.operationType.rawValue, systemImage: operation.isDestructive ? "trash" : "doc")
                        Text(operation.relativeSourcePath).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Text(operation.state.rawValue).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Queued \(operation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("Retry \(operation.retryCount)")
                        Text(operation.operationID.uuidString.prefix(8)).textSelection(.enabled)
                        Spacer()
                        if operation.state == .retryScheduled || operation.state == .permanentlyFailed {
                            Button("Retry") { appState.retryJournalOperation(operation) }
                        }
                        Button("Copy ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(operation.operationID.uuidString, forType: .string) }
                        Button("Reveal") { appState.revealJournalOperation(operation) }
                        if !operation.isDestructive && [.queued, .waitingForPeer, .retryScheduled].contains(operation.state) {
                            Button("Cancel") { appState.cancelJournalOperation(operation) }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
        }
    }

    private var conflictsView: some View {
        recoveryList(emptyTitle: "No Conflicts", emptyIcon: "checkmark.circle") {
            ForEach(appState.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(conflict.conflictType.rawValue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(conflict.resolutionState == .unresolved ? .orange : .secondary)
                        Text(conflict.relativePath).fontWeight(.medium)
                        Spacer()
                        Text(conflict.resolutionState.rawValue).foregroundStyle(.secondary)
                    }
                    Text("Detected \(conflict.detectedAt.formatted(date: .abbreviated, time: .shortened)) · \(conflict.diagnosticID)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if conflict.resolutionState == .unresolved {
                        HStack {
                            Button("Keep Both") { appState.resolveConflict(conflict, as: .keepBoth) }
                            Button("Keep Local") { appState.resolveConflict(conflict, as: .keptLocal) }
                            Button("Keep Remote") { appState.resolveConflict(conflict, as: .keptRemote) }
                            Button("Reveal Both in Finder") { appState.revealConflict(conflict) }
                        }
                    } else if conflict.resolutionState != .dismissed {
                        Button("Dismiss") { appState.resolveConflict(conflict, as: .dismissed) }
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    private var trashView: some View {
        recoveryList(emptyTitle: "PeerNest Trash Is Empty", emptyIcon: "trash") {
            ForEach(appState.trashRecords) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.originalRelativePath).fontWeight(.medium)
                        Text("Deleted \(record.deletedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { appState.restoreTrashRecord(record) }
                    Button("Delete Permanently", role: .destructive) { permanentDeletion = record }
                }
                .padding(.vertical, 5)
            }
        }
    }

    private var versionsView: some View {
        recoveryList(emptyTitle: "No Stored Versions", emptyIcon: "clock.arrow.circlepath") {
            ForEach(appState.storedVersions) { version in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(version.relativePath).fontWeight(.medium)
                        Text("\(version.storedAt.formatted(date: .abbreviated, time: .shortened)) · \(version.reason.rawValue) · \(version.contentHash.prefix(10))")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file)).foregroundStyle(.secondary)
                    Button("Restore as Current") { appState.restoreVersion(version) }
                    Button("Export Copy…") { appState.exportStoredVersion(version) }
                    Button("Reveal Stored Copy") { appState.revealStoredVersion(version) }
                }
                .padding(.vertical, 5)
            }
        }
    }

    private var storageView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Recovery Storage") {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                    GridRow { Text("Trash"); Text(ByteCountFormatter.string(fromByteCount: appState.syncHealth.trashSize, countStyle: .file)) }
                    GridRow { Text("Version history"); Text(ByteCountFormatter.string(fromByteCount: appState.syncHealth.versionHistorySize, countStyle: .file)) }
                    GridRow { Text("Maximum"); Text(ByteCountFormatter.string(fromByteCount: appState.retentionPolicy.maximumRecoveryBytes, countStyle: .file)) }
                    GridRow { Text("Minimum free disk"); Text(ByteCountFormatter.string(fromByteCount: appState.retentionPolicy.minimumFreeDiskBytes, countStyle: .file)) }
                }
                .padding(8)
            }
            GroupBox("Retention") {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Trash: \(appState.retentionPolicy.trashRetentionDays) days", value: Binding(
                        get: { appState.retentionPolicy.trashRetentionDays },
                        set: { value in appState.updateRetentionPolicy { $0.trashRetentionDays = value } }
                    ), in: 1...365)
                    Stepper("Versions: \(appState.retentionPolicy.versionRetentionDays) days", value: Binding(
                        get: { appState.retentionPolicy.versionRetentionDays },
                        set: { value in appState.updateRetentionPolicy { $0.versionRetentionDays = value } }
                    ), in: 1...365)
                    Stepper("Maximum versions per file: \(appState.retentionPolicy.maximumVersionsPerFile)", value: Binding(
                        get: { appState.retentionPolicy.maximumVersionsPerFile },
                        set: { value in appState.updateRetentionPolicy { $0.maximumVersionsPerFile = value } }
                    ), in: 1...100)
                }
                .padding(8)
            }
            Button("Clean Up Eligible Items") { appState.cleanupRecoveryStorage() }
            Text("Cleanup preserves active conflicts and unacknowledged tombstones.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func recoveryList<Content: View>(
        emptyTitle: String,
        emptyIcon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if (tab == .pending && appState.journalOperations.allSatisfy(\.state.isTerminal))
                || (tab == .conflicts && appState.conflicts.isEmpty)
                || (tab == .trash && appState.trashRecords.isEmpty)
                || (tab == .versions && appState.storedVersions.isEmpty) {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
            }
        }
    }

    private var healthTitle: String {
        switch appState.syncHealth.state {
        case .upToDate: "Up to Date"
        case .syncing: "Syncing"
        case .offlineChangesPending: "Offline Changes Pending"
        case .reconciling: "Reconciling"
        case .conflictsNeedAttention: "Conflicts Need Attention"
        case .paused: "Paused"
        case .storageWarning: "Storage Warning"
        case .error: "Error"
        }
    }

    private var healthIcon: String {
        switch appState.syncHealth.state {
        case .upToDate: "checkmark.circle.fill"
        case .syncing, .reconciling: "arrow.triangle.2.circlepath"
        case .offlineChangesPending: "wifi.slash"
        case .conflictsNeedAttention, .storageWarning, .error: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    private var healthColor: Color {
        switch appState.syncHealth.state {
        case .upToDate: .green
        case .syncing, .reconciling: .blue
        case .offlineChangesPending, .paused: .secondary
        case .conflictsNeedAttention, .storageWarning: .orange
        case .error: .red
        }
    }
}
