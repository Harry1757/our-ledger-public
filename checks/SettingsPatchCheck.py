"""Run SettingsView's actual request builder against stale-account scenarios.

    python3 checks/SettingsPatchCheck.py
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server'))
from app import settings

source = (ROOT / 'OurLedger/Settings.swift').read_text()
builder = source.split('        var body: [String: Any] =', 1)[1].split('\n        do {', 1)[0]
program = '''import Foundation
func patch(_ bank: String, _ account: String, _ holder: String, _ budget: String) -> [String: Any] {
    let loadedAccount = ["이전은행", "111", "본인"]
    let loadedBudget = "10,000"
    let value = Int(budget.replacingOccurrences(of: ",", with: ""))!
    var body: [String: Any] = BUILDER
    return body
}
let patches = [
    patch("이전은행", "111", "본인", "3,000,000"),
    patch("다른은행", "111", "본인", "10,000"),
    patch("이전은행", "", "본인", "10,000"),
    patch("이전은행", "111", "본인", "10,000")
]
print(String(data: try JSONSerialization.data(withJSONObject: patches), encoding: .utf8)!)
'''.replace('BUILDER', builder)
with tempfile.TemporaryDirectory() as temporary:
    path = Path(temporary) / 'SettingsPatch.swift'
    path.write_text(program)
    patches = json.loads(subprocess.check_output(['swift', str(path)]))
assert patches == [{'budget': 3000000}, {'bank': '다른은행'}, {'account': ''}, {}]
state = {'members': [{'id': 'me', 'bank': '다른기기은행', 'account': '222', 'holder': '새예금주'}], 'budget': 10000}
settings(state, 'me', patches[0])
assert state['budget'] == 3000000
assert state['members'][0] == {'id': 'me', 'bank': '다른기기은행', 'account': '222', 'holder': '새예금주'}
settings(state, 'me', patches[1])
assert state['members'][0]['bank'] == '다른은행' and state['members'][0]['account'] == '222'
settings(state, 'me', patches[2])
assert state['members'][0]['account'] == '' and state['budget'] == 3000000
print('PASS: budget-only stale account protection, individual field edit, intentional clearing, unchanged fields')
