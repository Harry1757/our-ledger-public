"""Compile the real Foundation exporter and inspect synthetic XLSX bytes only.

Run: python3 checks/LedgerWorkbookCheck.py (swiftc required; openpyxl optional).
No Xcode build, server, user data, package install, or persistent test files.
"""
from pathlib import Path
import importlib.util
import json
import struct
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
HEADERS = ["날짜", "구분", "내용", "분류", "금액(원)", "범위", "결제자"]


def entry(note, **changes):
    value = dict(id=note, owner="me", payer="me", scope="shared", kind="expense",
                funding="personal", note=note, category="food", day="2026-10-01",
                amount=1234567)
    value.update(changes)
    return value


def fixture():
    stats = dict(total=0, previousTotal=0, delta=0, budgetRemaining=0,
                 personalTotal=0, fundBalance=0, byCategory=[], byMember=[], daily=[], trend=[])
    # Extra decoded-but-never-exported fields carry unique privacy sentinels.
    members = [dict(id="me", name="순환", bank="SECRET_BANK", account="SECRET_ACCOUNT", holder="SECRET_HOLDER"),
               dict(id="other", name="+상대", bank="SECRET_BANK", account="SECRET_ACCOUNT", holder="SECRET_HOLDER")]
    rows = [entry("한글 점심 🍚"), entry("급여", kind="income", amount=3000000, payer="other"),
            entry("기존 환불", kind="refund", amount=2500),
            entry("공동 입금", kind="deposit", amount=50000, payer="fund"),
            entry("내 개인", scope="personal", amount=9800),
            entry("OTHER_PRIVATE", owner="other", payer="me", scope="personal"),
            entry("OLD_MONTH", day="2026-09-30"), entry("NEXT_MONTH", day="2026-11-01"),
            entry("UNKNOWN_SCOPE", scope="all")]
    return dict(household=dict(id="h", name="SECRET_HOUSEHOLD", mode="pool", budget=0),
                me="me", members=members, categories=[dict(id="food", name="식비 & 생활", keywords=["SECRET_RULE"])],
                entries=rows, inbox=[dict(id="i", owner="me", raw="SECRET_INBOX", status="pending",
                    merchant="SECRET_MERCHANT", kind="expense", card="SECRET_CARD", reference="SECRET_REF",
                    reason="SECRET_REASON", amount=99999, sources=[], candidates=[], requiresReview=True)],
                stats=stats, settlement=dict(fromID="me", toID="other", kind="pool", revision="SECRET_REVISION",
                    amount=0, count=0, memberAmounts=[]), history=[], token="SECRET_TOKEN")


class LedgerWorkbookCheck(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="ledger-workbook-check-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.work = Path(cls.temp.name)
        driver = cls.work / "Driver.swift"
        driver.write_text('''import Foundation
@main struct Check {
    static func main() throws {
        let args = CommandLine.arguments
        let snapshot = try JSONDecoder().decode(LedgerSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        do {
            let data = try LedgerWorkbook.data(snapshot: snapshot, month: args[2], scope: args[3])
            try data.write(to: URL(fileURLWithPath: args[4]))
        } catch { print("REJECTED"); exit(2) }
    }
}
''')
        cls.binary = cls.work / "workbook-check"
        subprocess.run(["swiftc", "-warnings-as-errors", str(ROOT / "OurLedger/Models.swift"),
                        str(ROOT / "OurLedger/LedgerWorkbook.swift"), str(driver), "-o", str(cls.binary)], check=True)

    def export(self, snapshot=None, month="2026-10", scope="shared", rejected=False):
        source = self.work / "snapshot.json"
        target = self.work / "output.xlsx"
        target.unlink(missing_ok=True)
        source.write_text(json.dumps(fixture() if snapshot is None else snapshot, ensure_ascii=True))
        result = subprocess.run([str(self.binary), str(source), month, scope, str(target)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2 if rejected else 0, result.stderr)
        if rejected:
            self.assertFalse(target.exists())
            self.assertEqual(result.stdout.strip(), "REJECTED")
            return None
        return target

    def read_rows(self, path):
        with zipfile.ZipFile(path) as archive:
            sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
        rows = []
        for row in sheet.findall("s:sheetData/s:row", NS):
            values = []
            for cell in row.findall("s:c", NS):
                self.assertIsNone(cell.find("s:f", NS), "No cell may contain an executable formula")
                if cell.get("t") == "inlineStr":
                    values.append(cell.find("s:is/s:t", NS).text or "")
                else:
                    self.assertEqual(cell.get("t", "n"), "n")
                    values.append(int(cell.find("s:v", NS).text))
            rows.append(values)
        return rows

    def test_real_zip_crcs_relationships_and_numeric_cells(self):
        path = self.export()
        raw = path.read_bytes()
        with zipfile.ZipFile(path) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()), {"[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
                "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml"})
            for info in archive.infolist():
                self.assertEqual(info.compress_type, zipfile.ZIP_STORED)
                payload = archive.read(info)
                self.assertEqual(info.CRC, zlib.crc32(payload))
                local = struct.unpack_from("<IHHHHHIIIHH", raw, info.header_offset)
                self.assertEqual(local[0], 0x04034B50)
                self.assertEqual(local[6:9], (info.CRC, len(payload), len(payload)))
                self.assertEqual(local[3], 0)
                self.assertFalse(local[2] & 8, "No missing data descriptor")
                ET.fromstring(payload)
            types = ET.fromstring(archive.read("[Content_Types].xml"))
            content_types = {item.get("PartName"): item.get("ContentType") for item in types}
            self.assertTrue(content_types["/xl/workbook.xml"].endswith("spreadsheetml.sheet.main+xml"))
            for rel_path, base in [("_rels/.rels", ""), ("xl/_rels/workbook.xml.rels", "xl/")]:
                for rel in ET.fromstring(archive.read(rel_path)):
                    self.assertNotEqual(rel.get("TargetMode"), "External")
                    self.assertIn(base + rel.get("Target"), archive.namelist())
            styles = ET.fromstring(archive.read("xl/styles.xml"))
            formats = styles.find("s:cellXfs", NS)
            fonts = styles.find("s:fonts", NS)
            sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            for cell in sheet.findall("s:sheetData/s:row", NS)[0]:
                style = formats[int(cell.get("s", "0"))]
                self.assertIsNotNone(fonts[int(style.get("fontId"))].find("s:b", NS))
            for cell in sheet.findall("s:sheetData/s:row/s:c", NS):
                if cell.get("r").startswith("E") and cell.get("r") != "E1":
                    self.assertEqual(formats[int(cell.get("s"))].get("numFmtId"), "3")  # built-in #,##0
        eocd = struct.unpack_from("<IHHHHIIH", raw, len(raw) - 22)
        self.assertEqual(eocd[:5], (0x06054B50, 0, 0, 6, 6))
        self.assertEqual(eocd[5] + eocd[6], len(raw) - 22)
        rows = self.read_rows(path)
        self.assertEqual(rows, [HEADERS,
            ["2026-10-01", "지출", "한글 점심 🍚", "식비 & 생활", 1234567, "공용", "순환"],
            ["2026-10-01", "수입", "급여", "식비 & 생활", 3000000, "공용", "+상대"],
            ["2026-10-01", "환불", "기존 환불", "식비 & 생활", -2500, "공용", "순환"],
            ["2026-10-01", "공동자금 입금", "공동 입금", "식비 & 생활", 50000, "공용", "공동자금"]])

    def test_scope_owner_month_and_nonentry_privacy(self):
        for scope, names in [("shared", ["한글 점심 🍚", "급여", "기존 환불", "공동 입금"]),
                             ("personal", ["내 개인"])]:
            path = self.export(scope=scope)
            rows = self.read_rows(path)
            self.assertEqual([row[2] for row in rows[1:]], names)
            with zipfile.ZipFile(path) as archive:
                payload = b"".join(archive.read(info) for info in archive.infolist()).decode("utf-8")
            for forbidden in ["SECRET_", "OTHER_PRIVATE", "OLD_MONTH", "NEXT_MONTH", "UNKNOWN_SCOPE"]:
                self.assertNotIn(forbidden, payload)
        self.assertEqual(self.read_rows(self.export(month="2026-09"))[1][2], "OLD_MONTH")
        snap = fixture()
        snap["me"] = "other"
        self.assertEqual([r[2] for r in self.read_rows(self.export(snap, scope="personal"))[1:]], ["OTHER_PRIVATE"])

    def test_all_human_strings_are_text_with_xml_controls_and_unicode(self):
        snap = fixture()
        notes = ['=HYPERLINK("https://invalid.example","한글")', '+SUM(1,2)', '-1+2', '@SUM(A1)',
                 ' <태그> & "따옴표" \'한글\' \t\r\n🍚\x00\x01\x0b\x1f\ufffe\uffff끝 ']
        snap["entries"] = [entry(note) for note in notes]
        snap["members"][0]["name"] = "=결제자"
        snap["categories"][0]["name"] = "+분류 & <한글>"
        path = self.export(snap)
        rows = self.read_rows(path)
        self.assertEqual([row[2] for row in rows[1:]], notes[:-1] + [' <태그> & "따옴표" \'한글\' \t\r\n🍚끝 '])
        for row in rows[1:]:
            self.assertEqual(row[3], "+분류 & <한글>")
            self.assertEqual(row[6], "=결제자")
        with zipfile.ZipFile(path) as archive:
            sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
            for row in sheet.findall("s:sheetData/s:row", NS):
                for cell in row:
                    if not cell.get("r").startswith("E") or cell.get("r") == "E1":
                        self.assertEqual(cell.get("t"), "inlineStr")

    def test_invalid_month_and_scope_fail_closed(self):
        for month in ["", "2026-1", "2026-00", "2026-13", "0000-01", "10000-01", "2026-10-01",
                      " 2026-10", "2026-10\n", "２０２６-１０", "2026-1x", "2026/+1"]:
            with self.subTest(month=month):
                self.export(month=month, rejected=True)
        for scope in ["", "all", "Shared", "personal ", "shared\n"]:
            with self.subTest(scope=scope):
                self.export(scope=scope, rejected=True)

    def test_empty_export_keeps_headers_and_valid_boundary_months(self):
        for month in ["0001-01", "9999-12", "2024-02"]:
            self.assertEqual(self.read_rows(self.export(month=month)), [HEADERS])

    def test_unsupported_kind_and_excel_cell_limit_reject_without_partial_file(self):
        for row in [entry("unknown", kind="transfer"), entry("가" * 32768),
                    entry("overflow refund", kind="refund", amount=-9223372036854775808)]:
            snap = fixture()
            snap["entries"] = [row]
            self.export(snap, rejected=True)
        snap = fixture()
        snap["entries"] = [entry("가" * 32767)]
        self.assertEqual(self.read_rows(self.export(snap))[1][2], "가" * 32767)

    def test_optional_openpyxl_consumer(self):
        if importlib.util.find_spec("openpyxl") is None:
            self.skipTest("openpyxl not installed; ZIP/XML checks still run")
        from openpyxl import load_workbook
        path = self.export()
        workbook = load_workbook(path, data_only=False)
        self.addCleanup(workbook.close)
        sheet = workbook.active
        self.assertEqual(sheet["C2"].value, "한글 점심 🍚")
        self.assertEqual(sheet["E2"].value, 1234567)
        self.assertEqual(sheet["E2"].number_format, "#,##0")
        self.assertTrue(sheet["A1"].font.bold)
        snap = fixture()
        snap["entries"] = [entry('=1+1'), entry('+1+1')]
        other = load_workbook(self.export(snap), data_only=False)
        self.addCleanup(other.close)
        self.assertEqual(other.active["C2"].data_type, "s")
        self.assertEqual(other.active["C2"].value, "=1+1")
        self.assertEqual(other.active["C3"].value, "+1+1")


if __name__ == "__main__":
    unittest.main(verbosity=2)
