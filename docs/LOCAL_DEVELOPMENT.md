# 로컬 개발

## 필요한 환경

- Python 3.10 이상. SQLite 개발 서버는 표준 라이브러리만 사용합니다.
- Node.js 22, npm. 웹 의존성은 `web/package-lock.json`으로 고정합니다.
- iOS 앱: macOS, Xcode, iOS 26 이상 시뮬레이터. 실제 기기 서명에는 본인 Apple 개발팀 설정이 필요합니다.

## 1. 서버

```sh
python3 server/app.py --port 8817 --db /tmp/ourledger-dev.sqlite
```

기본 리스닝 주소는 `127.0.0.1`입니다. 로컬 가입 코드는 선택 사항이며, 외부 접근이 가능한 서버는 HTTPS와 별도의 강한 가입 코드를 설정해야 합니다. `.env.example`은 안내용이며 자동으로 읽지 않습니다.

Firestore를 직접 사용하는 경우에만 `python3 -m pip install -r server/requirements.txt`가 필요합니다. Google 인증정보는 저장소 밖에서 관리하세요. 이 저장소에는 운영 계정이나 서비스 계정 키를 포함하지 않습니다.

## 2. iOS

`OurLedger.xcodeproj`를 열고 `OurLedger` 스킴과 iPhone 시뮬레이터를 선택합니다. 공개본의 기본 서버 주소는 `http://127.0.0.1:8817`입니다. 새 가계부를 만들면 별도의 로컬 데이터베이스에 저장됩니다.

실제 iPhone에서 `127.0.0.1`은 Mac이 아닌 iPhone 자신입니다. 실기기는 본인이 구성한 HTTPS 서버를 사용하세요. 앱·위젯의 개발팀은 공개본에서 비워 두었으므로 실기기 빌드 시 본인 팀과 앱 식별자를 설정해야 합니다.

서명된 `.shortcut` 바이너리는 공개본에서 제외하고 검토 가능한 `.plist` 템플릿만 제공합니다. 직접 배포하려면 본인 계정으로 단축어를 구성·서명해야 합니다. 앱의 설치 링크는 기존에 공개한 iCloud 단축어이며 운영 로그인 정보를 포함하지 않습니다.

단축어 템플릿의 `YOUR_APPLE_TEAM_ID`도 본인 개발팀으로 바꾸세요. 앱 식별자를 변경하면 App Intents·App Group·위젯·단축어 템플릿의 식별자를 함께 맞춰야 합니다.

## 3. PC

```sh
cd web
npm ci
LEDGER_API_URL=http://127.0.0.1:8817 npm run dev
```

`http://127.0.0.1:5183`의 체험 화면은 브라우저 메모리의 합성 데이터입니다. 새로고침하면 초기화됩니다. 실제 로컬 원장 연결은 iPhone 시뮬레이터의 **설정 → PC에서 기록하기 → 연결 코드 만들기**를 이용합니다.

웹을 외부에 배포할 때는 `LEDGER_API_URL`에 본인의 HTTPS API 주소를 지정해야 합니다. 가입 코드·기기 토큰을 `VITE_*` 환경변수에 넣지 마세요. 이 값은 브라우저 번들로 공개될 수 있습니다.

## 검사

```sh
python3 -m unittest discover -s server -v
python3 checks/LedgerWorkbookCheck.py
cd web
npm test
npm run build
```

Firestore 통합 검사는 별도 계정과 명시적인 환경 설정이 필요하며, 설정하지 않으면 건너뜁니다. XLSX 검사의 추가 소비자 검증에는 `openpyxl`이 필요합니다. 다른 Swift 실행 검사는 `checks/`의 각 파일 설명을 따릅니다.

iOS UI 검사는 운영 연결이 없는 **별도 시뮬레이터**와 `127.0.0.1:18817`의 로컬 서버를 사용합니다. 기존 실사용 기기에서 UI 테스트를 실행하지 않습니다.

```sh
python3 server/app.py --port 18817 --db /tmp/ourledger-ui.sqlite
# 다른 터미널에서 본인의 별도 시뮬레이터 ID를 지정
xcodebuild test -project OurLedger.xcodeproj -scheme OurLedger \
  -destination 'platform=iOS Simulator,id=YOUR_TEST_SIMULATOR_ID' \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=-
```
