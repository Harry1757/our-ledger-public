import SwiftUI

struct LedgerExportView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: LedgerSnapshot
    let month: String
    @State private var scope: String
    @State private var file: (scope: String, url: URL)?
    @State private var error: String?
    @State private var retry = 0

    init(snapshot: LedgerSnapshot, month: String, initialScope: String) {
        self.snapshot = snapshot; self.month = month
        _scope = State(initialValue: initialScope == "personal" ? "personal" : "shared")
    }

    private var count: Int {
        snapshot.entries.filter {
            $0.day.hasPrefix(month + "-") && $0.scope == scope && (scope == "shared" || $0.owner == snapshot.me)
        }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("기간", value: month.replacingOccurrences(of: "-", with: "."))
                    Picker("내보낼 내역", selection: $scope) {
                        Text("공용").tag("shared")
                        Text("내 개인").tag("personal")
                    }.pickerStyle(.segmented).accessibilityIdentifier("exportScope")
                    Text("확정한 거래 \(count)건").foregroundStyle(LedgerTheme.muted)
                        .accessibilityIdentifier("exportCount")
                } footer: {
                    Text(scope == "personal" ? "내 개인 기록만 포함해요. 공유할 대상을 확인해 주세요." : "선택한 달의 공용 기록만 포함해요.")
                }
                Section {
                    Label("날짜·내용·분류·금액·결제자", systemImage: "tablecells")
                    Text("이메일, 파일 저장 또는 설치된 스프레드시트 앱으로 보낼 수 있어요.")
                        .font(.subheadline).foregroundStyle(LedgerTheme.muted)
                }
                if let error {
                    Section {
                        ErrorNotice(message: error)
                        Button("다시 만들기") { retry += 1 }
                    }
                }
            }.ledgerScreen()
                .navigationTitle("엑셀 내보내기").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    Group {
                        if let file, file.scope == scope {
                            ShareLink(item: file.url) {
                                Label("엑셀 파일 공유하기", systemImage: "square.and.arrow.up")
                            }.buttonStyle(LedgerPrimaryButtonStyle())
                                .accessibilityIdentifier("shareLedgerWorkbook")
                                .accessibilityValue(file.url.lastPathComponent)
                        } else if error == nil {
                            ProgressView("파일 만드는 중…").frame(maxWidth: .infinity, minHeight: 52)
                        }
                    }.padding(20).background(LedgerTheme.background)
                }
                .task(id: scope + String(retry)) { await prepareFile() }
        }.presentationDragIndicator(.visible).presentationCornerRadius(28)
    }

    private func prepareFile() async {
        file = nil; error = nil
        let selectedScope = scope
        do {
            let snapshot = snapshot, month = month
            let bytes = try await Task.detached(priority: .userInitiated) {
                try LedgerWorkbook.data(snapshot: snapshot, month: month, scope: selectedScope)
            }.value
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OurLedgerExports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("우리 가계부_\(month)_\(selectedScope == "shared" ? "공용" : "내 개인").xlsx")
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            file = (selectedScope, url)
        } catch is CancellationError {
            return
        } catch {
            self.error = "엑셀 파일을 만들지 못했어요. 다시 시도해 주세요."
        }
    }
}
