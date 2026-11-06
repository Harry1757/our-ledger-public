# 우리 가계부 PC

React·Vite와 Vercel Node Functions로 만든 PC 가계부입니다. 별도 데이터베이스를 추가하지 않고 Python API의 회원 권한·기록·정산 계산을 사용합니다.

- 공용/개인 범위, 월별 거래·검색·달력·카테고리 통계
- 작성자 권한에 따른 거래 수정·삭제, 결제자 표시
- 확인한 revision과 요청 ID를 사용하는 정산 완료
- 일회용 연결 코드로 같은 회원의 PC 세션 생성
- JavaScript에 인증 토큰을 노출하지 않는 HttpOnly 쿠키
- 실제 계정 없이 사용하는 메모리 기반 체험 모드

## 실행

```sh
npm ci
LEDGER_API_URL=http://127.0.0.1:8817 npm run dev
npm test
npm run build
```

전체 환경과 iOS 연결 방법: [로컬 개발](../docs/LOCAL_DEVELOPMENT.md).

이 저장소는 원래 운영 서버에 자동 연결되지 않습니다. 외부 배포 시 본인의 HTTPS API를 서버 환경변수 `LEDGER_API_URL`로 설정합니다. 토큰·가입 코드를 클라이언트 환경변수나 소스에 넣지 않습니다.
