import SwiftUI
import PhotosUI
import Vision
import ImageIO

struct InboxView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pasting = false
    @State private var selected: ImportedMessage?
    @State private var selectedSettlement: SettlementCandidate?
    @State private var error: String?
    @State private var busy = false
    @State private var mergeItem: ImportedMessage?
    @State private var mergeTarget: ImportCandidate?
    @State private var confirmingMerge = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    let header = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 12))
                    header {
                        Text("확인할 거래 \(store.snapshot?.inbox.count ?? 0)건")
                            .font(.title3.bold()).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Label("나만 보기", systemImage: "lock")
                            .font(.caption).foregroundStyle(LedgerTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 4).listRowSeparator(.hidden).ledgerTourTarget(.inbox)
                    if store.credentials?.notificationSetup.configured != true && store.snapshot?.inbox.isEmpty != false {
                        NotificationConnectionCard { PaymentNotificationRouter.shared.showGuide() }
                    }
                }.listRowBackground(LedgerTheme.background).listRowSeparator(.hidden)
                if store.snapshot?.inbox.isEmpty != false {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: store.credentials?.notificationSetup.configured == true ? "checkmark.circle" : "tray")
                                .font(.title).foregroundStyle(LedgerTheme.accent).accessibilityHidden(true)
                            Text(store.credentials?.notificationSetup.configured == true ? "확인할 거래가 없어요" : "아직 받은 알림이 없어요")
                                .font(.title3.weight(.semibold))
                            Text(store.credentials?.notificationSetup.configured == true ? "새 거래가 오면 여기서 확인하고 기록해요." : "위에서 알림을 연결하면 결제·입금 내역을 가져와요.")
                                .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden)
                }
                ForEach(store.snapshot?.inbox ?? []) { item in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.amount.map(won) ?? "금액 확인 필요")
                                    .font(.title2.bold()).monospacedDigit().foregroundStyle(LedgerTheme.ink)
                                Text(item.merchant.isEmpty ? "사용처 확인 필요" : item.merchant)
                                    .font(.headline).foregroundStyle(LedgerTheme.ink)
                            }.fixedSize(horizontal: false, vertical: true)
                            Text(item.sources.map { $0 == "sms" ? "문자" : $0 == "app" ? "앱 알림" : "직접 전달" }.joined(separator: " · ") + (item.kind == "refund" ? " · 취소/환불" : item.kind == "transfer" ? " · 송금 확인" : ""))
                                .font(.caption).foregroundStyle(LedgerTheme.muted)
                            if let time = item.time { Text((time.count == 10 ? "거래일 " : "거래 시각 ") + displayTime(time)).font(.caption).foregroundStyle(LedgerTheme.muted) }
                            else if let received = item.receivedAt { Text("수신 " + displayTime(received) + " · 거래 시각은 확인해 주세요").font(.caption).foregroundStyle(LedgerTheme.muted) }
                            if item.requiresReview && !item.reason.isEmpty {
                                Label(item.reason, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(LedgerTheme.muted)
                            }
                            ForEach((store.snapshot?.settlementCandidates ?? []).filter { $0.importID == item.id }) { candidate in
                                Button { selectedSettlement = candidate } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(candidate.due.month + " 정산 후보", systemImage: "arrow.left.arrow.right")
                                            .font(.subheadline.weight(.semibold))
                                        Text("금액이 같아요 · 상대를 확인하고 정산하기")
                                            .font(.caption)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .padding(12).background(LedgerTheme.background, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).foregroundStyle(LedgerTheme.accent)
                                    .disabled(store.refreshing || store.error != nil)
                                    .accessibilityIdentifier("settlementCandidate-" + candidate.id)
                            }
                            if item.needsDuplicateComparison {
                                Text("비슷한 알림과 비교해 주세요").font(.subheadline.weight(.semibold))
                                ForEach(candidates(for: item)) { candidate in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(candidate.merchant.isEmpty ? "사용처 미확인" : candidate.merchant).fontWeight(.medium)
                                            Spacer()
                                            Text(candidate.amount.map(won) ?? "금액 미확인").monospacedDigit()
                                        }
                                        Text((candidate.time.map(displayTime) ?? "거래 시각 미확인") + " · " + (candidate.kind == "refund" ? "환불" : "결제"))
                                            .font(.caption).foregroundStyle(LedgerTheme.muted)
                                        Text(candidate.sources.map { $0 == "sms" ? "문자" : $0 == "app" ? "앱 알림" : "직접 전달" }.joined(separator: " · ") + " · " + (candidate.status == "recorded" ? "이미 기록한 알림" : "아직 확인 전인 알림"))
                                            .font(.caption).foregroundStyle(LedgerTheme.muted)
                                        Button("이 알림과 같은 결제예요") {
                                            mergeItem = item; mergeTarget = candidate; confirmingMerge = true
                                        }.buttonStyle(.borderless).frame(minHeight: 44).accessibilityIdentifier("mergeCandidate-" + candidate.id)
                                    }.padding(14).background(LedgerTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                                }
                                if candidates(for: item).isEmpty {
                                    Text(item.candidateDetails == nil ? "이전 알림 상세를 보려면 서버 업데이트가 필요해요. 확실하지 않으면 합치지 말고 확인해 주세요." : "이전 후보는 이미 제외되었거나 더 이상 비교할 수 없어요.")
                                        .font(.footnote).foregroundStyle(LedgerTheme.muted)
                                }
                            }
                            let actions = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                            actions {
                                Button { selected = item } label: {
                                    Text("확인하고 기록").fontWeight(.semibold)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 14).frame(minHeight: 44)
                                        .foregroundStyle(LedgerTheme.onAccent)
                                        .background(LedgerTheme.action, in: RoundedRectangle(cornerRadius: 12))
                                        .contentShape(RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                                    .accessibilityLabel((item.merchant.isEmpty ? "이 거래" : item.merchant) + " 기록")
                                    .accessibilityIdentifier("recordImport-" + item.id)
                                Button(role: .destructive) { Task { await ignore(item.id) } } label: {
                                    Text(item.kind == "transfer" ? "정산·계좌 이동으로 제외" : "기록 안 함")
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8).frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.borderless)
                            }.font(.subheadline).padding(.top, 4)
                        }.padding(.vertical, 8)
                        DisclosureGroup {
                            Text(item.raw).font(.footnote).foregroundStyle(LedgerTheme.muted)
                                .textSelection(.enabled).accessibilityIdentifier("importRaw-" + item.id)
                        } label: {
                            Text("원본 문구 보기").frame(minHeight: 44, alignment: .leading)
                        }.font(.subheadline).foregroundStyle(LedgerTheme.muted)
                    }.listRowBackground(LedgerTheme.surface).listRowSeparator(.hidden).disabled(busy)
                }
                Section {
                    Button { pasting = true } label: { Label("알림·캡처 가져오기", systemImage: "square.and.pencil") }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).accessibilityIdentifier("pasteNotification").ledgerRowDivider()
                    if store.credentials?.notificationSetup.configured == true || store.snapshot?.inbox.isEmpty == false {
                        Button("알림 연결 상태 확인") { PaymentNotificationRouter.shared.showGuide() }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).accessibilityIdentifier("inboxConnectionGuide").ledgerRowDivider()
                    }
                }
                if let error { Section { ErrorNotice(message: error) } }
            }.listStyle(.insetGrouped).ledgerScreen().listSectionSpacing(16).ledgerRootScreen()
                .refreshable { await store.refresh() }
                .sheet(isPresented: $pasting) { PasteNotificationView() }
                .sheet(item: $selected) { item in
                    if let credentials = store.credentials {
                        PaymentNotificationView(route: PaymentNotificationRoute(id: item.id,
                            identity: credentials.notificationSetup.identity, rawText: "", scope: nil,
                            practice: false, ignored: false), startsInForm: true)
                    }
                }
                .sheet(item: $selectedSettlement) { SettlementConfirmationView(candidate: $0) }
                .confirmationDialog("같은 결제의 알림을 합칠까요?", isPresented: $confirmingMerge, titleVisibility: .visible) {
                    if let item = mergeItem, let candidate = mergeTarget {
                        Button("같은 결제 확인 · 알림 합치기") { Task { await merge(item.id, target: candidate.id) } }
                    }
                } message: {
                    if let candidate = mergeTarget {
                        Text(candidate.merchant + " · " + (candidate.amount.map(won) ?? "금액 미확인") + "\n" + (candidate.time.map(displayTime) ?? "시각 미확인") + "\n이 알림은 새 지출로 만들지 않아요. 서로 다른 결제라면 취소해 주세요.")
                    }
                }
        }
    }
    private func candidates(for item: ImportedMessage) -> [ImportCandidate] {
        if let details = item.candidateDetails { return details }
        return item.candidates.compactMap { id in
            guard let candidate = store.snapshot?.inbox.first(where: { $0.id == id }) else { return nil }
            return ImportCandidate(id: candidate.id, merchant: candidate.merchant, kind: candidate.kind, status: candidate.status, amount: candidate.amount, time: candidate.time, sources: candidate.sources)
        }
    }
    private func displayTime(_ value: String) -> String {
        if value.count == 10 { return value }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? String(value.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }
    private func ignore(_ id: String) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await store.mutate("/imports/" + id, method: "DELETE") }
        catch { self.error = error.localizedDescription }
    }
    private func merge(_ id: String, target: String) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await store.mutate("/imports/" + id + "/merge", body: ["targetID": target]) }
        catch { self.error = error.localizedDescription }
    }
}

struct PasteNotificationView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var raw = ""
    @State private var hasImageDraft = false
    @State private var source = "sms"
    @State private var drafts: [String: String] = [:]
    @State private var submissionIDs = ImportSubmissionIDs()
    @State private var busy = false
    @State private var error: String?
    @State private var selectedImages: [PhotosPickerItem] = []
    @State private var showingPhotoPicker = false
    @State private var openPhotosOnAppear: Bool
    @State private var imageTask: Task<Void, Never>?
    @State private var submissionTask: Task<Void, Never>?
    @State private var readingID: UUID?
    @State private var captureDrafts: [CaptureImportDraft] = []
    @State private var captureIdentity: String?
    @State private var recordingRoute: PaymentNotificationRoute?
    @State private var recordingIDs: [String]?
    init(initialSource: String = "sms", openPhotoPicker: Bool = false) {
        let source = ["sms", "app", "paste"].contains(initialSource) ? initialSource : "sms"
        _source = State(initialValue: source)
        _openPhotosOnAppear = State(initialValue: openPhotoPicker && source == "paste")
    }
    private var showingBatch: Bool { source == "paste" && !captureDrafts.isEmpty }
    private var hasSubmittedCapture: Bool { captureDrafts.contains { $0.imported != nil || $0.retryLocked } }
    private var canSubmit: Bool {
        if showingBatch { return captureDrafts.allSatisfy { !$0.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        Group {
            if let recordingRoute {
                PaymentNotificationView(route: recordingRoute, startsInForm: true, reviewIDs: recordingIDs)
            } else {
                importForm
            }
        }.onDisappear { cancelImageReading(); submissionTask?.cancel() }
            .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedImages,
                          maxSelectionCount: 10, selectionBehavior: .ordered, matching: .images)
            .task {
                guard openPhotosOnAppear else { return }
                openPhotosOnAppear = false
                showingPhotoPicker = true
            }
            .onChange(of: store.credentials?.notificationSetup.identity) { _, _ in
                cancelImageReading(); submissionTask?.cancel()
                showingPhotoPicker = false
                raw = ""; drafts = [:]; captureDrafts = []; captureIdentity = nil
                hasImageDraft = false; recordingRoute = nil; recordingIDs = nil
                submissionIDs = ImportSubmissionIDs()
            }
    }

    private var importForm: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("가져올 내용", selection: $source) {
                        Text("문자").tag("sms")
                        Text("앱 알림").tag("app")
                        Text("캡처").tag("paste")
                    }.pickerStyle(.segmented).accessibilityIdentifier("importSource")
                        .disabled(busy || hasSubmittedCapture)
                }
                if source == "paste" {
                    Section {
                        if readingID != nil {
                            ProgressView("선택한 캡처를 순서대로 읽고 있어요…")
                            Button("읽기 취소") { cancelImageReading() }
                                .frame(minHeight: 44).disabled(busy).accessibilityIdentifier("cancelPaymentOCR")
                        } else {
                            Button { showingPhotoPicker = true } label: {
                                Label(hasImageDraft || showingBatch ? "다른 캡처 선택" : "캡처 선택", systemImage: "photo")
                                    .frame(minHeight: 44)
                            }.disabled(busy || hasSubmittedCapture).accessibilityIdentifier("pickPaymentImage")
                        }
                    } footer: {
                        Text("최대 10장 · 선택한 순서로 확인해요. 이미지는 기기에서만 읽어요.")
                    }
                }
                if showingBatch {
                    if readingID == nil {
                        Section {
                            Text("\(captureDrafts.filter { !$0.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)건을 찾았어요")
                                .font(.headline).accessibilityIdentifier("captureBatchPreview")
                            if hasSubmittedCapture {
                                Text("가져온 항목은 확인함에 보관했어요.")
                                    .font(.footnote).foregroundStyle(LedgerTheme.muted)
                            }
                        }.listRowSeparator(.hidden)
                        ForEach(Array(captureDrafts.enumerated()), id: \.element.id) { index, draft in
                            Section {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(draft.summary).font(.headline)
                                        .accessibilityIdentifier("captureBatchSummary-" + String(index + 1))
                                    if draft.previewText == draft.raw, let merchant = draft.preview?.merchant,
                                       !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(merchant).font(.subheadline).foregroundStyle(LedgerTheme.muted)
                                    }
                                }.fixedSize(horizontal: false, vertical: true)
                                if let issue = draft.issue {
                                    Text(issue).font(.subheadline).foregroundStyle(LedgerTheme.muted)
                                        .accessibilityIdentifier("captureBatchIssue-" + String(index + 1))
                                }
                                if draft.needsManualText {
                                    captureEditor(at: index, draft: draft)
                                } else {
                                    DisclosureGroup("인식 내용 수정") {
                                        captureEditor(at: index, draft: draft)
                                    }.accessibilityIdentifier("captureBatchEdit-" + String(index + 1))
                                }
                            } header: { Text("\(index + 1)번째 · 캡처 \(draft.imageNumber)") }
                                .listRowSeparator(.hidden)
                        }
                        if !busy && captureDrafts.contains(where: {
                            $0.previewText != $0.raw && !$0.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && $0.imported == nil && !$0.retryLocked
                        }) {
                            Button("금액·종류 다시 확인") {
                                submissionTask = Task { await refreshCapturePreviews() }
                            }.accessibilityIdentifier("refreshCapturePreview").listRowSeparator(.hidden)
                        }
                    }
                } else if source != "paste" || hasImageDraft {
                    Section {
                        if source != "paste" { pasteTextButton.listRowSeparator(.hidden) }
                        TextEditor(text: $raw).frame(minHeight: 240)
                            .accessibilityLabel("결제·송금 내용").accessibilityIdentifier("notificationText")
                            .disabled(busy || readingID != nil)
                            .overlay(alignment: .topLeading) {
                                if raw.isEmpty {
                                    Text(source == "paste" ? "인식한 내용을 고치거나 입력해 주세요." : source == "sms" ? "결제·입금 문자를 붙여넣어 주세요." : "앱 알림 문구를 붙여넣어 주세요.")
                                        .font(.body).foregroundStyle(LedgerTheme.muted)
                                        .padding(.top, 8).padding(.leading, 5)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                    } header: { Text(source == "paste" ? "인식한 내용" : "내용 확인") }
                }
            }.ledgerScreen().listSectionSpacing(16)
                .contentMargins(.top, 8, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        ErrorNotice(message: error)
                        Button(busy ? "확인 중…" : showingBatch ? "한 건씩 확인" : "확인하고 기록") {
                            submissionTask = Task {
                                if showingBatch { await submitCaptureBatch() }
                                else { await submit() }
                            }
                        }.buttonStyle(LedgerPrimaryButtonStyle())
                            .disabled(!canSubmit || busy || readingID != nil)
                            .accessibilityIdentifier("importNotification")
                        if busy && showingBatch {
                            Button("가져오기 중단") { submissionTask?.cancel(); cancelImageReading() }
                                .accessibilityIdentifier("cancelCaptureImport")
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 12).background(LedgerTheme.background)
                }
                .navigationTitle("알림·캡처").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { cancelImageReading(); dismiss() }.disabled(busy) }
                }.interactiveDismissDisabled(busy)
                .onChange(of: source) { previous, current in
                    drafts[previous] = raw
                    cancelImageReading()
                    showingPhotoPicker = false
                    raw = drafts[current] ?? ""
                    error = nil
                }
                .onChange(of: selectedImages) { _, items in
                    if !items.isEmpty { readImages(items) }
                }
        }
    }

    private var pasteTextButton: some View {
        let identity = store.credentials?.notificationSetup.identity
        let destination = source
        return PasteButton(payloadType: String.self) { values in
            guard !busy, readingID == nil, recordingRoute == nil, source == destination,
                  source != "paste", store.credentials?.notificationSetup.identity == identity else { return }
            let text = values.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : raw + "\n" + text
            error = nil
        }
        .labelStyle(.titleAndIcon).controlSize(.large).tint(LedgerTheme.accent)
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .disabled(busy || readingID != nil)
        .accessibilityIdentifier("pasteNotificationText")
    }

    private func captureEditor(at index: Int, draft: CaptureImportDraft) -> some View {
        TextEditor(text: $captureDrafts[index].raw).frame(minHeight: 130)
            .accessibilityLabel("\(index + 1)번째 거래 원문")
            .accessibilityIdentifier("captureBatchText-" + String(index + 1))
            .disabled(busy || readingID != nil || draft.imported != nil || draft.retryLocked)
    }

    @MainActor private func submit(automatically: Bool = false) async {
        guard !busy, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !automatically || source == "paste" else { return }
        guard let credentials = store.credentials else {
            error = "먼저 가계부를 연결해 주세요."; return
        }
        let text = raw, submittedSource = source
        let owner = store.snapshot?.me
        let api = ServerAPI(credentials: credentials)
        let eventID = submissionIDs.id(source: submittedSource, text: text)
        busy = true; error = nil
        defer { busy = false }
        do {
            try Task.checkCancellation()
            if automatically {
                let parsed: PaymentRecognition = try await api.request("/imports/preview", method: "POST", body: CaptureImportFlow.payload(text: text, source: submittedSource))
                try Task.checkCancellation()
                guard store.credentials == credentials, source == submittedSource, raw == text else { return }
                guard CaptureImportFlow.isClear(amount: parsed.amount, merchant: parsed.merchant,
                    kind: parsed.kind, requiresReview: parsed.requiresReview) else { return }
            }
            let imported: ImportedMessage = try await api.request("/imports", method: "POST",
                body: CaptureImportFlow.payload(text: text, source: submittedSource, eventID: eventID))
            try CaptureImportFlow.validateReview(imported, text: text, source: submittedSource)
            try Task.checkCancellation()
            guard store.credentials == credentials, source == submittedSource, raw == text else { return }
            await store.refresh()
            try Task.checkCancellation()
            guard store.credentials == credentials, source == submittedSource, raw == text else { return }
            if imported.owner == owner, imported.status == "pending", !imported.needsDuplicateComparison {
                // Even an unknown amount/kind belongs in the common form, never a guessed transaction.
                recordingIDs = submittedSource == "paste" ? [imported.id] : nil
                recordingRoute = PaymentNotificationRoute(id: imported.id,
                    identity: credentials.notificationSetup.identity, rawText: "", scope: nil,
                    practice: false, ignored: false)
            } else { dismiss() }
        } catch {
            guard !Task.isCancelled, store.credentials == credentials, source == submittedSource, raw == text else { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor private func refreshCapturePreviews() async {
        guard !busy, let credentials = store.credentials,
              credentials.notificationSetup.identity == captureIdentity, source == "paste" else { return }
        busy = true
        defer { busy = false }
        for index in captureDrafts.indices {
            let draft = captureDrafts[index]
            guard !Task.isCancelled, store.credentials == credentials, source == "paste" else { return }
            if draft.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.imported != nil || draft.retryLocked { continue }
            do {
                let preview: PaymentRecognition = try await ServerAPI(credentials: credentials).request("/imports/preview", method: "POST", body: CaptureImportFlow.payload(text: draft.raw, source: "paste"))
                try Task.checkCancellation()
                guard store.credentials == credentials, source == "paste",
                      captureDrafts.indices.contains(index), captureDrafts[index].id == draft.id, captureDrafts[index].raw == draft.raw else { return }
                captureDrafts[index].preview = preview
                captureDrafts[index].previewText = draft.raw
                captureDrafts[index].issue = preview.amount == nil ? "금액을 확정하지 못했어요. 기록 화면에서 직접 확인해 주세요." : nil
            } catch {
                guard !Task.isCancelled, store.credentials == credentials, source == "paste",
                      captureDrafts.indices.contains(index), captureDrafts[index].id == draft.id else { return }
                captureDrafts[index].issue = "금액·종류를 확인하지 못했어요. 원문을 확인하고 다시 시도해 주세요."
            }
        }
    }

    @MainActor private func submitCaptureBatch() async {
        guard !busy, source == "paste", !captureDrafts.isEmpty,
              captureDrafts.allSatisfy({ !$0.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let credentials = store.credentials, credentials.notificationSetup.identity == captureIdentity else { return }
        busy = true; error = nil
        defer { busy = false }
        let owner = store.snapshot?.me
        let api = ServerAPI(credentials: credentials)
        for index in captureDrafts.indices {
            guard !Task.isCancelled, store.credentials == credentials, source == "paste" else {
                error = "가져오기를 중단했어요. 이미 가져온 항목은 유지하며 나머지는 다시 시도할 수 있어요."; return
            }
            if captureDrafts[index].imported != nil { continue }
            let draftID = captureDrafts[index].id, text = captureDrafts[index].raw
            let eventID = captureDrafts[index].submissionIDs.id(source: "paste", text: text)
            captureDrafts[index].retryLocked = true
            do {
                let imported: ImportedMessage = try await api.request("/imports", method: "POST", body: CaptureImportFlow.payload(text: text, source: "paste", eventID: eventID))
                try CaptureImportFlow.validateReview(imported, text: text, source: "paste")
                // Retain a successful response even if cancellation arrived with it.
                guard store.credentials == credentials, source == "paste",
                      captureDrafts.indices.contains(index), captureDrafts[index].id == draftID else { return }
                guard imported.owner == owner else { throw APIError(message: "이 가계부의 가져오기 결과를 확인하지 못했어요.") }
                captureDrafts[index].imported = imported
                captureDrafts[index].retryLocked = false
                captureDrafts[index].issue = imported.status == "pending" ? "확인함에 보관했어요. 아직 기록하지 않았어요." : "이미 처리했거나 거래가 아닌 안내예요. 새 기록으로 만들지 않아요."
                try Task.checkCancellation()
            } catch {
                guard store.credentials == credentials, source == "paste",
                      captureDrafts.indices.contains(index), captureDrafts[index].id == draftID else { return }
                // A timeout/5xx/cancellation may follow a committed import. Freeze its text until
                // the same eventID resolves; a definitive rejection permits correcting the raw text.
                if let failure = error as? APIError, let status = failure.statusCode, (400...499).contains(status) {
                    captureDrafts[index].retryLocked = false
                }
                if captureDrafts[index].imported == nil {
                    captureDrafts[index].issue = captureDrafts[index].retryLocked
                        ? "응답을 확인하지 못했어요. 원문을 유지한 채 다시 확인해 주세요."
                        : "원문을 고친 뒤 다시 확인해 주세요."
                }
                self.error = Task.isCancelled ? "가져오기를 중단했어요. 성공한 항목은 유지했어요."
                    : "\(index + 1)번째 내용을 가져오지 못했어요. 성공한 항목은 유지하며 다시 시도해요. " + error.localizedDescription
                return
            }
        }
        let previousUpdate = store.updatedAt, requestedMonth = store.month
        await store.refresh()
        guard !Task.isCancelled, store.credentials == credentials, source == "paste" else { return }
        // Another session may have handled an earlier success during a failed batch. Also,
        // refresh can fail or be superseded without throwing; never navigate from cached IDs.
        guard !store.refreshing, store.month == requestedMonth, store.error == nil,
              store.updatedAt != previousUpdate, let latest = store.snapshot, latest.me == owner else {
            error = "최신 확인함을 불러오지 못했어요. 가져온 항목은 유지했으니 다시 확인해 주세요."; return
        }
        let latestPending = latest.inbox.filter { $0.owner == latest.me && $0.status == "pending" }
        var seen = Set<String>()
        let pending = captureDrafts.compactMap(\.imported).compactMap { imported -> ImportedMessage? in
            guard imported.status == "pending", imported.owner == latest.me, seen.insert(imported.id).inserted else { return nil }
            return latestPending.first { $0.id == imported.id }
        }
        guard let first = pending.first else {
            error = "가져온 내용은 이미 처리했거나 거래가 아닌 안내예요. 각 항목의 결과를 확인해 주세요."; return
        }
        recordingIDs = pending.map(\.id)
        recordingRoute = PaymentNotificationRoute(id: first.id, identity: credentials.notificationSetup.identity,
            rawText: "", scope: nil, practice: false, ignored: false)
    }

    private func cancelImageReading() {
        imageTask?.cancel()
        imageTask = nil
        readingID = nil
        selectedImages = []
        for index in captureDrafts.indices where captureDrafts[index].waitingForImage {
            captureDrafts[index].waitingForImage = false
            captureDrafts[index].issue = "읽기를 취소했어요. 이 캡처의 내용을 직접 입력하거나 사진을 다시 선택해 주세요."
        }
    }

    private func readImages(_ items: [PhotosPickerItem]) {
        guard !busy, !hasSubmittedCapture, source == "paste", let credentials = store.credentials else { return }
        imageTask?.cancel()
        let automatically = !hasImageDraft && raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && captureDrafts.isEmpty
        let id = UUID()
        readingID = id; error = nil
        captureIdentity = credentials.notificationSetup.identity
        // Keep a slot for every selected image, including unreadable/unprocessed ones.
        captureDrafts = items.prefix(10).enumerated().map { CaptureImportDraft(imageNumber: $0.offset + 1, raw: "", waitingForImage: true, issue: "읽기 대기 중…", needsManualText: true) }
        imageTask = Task { @MainActor in
            defer {
                if readingID == id { readingID = nil; selectedImages = []; imageTask = nil }
            }
            for (imageIndex, item) in items.prefix(10).enumerated() {
                guard !Task.isCancelled, readingID == id, source == "paste", store.credentials == credentials else { return }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw PaymentImageOCR.Failure.unreadableImage }
                    let texts = try await PaymentImageOCR.recognizeTransactions(data)
                    try Task.checkCancellation()
                    guard readingID == id, source == "paste", store.credentials == credentials else { return }
                    guard !texts.isEmpty else { throw PaymentImageOCR.Failure.noText }
                    guard let slot = captureDrafts.firstIndex(where: { $0.imageNumber == imageIndex + 1 }) else { return }
                    captureDrafts.replaceSubrange(slot...slot, with: texts.map { CaptureImportDraft(imageNumber: imageIndex + 1, raw: $0, needsManualText: $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) })
                } catch {
                    guard !Task.isCancelled, readingID == id, source == "paste", store.credentials == credentials else { return }
                    if let slot = captureDrafts.firstIndex(where: { $0.imageNumber == imageIndex + 1 }) {
                        captureDrafts[slot].waitingForImage = false
                        captureDrafts[slot].issue = "\(imageIndex + 1)번째 캡처를 읽지 못했어요. 내용을 직접 입력하거나 다시 선택해 주세요."
                    }
                }
            }
            guard !Task.isCancelled, readingID == id, source == "paste", store.credentials == credentials else { return }
            hasImageDraft = true
            if items.count == 1, captureDrafts.count == 1, let draft = captureDrafts.first, !draft.raw.isEmpty {
                raw = draft.raw
                captureDrafts = []
                if automatically { await submit(automatically: true) }
            } else {
                await refreshCapturePreviews()
            }
        }
    }
}

private struct CaptureImportDraft: Identifiable {
    let id = UUID()
    let imageNumber: Int
    var raw: String
    var waitingForImage = false
    var issue: String?
    var needsManualText = false
    var preview: PaymentRecognition?
    var previewText: String?
    var submissionIDs = ImportSubmissionIDs()
    var imported: ImportedMessage?
    var retryLocked = false
    var summary: String {
        guard previewText == raw, let preview else { return "금액·종류 확인 필요" }
        let amount = preview.amount.map { $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) + "원" } ?? "금액 확인 필요"
        let kind: String
        switch preview.kind {
        case "expense": kind = "결제·지출"
        case "income": kind = "입금"
        case "transfer": kind = "출금·송금"
        case "refund": kind = "취소·환불"
        default: kind = "거래 종류 확인 필요"
        }
        return amount + " · " + kind
    }
}

private enum CaptureImportFlow {
    static func needsReview(text: String, source: String) -> Bool {
        source == "paste" && text.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("발신 알림: 금액 확인 필요")
    }
    static func payload(text: String, source: String, eventID: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["text": text, "source": source]
        if let eventID { body["eventID"] = eventID }
        if needsReview(text: text, source: source) { body["reviewOnly"] = true }
        return body
    }
    static func validateReview(_ imported: ImportedMessage, text: String, source: String) throws {
        guard needsReview(text: text, source: source) else { return }
        guard imported.status == "pending", imported.kind == "unknown", imported.amount == nil,
              imported.requiresReview else {
            throw APIError(message: "이 캡처를 확인 대상으로 보관하지 못했어요. 원문을 유지했으니 내용을 확인하고 다시 시도해 주세요.", statusCode: 409)
        }
    }
    static func isClear(amount: Int?, merchant: String, kind: String, requiresReview: Bool) -> Bool {
        guard let amount, (1...100_000_000_000).contains(amount) else { return false }
        // Missing merchant/date and bank classification are completed by the user in EntryForm.
        // The server leaves notice/balance-only or ambiguous transaction amounts nil.
        return ["expense", "income", "transfer", "refund"].contains(kind)
    }
}

// MARK: - On-device payment image OCR
enum PaymentImageOCR {
    struct Line {
        let text: String
        let box: CGRect
    }

    enum Failure: LocalizedError {
        case unreadableImage, noText

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "이미지를 열지 못했어요. 다른 캡처를 선택해 주세요."
            case .noText: "글자를 찾지 못했어요. 선명한 캡처를 다시 선택해 주세요."
            }
        }
    }

    nonisolated static func editableText(from lines: [Line]) -> String {
        let raw = lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        func matches(_ pattern: String, _ text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let string = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: string.length))
                .map { string.substring(with: $0.range) }
        }
        func label(_ title: String) -> Line? {
            let found = lines.filter { compact($0.text) == title }
            return found.count == 1 && found[0].box.minX < 0.35 ? found[0] : nil
        }
        func value(for label: Line, joiningDateFragments: Bool = false) -> Line? {
            let found = lines.filter {
                $0.box.minX > label.box.maxX + 0.04
                    && min($0.box.maxY, label.box.maxY) - max($0.box.minY, label.box.minY)
                        > min($0.box.height, label.box.height) * 0.5
            }
            if found.count == 1 { return found[0] }
            guard joiningDateFragments, (2...6).contains(found.count) else { return nil }
            // Vision can split a single date row horizontally, especially on dark captures.
            // Join only adjacent boxes; bankDetail still validates the complete date/calendar.
            let ordered = found.sorted { $0.box.minX < $1.box.minX }
            for (left, right) in zip(ordered, ordered.dropFirst()) {
                let height = min(left.box.height, right.box.height)
                let gap = right.box.minX - left.box.maxX
                let overlap = min(left.box.maxY, right.box.maxY) - max(left.box.minY, right.box.minY)
                guard overlap > height * 0.5, gap >= -height * 0.5, gap <= height * 2 else { return nil }
            }
            return Line(text: ordered.map(\.text).joined(separator: " "),
                        box: ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) })
        }
        // OCR reading order can group columns; pair labels and values by their screen positions.
        func bankDetail() -> String? {
            func field(_ titles: [String]) -> Line? {
                let found = titles.compactMap { label($0) }
                return found.count == 1 ? found[0] : nil
            }
            func sameBox(_ a: Line, _ b: Line?) -> Bool { b.map { a.box == $0.box } ?? false }
            let money = #"^[+−-]?(?:\d{1,3}(?:,\d{3})+|\d+)원$"#
            guard matches(#"예정|취소|환불|실패|거래목록|거래내역목록|합계|총\s*\d+\s*건"#, compact(raw)).isEmpty,
                  let typeLabel = field(["거래유형", "거래구분"]), let type = value(for: typeLabel),
                  let nameLabel = field(["적요", "거래처", "받는분", "보낸분", "받는사람", "보낸사람"]),
                  let name = value(for: nameLabel), !name.text.isEmpty, name.text.count <= 120,
                  let dateLabel = field(["일시", "거래일시", "거래일자"]),
                  let dateValue = value(for: dateLabel, joiningDateFragments: true)
            else { return nil }
            let kind: String
            switch compact(type.text).uppercased() {
            case "CMS출금", "출금", "자동출금", "자동이체", "이체", "송금", "출금이체": kind = "출금"
            case "CMS입금", "입금", "입금이체": kind = "입금"
            default: return nil
            }
            let headerAmounts = lines.filter {
                $0.box.minY > max(typeLabel.box.maxY, nameLabel.box.maxY)
                    && !matches(money, compact($0.text)).isEmpty
            }
            guard headerAmounts.count == 1 else { return nil }
            let header = headerAmounts[0]
            let signed = compact(header.text).replacingOccurrences(of: "−", with: "-")
            guard !(kind == "입금" && signed.hasPrefix("-")),
                  !(kind == "출금" && signed.hasPrefix("+")),
                  let amount = Int(signed.filter(\.isNumber)), (1...100_000_000_000).contains(amount)
            else { return nil }
            let balance = field(["거래후잔액", "잔액", "출금후잔액", "입금후잔액"]).flatMap { value(for: $0) }
            let labeledAmount = field(["거래금액", "출금금액", "입금금액", "이체금액"]).flatMap { value(for: $0) }
            // An extra unlabelled amount may belong to another transaction: never guess which one to keep.
            for row in lines where !matches(#"(?:\d{1,3}(?:,\d{3})+|\d+)\s*원"#, row.text).isEmpty {
                if sameBox(row, header) || sameBox(row, balance) { continue }
                if sameBox(row, labeledAmount), !matches(money, compact(row.text)).isEmpty,
                   Int(row.text.filter(\.isNumber)) == amount { continue }
                return nil
            }
            let dateText = compact(dateValue.text)
            guard !matches(#"^\d{4}(?:년|[./-])\d{1,2}(?:월|[./-])\d{1,2}(?:일)?(?:\d{1,2}:\d{2}(?::\d{2})?)?$"#, dateText).isEmpty else { return nil }
            let parts = matches(#"\d+"#, dateValue.text).compactMap(Int.init)
            guard [3,5,6].contains(parts.count) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                            hour: parts.count >= 5 ? parts[3] : 0,
                                            minute: parts.count >= 5 ? parts[4] : 0,
                                            second: parts.count == 6 ? parts[5] : 0)
            guard let date = calendar.date(from: components),
                  calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else { return nil }
            let day = String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
            let amountText = signed.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
            let time = parts.count >= 5 ? "\n" + day + String(format: " %02d:%02d", parts[3], parts[4]) : ""
            return "\(kind)\n\(amountText)\n가맹점: \(name.text)\n거래일: \(day)\(time)"
        }
        if let bank = bankDetail() { return bank }
        let amountPattern = #"(?<![\d.,])(?:\d{1,3}(?:,\d{3})+(?:\s*원)?|\d+\s*원)(?![\d.,])"#
        let datePattern = #"(?<!\d)(?:\d{4}|\d{2})[./-]\s*\d{1,2}[./-]\s*\d{1,2}(?!\d)"#
        let amounts = matches(amountPattern, raw)
        let numbers = amounts.compactMap { Int(compact($0).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "원", with: "")) }
        // shortcut: 같은 금액이 두 번 표시된 단일 카드 상세만 정돈하고 다른 배치는 원문으로 확인받는다.
        guard amounts.count == 2, numbers.count == 2, numbers[0] == numbers[1],
              (1...100_000_000_000).contains(numbers[0]),
              matches(#"목록|예정|취소|환불|이체|송금|합계|수수료|잔액|총\s*\d+\s*건"#, raw).isEmpty,
              matches(datePattern, raw).count == 1,
              let dateLabel = label("거래일자"), let typeLabel = label("결제구분"),
              let amountLabel = label("이용금액"), let cardLabel = label("결제카드"),
              dateLabel.box.minY > typeLabel.box.maxY,
              typeLabel.box.minY > amountLabel.box.maxY,
              amountLabel.box.minY > cardLabel.box.maxY,
              let dateLine = value(for: dateLabel), let typeLine = value(for: typeLabel),
              let amountLine = value(for: amountLabel), value(for: cardLabel) != nil,
              compact(typeLine.text) == "일시불",
              !matches(#"^(?:\d{1,3}(?:,\d{3})+|\d+)원$"#, compact(amountLine.text)).isEmpty,
              !matches("^" + datePattern + "$", dateLine.text).isEmpty else { return raw }

        let headers = lines.filter {
            $0.box.minX < 0.35 && $0.box.minY > dateLabel.box.maxY
                && !matches(#"^(?:\d{1,3}(?:,\d{3})+|\d+)원$"#, compact($0.text)).isEmpty
        }
        guard headers.count == 1 else { return raw }
        let merchants = lines.filter {
            $0.box.minY > headers[0].box.maxY && $0.box.maxY < 0.94
                && abs($0.box.minX - headers[0].box.minX) < 0.04
                && !matches("[가-힣A-Za-z]", $0.text).isEmpty
        }
        guard merchants.count == 1, merchants[0].text.count <= 120,
              !["현대카드", "카드", "결제상세", "거래내역", "이용내역"].contains(compact(merchants[0].text)) else { return raw }
        let parts = compact(dateLine.text).split(whereSeparator: { ".-/".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3 else { return raw }
        let year = parts[0] < 100 ? 2000 + parts[0] : parts[0]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return raw }
        let day = String(format: "%04d-%02d-%02d", year, parts[1], parts[2])
        return "카드 결제\n\(compact(amountLine.text))\n가맹점: \(merchants[0].text)\n거래일: \(day)"
    }

    nonisolated static func recognize(_ data: Data) async throws -> String {
        let text = editableText(from: try await recognizeLines(data))
        guard !text.isEmpty else { throw Failure.noText }
        return text
    }

    nonisolated static func recognizeTransactions(_ data: Data) async throws -> [String] {
        PaymentCaptureBatch.texts(from: try await recognizeLines(data))
    }

    nonisolated static func recognizeLines(_ data: Data) async throws -> [Line] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            // shortcut: 긴 캡처는 4096px로 축소, 작은 글자 누락이 확인되면 영역별 인식으로 확장.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) else { throw Failure.unreadableImage }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = false
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { observation -> Line? in
                guard let text = observation.topCandidates(1).first?.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return Line(text: text, box: observation.boundingBox)
            }
            guard !lines.isEmpty else { throw Failure.noText }
            return lines
        }
        return try await withTaskCancellationHandler {
            let text = try await worker.value
            try Task.checkCancellation()
            return text
        } onCancel: {
            worker.cancel()
        }
    }
}
