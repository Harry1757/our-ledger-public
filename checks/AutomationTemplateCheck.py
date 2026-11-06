"""Run from any directory: python3 checks/AutomationTemplateCheck.py."""
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
template = plistlib.loads((root / "OurLedger/Shortcuts/PaymentAutomation.plist").read_bytes())
triggers = {item["WFTriggerIdentifier"]: item["WFTriggerSerializedParameters"]
            for item in template["WFWorkflowTriggers"]}
apps = triggers["WFNotificationTrigger"].get("SelectedApps", [])
# iOS serializes a single app as a dictionary and multiple apps as a list.
if isinstance(apps, dict):
    apps = [apps]
assert [app["BundleIdentifier"] for app in apps] == ["com.hwangsoonhwan.OurLedger"], "우리 가계부만 기본 포함해야 함"
assert not template.get("WFWorkflowImportQuestions"), "단일 앱 질문은 여러 앱 설정을 대체하지 못함"
conditions = triggers["WFMessageTrigger"]["WFMessageConditions"]["Value"]["WFActionParameterFilterTemplates"]
assert len(conditions) == 1 and conditions[0]["Values"]["Text"] == "원"
action, = template["WFWorkflowActions"]
assert action["WFWorkflowActionIdentifier"] == "com.hwangsoonhwan.OurLedger.ReceivePaymentNotificationIntent"
text = action["WFWorkflowActionParameters"]["text"]["Value"]["attachmentsByRange"]
assert text["{0, 1}"]["Type"] == "ExtensionInput", "받은 알림 원문을 전달해야 함"
print("Automation template: default app, no broken import question, SMS condition, original input OK")
