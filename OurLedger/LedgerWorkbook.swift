import Foundation

enum LedgerWorkbook {
    private enum ExportError: LocalizedError {
        case invalidMonth, invalidScope, unsupportedKind, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidMonth: return "내보낼 월을 YYYY-MM 형식으로 선택해 주세요."
            case .invalidScope: return "공용 또는 개인 내역을 선택해 주세요."
            case .unsupportedKind: return "지원하지 않는 거래 종류가 있어요."
            case .tooLarge: return "엑셀 파일로 내보내기에는 데이터가 너무 커요."
            }
        }
    }

    static func data(snapshot: LedgerSnapshot, month: String, scope: String) throws -> Data {
        let bytes = Array(month.utf8)
        guard bytes.count == 7, bytes[4] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || (48...57).contains($0.element) }),
              let year = Int(month.prefix(4)), (1...9999).contains(year),
              let number = Int(month.suffix(2)), (1...12).contains(number) else {
            throw ExportError.invalidMonth
        }
        guard scope == "shared" || scope == "personal" else { throw ExportError.invalidScope }

        // Only entries are confirmed records. Never serialize the snapshot or inbox.
        let entries = snapshot.entries.filter {
            $0.scope == scope && (scope == "shared" || $0.owner == snapshot.me)
                && $0.day.hasPrefix(month + "-")
        }
        guard entries.count < 1_048_576 else { throw ExportError.tooLarge }
        let headers = ["날짜", "구분", "내용", "분류", "금액(원)", "범위", "결제자"]
        var sheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <cols><col min="1" max="1" width="14" customWidth="1"/>
        <col min="2" max="2" width="20" customWidth="1"/>
        <col min="3" max="3" width="38" customWidth="1"/>
        <col min="4" max="7" width="18" customWidth="1"/></cols><sheetData><row r="1">
        """
        for (index, title) in headers.enumerated() {
            sheet += try textCell(title, reference: "\(columns[index])1", style: 1)
        }
        sheet += "</row>"
        for (index, entry) in entries.enumerated() {
            let kind: String
            switch entry.kind {
            case "expense": kind = "지출"
            case "income": kind = "수입"
            case "refund": kind = "환불"
            case "deposit": kind = "공동자금 입금"
            default: throw ExportError.unsupportedKind
            }
            let row = index + 2
            let strings = [entry.day, kind, entry.note, snapshot.categoryName(entry.category),
                           "", scope == "shared" ? "공용" : "개인", snapshot.memberName(entry.payer)]
            sheet += "<row r=\"\(row)\">"
            for column in strings.indices {
                let reference = "\(columns[column])\(row)"
                if column == 4 {
                    // Keep refund signs consistent with the ledger; income is not signedAmount (zero).
                    guard entry.kind != "refund" || entry.amount != Int.min else { throw ExportError.tooLarge }
                    let amount = entry.kind == "refund" ? -entry.amount : entry.amount
                    sheet += "<c r=\"\(reference)\" s=\"2\" t=\"n\"><v>\(amount)</v></c>"
                } else {
                    sheet += try textCell(strings[column], reference: reference)
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        return try zip([
            ("[Content_Types].xml", """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """),
            ("_rels/.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """),
            ("xl/workbook.xml", """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="가계부" sheetId="1" r:id="rId1"/></sheets></workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """),
            ("xl/styles.xml", """
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <fonts count="2"><font><sz val="11"/><name val="맑은 고딕"/></font><font><b/><sz val="11"/><name val="맑은 고딕"/></font></fonts>
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
            <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
            <xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
            </styleSheet>
            """),
            ("xl/worksheets/sheet1.xml", sheet)
        ])
    }

    private static let columns = ["A", "B", "C", "D", "E", "F", "G"]

    private static func textCell(_ value: String, reference: String, style: Int = 0) throws -> String {
        guard value.utf16.count <= 32_767 else { throw ExportError.tooLarge }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value)
                || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        }))
        let escaped = clean.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\r", with: "&#13;")
        return "<c r=\"\(reference)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escaped)</t></is></c>"
    }

    // Six fixed OOXML parts, ZIP method 0 (stored), without ZIP64 or data descriptors.
    private static func zip(_ parts: [(String, String)]) throws -> Data {
        var archive = Data(), directory = Data()
        for (path, xml) in parts {
            let name = Data(path.utf8)
            let payload = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xml).utf8)
            guard let size = UInt32(exactly: payload.count), let offset = UInt32(exactly: archive.count) else {
                throw ExportError.tooLarge
            }
            let crc = crc32(payload)
            append(0x04034B50, to: &archive)
            for field: UInt32 in [20, 0, 0, 0, 33] { append(field, to: &archive, bytes: 2) }
            for field in [crc, size, size] { append(field, to: &archive) }
            append(UInt32(name.count), to: &archive, bytes: 2)
            append(0, to: &archive, bytes: 2)
            archive.append(name)
            archive.append(payload)

            append(0x02014B50, to: &directory)
            for field: UInt32 in [20, 20, 0, 0, 0, 33] { append(field, to: &directory, bytes: 2) }
            for field in [crc, size, size] { append(field, to: &directory) }
            for field in [UInt32(name.count), 0, 0, 0, 0] { append(field, to: &directory, bytes: 2) }
            append(0, to: &directory)
            append(offset, to: &directory)
            directory.append(name)
        }
        guard let offset = UInt32(exactly: archive.count), let size = UInt32(exactly: directory.count),
              UInt64(offset) + UInt64(size) + 22 < UInt64(UInt32.max) else { throw ExportError.tooLarge }
        archive.append(directory)
        append(0x06054B50, to: &archive)
        for field in [0, 0, UInt32(parts.count), UInt32(parts.count)] { append(field, to: &archive, bytes: 2) }
        append(size, to: &archive)
        append(offset, to: &archive)
        append(0, to: &archive, bytes: 2)
        return archive
    }

    private static func append(_ value: UInt32, to data: inout Data, bytes: Int = 4) {
        for shift in stride(from: 0, to: bytes * 8, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB88320) }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data { value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 0xFF)] }
        return value ^ UInt32.max
    }
}
