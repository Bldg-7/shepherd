# hc 단일 backend 마이그레이션 — 현재 범위

## 사용자 결정: 인앱 브라우저와 capture는 이번 범위에서 제외

이 문서는 현재 완료 조건의 기준이다. 과거 설계·검증 기록에 남은 browser/capture
필수 통합 항목보다 이 결정을 우선한다. **제외/연기는 구현 완료나 검증 통과가 아니다.**

이번 목표는 **기존 UI와 범위 내 사용 흐름을 유지하면서 terminal backend를 공식
hc 0.1.17의 `hc connect`로 교체**하는 것이다. 영구적인 이중 backend 제품은 만들지 않는다.

## 이번에 포함

- 기존 sidebar/board/launcher/switcher/제목 편집/Preview/키보드·파일·pane/tab 흐름.
- hc 터미널 연결·lossless 출력·입력·resize·재연결·소유 연결 종료.
- 브라우저·capture 주입 없는 shell/Claude/Codex/Pi의 일반 실행.
- 정확한 origin/epoch/CAS, durable 실행·종료 복구, 불확실한 요청 재실행 금지.
- local/직접 SSH 및 허용된 원격 범위, 파일 작업, pairing, 모바일 terminal/screen 흐름.
- core event 기반 attention/알림, hc 탐색·호환성·설치 UX와 필요한 lifecycle 검증.
- 위 범위의 실제 제품 회귀 검증 후 기본 backend 전환 및 legacy backend 제거.

## 이번에 제외 — 별도 후속 작업

| 기능 | 제외되는 작업 |
| --- | --- |
| 인앱 브라우저 | experimental browser, 3rdr-browser, browser/credential 권한 연결 및 AgentRuntime 주입 재설계 |
| Capture 기반 대화 표시 | 모델 API 요청·응답을 proxy/recorder로 수집해 모바일에 구조화된 세션 메시지로 표시하는 신규 hc 통합 및 UI parity |
| Capture launcher 연결 | hc capture route 예약, launcher ticket/run receipt 결합, proxy URL/token 전달, provider-native session 연동 |
| Capture 실행 보조기 | token 전달용 one-shot IPC/bootstrap/helper 설계·구현·실행 검증 |
| Capture 전용 서비스 | hc reservation에 맞춘 capture proxy sweep/off/restart/install/handover 통합 |

따라서 capture route/provider session/토큰 전달/archive 화면 parity의 미완료는
**현재 hc backend 전환의 완료 차단 항목이 아니다.** terminal 화면·입력·일반 CLI 실행과
core event 알림까지 제외하는 결정은 아니다. hc 자체의 설치·서비스 생존·안전한 원격
동작·UI 회귀 등 범위 내 gate도 면제하지 않는다.

## 보존 및 출시 경계

- 기존 capture archive·사용자 설정·route·이미 실행 중인 사용자 프로그램을 삭제하거나
  임의 종료하지 않는다. 이미 구현한 capture 코드와 검증·실패·보안 기록도 보존한다.
- 기존 read-only archive 접근이 구현돼 있어도 이번 마이그레이션의 필수 완료 조건이나
  새 hc terminal/provider session과의 자동 연결 근거로 삼지 않는다.
- hc launcher에는 capture route/env/runtime/helper를 연결하지 않는다. capture를 위해
  사용자 proxy를 자동 설치·시작·재시작하거나 provider credential을 복사하지 않는다.
- hc cutover 때 미지원 capture는 명확히 비활성/비노출 처리한다. 기능을 유지한다는
  이유로 legacy terminal backend를 fallback으로 되살리지 않는다. 현재 기본 legacy
  제품의 동작을 이번 문서 변경만으로 즉시 삭제하는 것은 아니다.
- 공식0.1.17의 caller env 평문 저장 관측은 유효한 보안 기록으로 남긴다. capture가
  연기됐다고 token/credential을 argv/env/labels/docs/로그에 넣는 것이 허용되지는 않는다.
- 이 범위 결정은 배포·설치된 앱/core 교체·사용자 서비스 변경·개인정보 권한 변경의
  승인이 아니며, 전체 마이그레이션이나 release가 완료됐다는 뜻도 아니다.
