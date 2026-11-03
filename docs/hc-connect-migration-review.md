# hc connect 전환 검토

## 결론

**전환 방향은 권장한다. 다만 transport만 바꾸는 drop-in 교체는 아니다.**

기존 herdr는 터미널 runtime + workspace/tab/pane + 에이전트 관찰을 제공했다. herdr-core는 runtime에 집중한다. SwiftUI/AppKit/SwiftTerm과 제품 기능은 유지하면서, 통신/attach는 hc로 교체하고 레이아웃 및 에이전트 관찰 책임을 앱으로 옮겨야 한다.

- 사용자 조건: 기존 기능 유지. 이전 데이터의 보존·마이그레이션과 구형 herdr 호환은 필수 아님.
- 권장: 이중 backend를 장기 유지하지 않고 새 core를 최소 지원 버전으로 고정한다.
- 데이터 마이그레이션은 생략할 수 있지만, 기존 파일·실행 중 터미널·사용자 CLI 설정을 자동 삭제하거나 재시작하는 것은 별개의 결정이다. 새 저장 namespace로 시작하고 기존 파일은 건드리지 않는다.
- 판정: 터미널/SSH 연결은 구현 가능성이 높음. **에이전트 상태·안전한 resume·native session 식별·프로세스 소유권은 기능 동등성 검증 전까지 전환 완료로 볼 수 없음.**

## 조사 범위와 근거

최초 검토는 정적 코드/스키마 조사이며 앱 또는 core를 실행하지 않았다. 조사 환경 PATH에는 hc/herdr-core가 없어 실제 wire/SwiftTerm 상호운용은 미검증이다. 설치·사용자 core 재시작·MCP 설정 변경은 하지 않았다. 이후 시작한 A1의 순수 codec 테스트 결과는 아래 구현 진행 절에 별도로 기록한다.

- 우리 프로젝트: HEAD `9f8c55a` 및 당시 작업 트리. 기존 수정 파일은 변경하지 않음.
- herdr-app: `f896da489de594fdb18a92a31dd953da3cf58da2`.
- herdr-core: `5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2`.
- core package version은 `0.1.16`이지만 HEAD 스키마는 `released.openrpc.json`과 다르다. 특히 observer `resize_notifications`를 0.1.16 릴리스의 기능으로 가정하면 안 된다.

주요 외부 근거:

1. [프로토콜·이벤트·문서 규약](https://github.com/herdrdev/herdr-core/blob/5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2/schema/README.md)
2. [OpenRPC 스키마](https://github.com/herdrdev/herdr-core/blob/5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2/schema/hc.openrpc.json)
3. [framing 및 flow control](https://github.com/herdrdev/herdr-core/blob/5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2/crates/herdr-core/src/wire.rs)
4. [terminal.read 구현](https://github.com/herdrdev/herdr-core/blob/5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2/crates/herdr-core/src/api.rs#L352-L405)
5. [전체화면 history stitching](https://github.com/herdrdev/herdr-core/blob/5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2/crates/herdr-core/src/stitch.rs#L168-L225)
6. [실제 앱의 hc client](https://github.com/herdrdev/herdr-app/blob/f896da489de594fdb18a92a31dd953da3cf58da2/src/hc.rs)
7. [실제 앱의 공유 레이아웃과 로컬 view 상태](https://github.com/herdrdev/herdr-app/blob/f896da489de594fdb18a92a31dd953da3cf58da2/src/mirror.rs)
8. [문서 CAS 처리](https://github.com/herdrdev/herdr-app/blob/f896da489de594fdb18a92a31dd953da3cf58da2/src/mirror_sync.rs)
9. [core 보안 경계](https://github.com/herdrdev/herdr-core/blob/5a9de29b2f9b6690388a1c297a7ca8d73df7d3e2/docs/security.md)

## 1. 연결과 attach: 가장 명확한 개선

### 현재

- `LocalHerdrTransport`: 기존 herdr socket API.
- `SSHHerdrTransport`: SSH direct-streamlocal로 요청별 채널, 구독 별도.
- `LocalTerminalSession`: pane별 로컬 PTY + `herdr terminal attach` 프로세스.
- `TerminalSession`: pane별 별도 SSH 연결 + 원격 PTY + attach 명령.
- `HerdrAttachInput`: attach CLI의 Ctrl+B prefix를 피하기 위한 입력 변환.

### 권장

- macOS 로컬: `Process`의 stdin/stdout pipe로 `hc connect`. PTY 아님.
- macOS/iOS SSH: 기존 Citadel 인증 및 host-key 검증을 유지하고, **PTY 없는 exec 채널**에서 원격 `hc connect`.
- 앱에서 설정한 endpoint/core session별 장기 연결 하나를 공유. channel 0은 RPC, 나머지는 attach/event stream.
- 이미 연결한 core가 관리하는 원격 machine은 `box/t7` 주소와 `on`을 통해 같은 연결로 접근.
- 앱 자체 SSH machine과 core-managed machine은 제품의 기존 두 접속 경로로 유지. 모든 SSH 자격증명을 core로 옮길 필요는 없다.
- vendored Citadel은 `Vendor/Citadel/Sources/Citadel/TTY/Client/TTY.swift:470`에 이미 bidirectional `withExec`이 있다. 새 SSH 라이브러리가 반드시 필요한 것은 아니다. 취소 및 버퍼 상한은 별도로 검증해야 한다.

직접 framed attach가 되면 클라이언트 측 `forkpty`, pane별 attach CLI, takeover, prefix 이스케이프는 제거할 수 있다. core가 프로그램을 실행하는 PTY 자체는 남는다.

### 반드시 구현할 wire 규칙

- plain JSON line의 `hello {framed:true, generation:1}` 응답 이후 framed로 전환.
- `[channel:u32LE][kind:u8][length:u32LE][payload]`, header 9 bytes, payload 최대 16 MiB.
- read 한 번이 frame 하나라는 가정 금지. hello 응답과 첫 frame이 한 read에 오는 경우도 보존.
- RPC 응답과 stream 구독 등록 사이에 도착한 초기 frame을 상한 있는 임시 큐에 보존. 취소/timeout 뒤 도착한 attach 결과의 채널도 닫기.
- event DATA 내부에서도 JSON line은 frame 경계를 넘을 수 있음.
- CREDIT는 네트워크 수신 직후가 아니라 실제 소비 후 반환. `AsyncStream.yield` 성공은 UI 소비 완료가 아니다.
- 초기 stream credit 256 KiB, core의 pending output 4 MiB 초과 시 backlog 대신 repaint. 이는 화면 복구이지 모든 과거 바이트를 기록한다는 보장이 아니다.
- 한 stream의 느린 소비가 RPC reader를 막지 않게 라우팅. per-stream 및 전체 메모리 예산, outbound queue 상한 필요.
- FOCUS/FACTS/RESIZE 반영. SwiftTerm에서 키를 인코딩한 DATA를 그대로 보내고 CLI용 Ctrl+B 변환은 제거.
- attach CLOSE는 detach, `terminal.kill`은 프로세스 종료. 연결 손실도 terminal 종료와 다름.
- `TerminalSessionProviding`은 focus/display/소비 ACK를 표현하도록 바뀌어야 함. 기존 start/write/resize/stop만으로는 새 규약을 충분히 표현하지 못함.
- SwiftTerm의 ANSI first paint, CAN 복구, kitty keyboard, OSC8, 마우스, IME, 색상, terminal query 응답 호환은 실증 필요.

## 2. 기능 매핑

| 현재 기능 | hc 경로 | 판정/추가 책임 |
|---|---|---|
| terminal 표시/키/resize | `terminal.attach`, DATA/RESIZE/FOCUS/FACTS | 직접 대체 후보. 렌더러 검증 필요 |
| 앱 종료 후 프로그램 유지 | attach CLOSE/연결 해제 | 유지 가능. core stop/kill과 혼동 금지 |
| pane/agent 목록 | `terminal.list/get`, `events.subscribe` | 레이아웃/에이전트 관찰을 합성해야 함 |
| workspace/tab/pane 생성·이름·배치 | `doc.get/set` + `terminal.run/kill/label` | 대응 고수준 API 없음. 앱 책임 |
| 여러 기기의 동일 workspace | 머신별 core document | CAS 충돌·재연결 정책 필요 |
| SSH 및 core-managed machine | SSH exec / `machine.*` / qualified address | 유지 가능. 인증·설치·재접속 UX 재연결 |
| 상태별 목록/알림/seen | OSC7501 + turn + 앱 상태 | 화면 추정·agent registry는 core에 없음 |
| Claude/Codex/Pi 관리형 시작 | `terminal.run` + 앱 launch coordinator | 기존 `agent.start`와 준비 완료 의미가 다름 |
| prompt 제출 | `terminal.send` | Enter 포함, 약 3초 quiet gate, blocked 거부 |
| 대화창에 문자만 입력 | attach DATA | `terminal.send`로 바꾸면 Enter가 추가돼 의미가 달라짐 |
| named key 입력 | `terminal.keys` | quiet gate와 키 표기 검증 |
| 특정 상태까지 대기 | 구독 기반 앱 predicate | `terminal.wait`는 임의 상태 집합 대기의 대체물이 아님 |
| foreground 프로세스 검사 | `Terminal.foreground` + 로컬 OS 검사 | 단일 leader만 있음. 기존 전체 목록/TTY 정보와 동등하지 않음 |
| native agent session ID / 안전한 resume | 앱별 adapter/native bridge | 현재 core 스키마에 session reference·interactive_ready 없음 |
| ANSI visible screen 검사 | observer+headless terminal model 등 | `terminal.read`는 plain text. 안전한 snapshot 대안 필요 |
| 모바일 최근 출력 | captured conversation/observer 우선 | `terminal.read(lines>0)`의 TUI 조작 의미 주의 |
| file preview/drop | 기존 SFTP/exec 유지 가능 | `file.read/terminal.put`는 후속 검토. 바이너리·크기 의미 검증 없이 교체 금지 |
| CEF/credential broker | 기존 네이티브 서비스 유지 | owner identity, launch/revoke 연결 재설계 |
| API proxy/captured conversation | 기존 별도 서비스 유지 | route 및 session 매칭을 새 identity로 변경 |
| 모바일 QR/Secure Enclave pairing | 기존 SSH pairing 유지 | herdr.sock/pane.list probe만 새 연결 검사로 교체 |

## 3. 앱으로 가져와야 하는 workspace 모델

core에는 workspace/tab/pane API가 없다. opaque JSON document와 CAS version만 제공한다.

권장 최소 모델:

- `WorkspaceDocument(schemaVersion, workspaces[])`
- workspace: UUID, 이름, 기본 cwd, tabs[]
- tab: UUID, 이름, pane layout tree
- pane: UUID, terminal 참조, 표시 이름
- terminal 참조: origin core ID + origin terminal ID. 경유 machine 이름은 라우팅 정보로 별도 관리.
- selection/focus/zoom은 device-local view 상태. 공유 문서 갱신으로 다른 기기의 focus를 빼앗지 않는다.

머신별 문서 이름 예: `3rdr-workspace-v1`. macOS와 iOS가 같은 schema/reducer를 ShepherdKit에서 공유한다.

규칙:

1. events 구독을 먼저 열고 문서를 읽는다.
2. `doc` 이벤트, 재연결, `missed`, 원격 machine 재연결 후 관련 문서를 다시 읽는다. terminal snapshot에는 document가 없다.
3. `doc.set(version:)` 충돌은 read/rebase 또는 사용자 충돌 처리. 최신 문서를 무조건 덮어쓰지 않는다.
4. 원격 문서가 없거나 읽기 실패라고 빈 레이아웃을 쓰지 않는다. unavailable과 empty를 구분한다.
5. document는 최대 1 MiB. schema와 terminal 참조 검증 필요.
6. `terminal.run`과 `doc.set`은 원자적 transaction이 아니다. 생성 성공/문서 실패 시 orphan terminal을 조정하고 사용자에게 복구 경로를 제공한다.
7. run/send 응답 손실을 실패 확정으로 보고 재실행하면 중복 프로그램/메시지가 생긴다. launch operation ID label과 fresh snapshot으로 조정하되 label을 권한 증거로 사용하지 않는다.
8. 탭 닫기도 layout 변경과 여러 terminal kill의 부분 성공을 처리해야 한다. 재시도 전에 정확한 identity와 상태를 재검증한다.

**별도 제품 결정:** 공식 herdr-app과 새 레이아웃까지 실시간 공유할 것인가?

자체 namespace는 우리 macOS/iOS 간 공유를 보장할 수 있지만 공식 앱의 `herdr-app` document와 같은 workspace는 아니다. 이는 과거 데이터 마이그레이션과 다른 문제다. 공식 앱과의 live layout 상호운용이 필수이면 공유 schema의 유지 계약과 mod node 처리까지 합의해야 한다. 초기 권장은 자체 문서와 core terminal 공유이며, 공식 앱 document에 임의로 쓰지 않는다.

## 4. 가장 큰 기능 동등성 과제: 에이전트 관찰

### 상태와 준비 완료

core는 OSC7501로 프로그램이 보고한 상태만 저장한다. 없는 상태를 화면에서 추정하지 않으며 `agent.list`, `interactive_ready`, `launch_pending`, `session_ref`를 제공하지 않는다.

현재 의존:

- `Shepherd/Agents/AgentLaunchState.swift:42`: CLI별 준비 완료.
- `Shepherd/Agents/AgentLaunchService.swift`: agent list/process info 기반 launch/resume/inspection.
- `ShepherdKit/Sources/ShepherdKit/HerdrKit/Models/AgentLaunchModels.swift`: native session 및 프로세스 정보.
- `ShepherdMobile/ConversationView.swift`: 상태 대기, prompt, native session 매칭.

권장 `AgentObservationService`는 다음을 분리한다.

- core raw status (프로그램이 보고한 말)
- 앱 display status (done/seen, 알림)
- interactive readiness
- native session reference
- authenticated process/session identity
- browser/MCP readiness

`terminal.run` 성공, working/idle, 프로그램 이름, label, 조용한 화면은 브라우저 승인이나 준비 완료 증거가 아니다.

관리형 agent에는 invocation-local hook/extension/native bridge를 활용할 수 있다. 사용자가 shell에서 직접 시작한 agent도 기존 지원 범위에 포함되므로, unmanaged 경로는 core OSC 지원 여부와 앱 관찰 대안을 별도로 검증해야 한다. 상태 미지원 agent를 전부 unknown으로 바꾸는 것은 기능 유지가 아니다. 사용자 글로벌 CLI 설정을 몰래 바꾸는 방식으로 해결하지 않는다.

### 실행 순서와 shell 의미

`terminal.run(argv:[agent...])`로 바로 바꾸면 기존 shell 초기화, shell로 복귀, 사전 terminal owner 예약 동작이 달라질 수 있다.

초기 전환은 기존 2단계 의도를 유지하는 편이 안전하다.

1. app launch reservation 준비.
2. `terminal.run`으로 shell 생성, 반환 terminal identity 확정.
3. workspace pane 및 native owner 연결.
4. 실제 shell foreground 확인 후 session-local shim 실행.
5. authenticated process/session 및 MCP 확인.

직접 agent 실행은 이후 별도 실험으로 검증한다. `keep:true`는 손실된 프로그램을 shell로 복구할 뿐, 정상 종료한 agent를 shell로 되돌리는 옵션이 아니다. 최초 spawn timeout도 이미 실행 중일 수 있으므로 맹목적 재시작 금지.

## 5. 프로세스·브라우저 권한의 identity

현재 `PaneProcessInfo`에는 shell PID, foreground process group, TTY, foregroundProcesses[]가 있다. core의 `Foreground`에는 leader의 pid/name/argv/cwd만 있다. shell wrapper, pipeline, node launcher에서는 같은 정보가 아니다.

- `PiLaunchCoordinator.swift:97`는 exact terminal/pane 및 전체 foreground 후보를 확인한다.
- `PiProcessIdentity.swift`는 OS의 PID/start/executable/argv/cwd와 동일 인스턴스 여부를 검증한다.
- `PiHostBridge`는 실제 peer PID와 준비한 launch/session을 묶는다.

따라서 단일 foreground PID로 기존 구조를 채우고 나머지를 추정하면 안 된다. 로컬 macOS에서는 OS 기반 foreground group 검사 또는 준비된 shim의 native handshake를 추가 설계해야 한다. 비관리형 agent·remote session naming 경로에 필요한 관찰 범위도 남는다. 필요하면 core의 일반적인 process/terminal inspection 확장을 검토하되 vendor-specific session 관찰은 앱에 둔다.

identity를 분리한다.

- layout pane ID: 앱이 정한 UUID.
- runtime terminal identity: origin core의 영속 ID + origin terminal ID.
- connection epoch: 연결 재수립/채널 번호 재사용 구분.
- launch/process instance: launch ID + PID/start evidence + native session ID.
- browser route lease: 해당 process/session의 현재 승인.

`hello.generation`은 API 세대이지 프로세스 재시작 횟수가 아니다. core ID도 영속적이므로 연결 epoch나 launch instance를 대신할 수 없다. `keep` 복구 후 terminal address가 같아도 프로그램은 새 shell이다.

연결 손실, `lost/restarted`, session switch, 프로세스 교체 시 기존 lease를 정지/퇴역하고 검증 후 새 binding을 만든다. UI 탭 재배치와 프로그램 교체를 혼동하지 않는다. core의 active viewer가 되었다고 브라우저 권한이 생기지 않는다.

기존 This Mac-only browser/credential 정책, 사용자 승인, child의 별도 reservation, fail-closed 원칙은 유지한다. core API는 같은 계정의 shell 권한이며 per-client authorization을 제공하지 않는다. raw core API를 브라우저/MCP 경계 밖으로 그대로 공개하지 않는다.

## 6. ANSI 검사와 모바일 읽기의 함정

`terminal.read`의 결과는 text/complete/how/why이다. ANSI format 옵션이 없다.

우리의 `AgentIdleStopPolicy.swift`는 Codex의 dim SGR placeholder와 사용자 draft를 구분한다. plain text로 대체하면 빈 입력창 증거가 사라진다. `AgentSessionNaming.swift:309`도 같은 종류의 검사를 사용한다.

대안 후보:

- 현재 attach의 terminal model을 구조화된 화면/속성 snapshot으로 읽기.
- 비표시 pane은 `observe:true` attach + headless terminal model로 관찰.
- native agent API가 검증 가능한 empty editor/session 정보를 제공하면 그 증거를 사용.
- 필요한 최소 screen snapshot 기능을 core에 제안.

observer first paint 완료/일관된 snapshot 시점과 resize 전후 상태를 검증해야 한다. 조사 HEAD의 `resize_notifications`는 미릴리스 스키마 변경이므로, 실제 배포 버전 협상과 fallback 정책이 필요하다. **지원하지 않으면 추정하여 stop/resume하지 않는다.** 임시 차단은 안전 조치지만 최종 기능 동등성을 충족한 것으로 세지 않는다.

또한 `terminal.read(lines>0)`는 alternate-screen 앱에서 wheel 입력으로 history를 수집하고 되돌릴 수 있다. 현재 `ConversationView.reload`의 자동 읽기에 그대로 연결하면 사용자 화면·입력 타이밍에 영향을 준다.

- 화면 조회에는 `lines:0` 검토.
- 자동 conversation 읽기는 기존 captured conversation 또는 passive observer 기반을 우선.
- 과거 TUI history의 passive 수집이 부족하면 core API 보완을 검토. 사용자 동작을 유발하는 읽기를 숨겨서 넣지 않는다.
- `terminal.send`는 항상 제출까지 한다. 현재 `paneSendText`의 Enter 없는 입력과 분리해야 한다. raw DATA를 위한 attach는 비-observer이므로 size/focus 정책도 필요하다.

## 7. 보존 가능한 주변 기능

- CEF engine, file link policy, preview UI, credential broker 자체는 전면 재작성 대상이 아님.
- SFTP file preview와 기존 SSH file drop도 우선 유지 가능.
- QR pairing, Secure Enclave key, host key 검증은 유지. `PairingPreflight`의 herdr.sock 검사와 `SSHPairedMacChecker`의 pane.list probe 변경.
- API proxy/대화 capture의 별도 read-only socket은 유지. `HerdrTransport.openLineStream`을 core transport와 분리된 host service에 두면 결합도를 낮출 수 있음.
- `AgentProxyService+System.liveTerminals`는 `terminal.list` 및 fresh core identity 기반으로 변경. unreachable을 empty로 바꾸어 route를 정리하면 안 됨.
- `runtime-core.mjs`의 `herdr agent start`, `w*:p*`, `HERDR_SOCKET_PATH` 파서, child rewrite는 새 launch contract로 교체. 부모 descriptor를 자식에게 전달하는 shortcut은 불가.
- SwiftTerm 렌더링은 유지하되 직접 core first paint와의 호환성 테스트를 통과해야 함. Ghostty renderer 이식은 이번 범위에 넣지 않음.

## 8. 권장 구성 (제안, 아직 구현하지 않음)

ShepherdKit:

- `CoreWireCodec`: bounded incremental frame decoder/encoder.
- `CoreConnection`: hello/RPC/stream router/epoch/cancellation.
- `CoreEndpoint`: local process pipes 또는 SSH exec byte transport.
- `CoreEventStore`: snapshot + ordered delta + missed/reconnect reducer.
- `CoreTerminalSession`: attach lease, DATA, consumer ACK, resize/focus/facts.
- `WorkspaceStore`: document CAS + layout reducer + local view state.
- `AgentObservationService`: status/readiness/session 정보, capability별 provider.

macOS:

- 기존 terminal view에 CoreTerminalSession 연결.
- native process/launch inspector와 브라우저 lease coordinator 갱신.
- CEF, broker, proxy는 새 identity contract를 소비.

iOS:

- 같은 wire/event/workspace 모델 사용.
- SSH endpoint, terminal UI, conversation UI, pairing probe 갱신.

범용 다중 백엔드 프레임워크는 만들지 않는다. 기존 DTO를 UI projection으로 잠시 유지할 수는 있지만 가짜 `interactiveReady=true` 등의 legacy field 합성은 금지한다.

## 9. 구현 순서와 통과 조건

### A. 제한된 protocol spike

실제 사용자 session과 분리된 scratch HOME/XDG/HC_SESSION에서만 실행. 실제 agent 계정 호출 없이 fixture shell/TUI로 검증.

- local pipe hello/framing/list/run/attach/input/resize/close.
- SSH exec에서 같은 동작, host-key pin 검증 유지.
- SwiftTerm first paint, scrollback, CJK/IME, OSC8, kitty keyboard, 마우스, theme.
- 대량 출력에서 CREDIT 및 bounded memory, 느린 pane이 다른 pane/RPC를 막지 않음.
- partial/coalesced frames, oversized payload, half-frame EOF, timeout, late reply, cancellation.
- 동시에 여러 attach, reconnect, terminal exit/kill/loss/restart 구분.

A 통과는 연결 가능성 검증이지 제품 전환 완료가 아님.

### B. 기능 동등성 위험 spike — 대규모 UI 이식 전에

- 지원 CLI 버전별 managed/unmanaged OSC 상태와 준비 완료 검증.
- session ID, safe rename/resume, empty composer 증거.
- Pi의 foreground binding/argv rewrite/peer PID/session retirement.
- terminal.read를 대체한 passive mobile reading.
- 앱 종료 후 agent 지속, agent 종료 후 기존 shell 동작 유지.

이 단계에서 core API 확장이 필요한지 결정한다. 기능이 빠져도 전환 완료로 처리하지 않는다.

### C. workspace/event 전환

- 새 문서 schema 및 local focus.
- macOS/iOS 동시 편집 CAS, 원격 disconnect/missed 재동기화.
- 생성·닫기 부분 실패/응답 손실 조정.
- status/seen/notification dedup 및 재접속 baseline.

### D. launch/browser/proxy/mobile 통합

hc 감지·설치·호환성 안내도 필수 완료 조건이다(SHPHRD-153):

- GUI PATH 및 일반 설치 위치 탐색 → 실행/hello 호환성 확인 → 기존 호환 core 재사용.
- 미설치 시 앱 설치 안내·사용자 승인 → 공식 설치 경로 → 재탐색·검증·연결.
- core가 너무 오래됐거나 기능 부족이면 core 업데이트, 지원보다 새 API generation이면 앱 업데이트 안내.
- 실패/오프라인 시 오류·재시도·직접 설치 경로. package-manager 설치를 덮어쓰거나 기존 core/agent를 임의 종료하지 않음.
- 설치/업데이트와 실행 중 core 재시작은 분리. 기존 원격 setup에도 연결하며 iOS에 로컬 hc를 설치하지 않음.
- 독자적인 대형 설치 시스템이 아니라 공식 경로 재사용. 아래 통합 작업과 함께 검증하며 아직 미구현.

- 예약→terminal→process/session→MCP 순서의 owner proof.
- 이전 lease/route 재사용 차단, core가 terminal ID를 유지한 채 shell을 복구하는 경우.
- child rewrite, native session naming, proxy conversation mapping.
- pairing/SSH/remote file 기능 회귀.

### E. 기존 backend 제거

A–D 통과 후 기존 pane/session socket API, attach CLI/PTY 경로, prefix 우회, 버전 fallback을 제거한다. 신규 저장 영역으로 시작하고 legacy 파일은 자동으로 지우지 않는다.

## Plane 등록 및 첫 구현

워크스페이스 `bldg-7`, 프로젝트 `shepherd` (`SHPHRD`). Epic 타입이 플랜에서 지원되지 않아 일반 상위 작업과 하위 작업으로 등록했다.

| 작업 | 범위 | 현재 상태 |
|---|---|---|
| SHPHRD-148 | 전체 hc 단일 backend 전환 | 진행 중 |
| SHPHRD-149 (A1) | bounded wire/event codec, hello 협상, 격리 테스트 | 구현·테스트 완료 |
| SHPHRD-150 (A2) | local/SSH endpoint, RPC/attach/events/CREDIT, SwiftTerm 검증 | 고정 #14711 백포트로 검증 완료; 공식 0.1.16은 여전히 부적합 |
| SHPHRD-151 (B) | agent/session/process/screen 기능 동등성 | 진행 중 — 로컬 kernel foreground 관찰 검증; 전체 parity 미완료 |
| SHPHRD-152 (C) | workspace CAS 및 이벤트/알림 | 대기 |
| SHPHRD-153 (D) | launch/browser/proxy/mobile 통합 | 대기 |
| SHPHRD-154 (E) | 회귀 및 legacy 제거 | 대기 |
| SHPHRD-155 | first-party Swift 6 통일 및 기반 코드 커밋 | 완료 — `4e00351` |
| SHPHRD-157 | core/libghostty VT first paint의 OSC8 cell metadata 보존 | 기존 upstream #14711 백포트로 해결·검증; 전역 설치/배포 없음 |

의존 관계: 149 → 150 → (151, 152) → 153 → 154.

A1은 `ShepherdKit/Sources/ShepherdKit/CoreKit/`의 세 파일이며 기존 app backend에는 연결하지 않았다. 사용자 요청에 따라 SHPHRD-155에서 first-party 앱 타깃과 ShepherdKit/AgentProxy package 및 관련 runner를 Swift 6로 통일한다. Vendor 패키지의 언어 모드는 그대로 둔다. `Tests/CoreProtocol/run-tests.py`는 현재 Swift 6(패키지와 동일 upcoming flags) 빌드·실행과 iOS 17 Simulator 대상 typecheck만 수행한다. Python 독립 wire vectors 12개와 18개 테스트 그룹을 검증한다. 이후 A2에서 채널 routing과 소비 후 ACK를 구현했다. byte codec 자체는 여전히 CREDIT를 자동 전송하지 않는다.

최초 Swift 5/6 양쪽 모드 검증 artifact는 `/private/tmp/shepherd-hc-wire.wWY6A3/run/validation.json`이며 역사적 결과다. Swift 6 전용 runner 통과 artifact: `/private/tmp/shepherd-swift6-wire.RxRZYz/run/validation.json`. 당시 실제 hc/SSH/SwiftTerm 상호운용은 미검증이었다. 이후 로컬 hc 검증은 아래 A2 추가 구현 절에 구분한다. 재현 방법과 상세 범위: `Tests/CoreProtocol/README.md`.

Swift 6 전환에서 mutable SSH authentication delegate 공유를 없애고 immutable key/password를 캡처하는 Sendable factory로 바꾼다. Citadel의 legacy 비-Sendable async API는 연결을 소유하는 네 actor 파일에서만 `@preconcurrency import Citadel` 경계를 명시한다. 이는 Citadel 전체가 Sendable이라는 선언이 아니며 vendor의 모든 동시성 경고가 해소됐다는 뜻도 아니다. 앱/패키지의 Swift 6 검사 수준은 낮추지 않는다.

### Swift 6 전환 검증 (SHPHRD-155)

- macOS `Shepherd` Debug unsigned build 통과. 오래된 로컬 CEF 산출물은 이미 내려받은 고정 distribution에서 `scripts/cef.sh`로 재생성했다. 앱 실행·설치·배포는 하지 않았다.
- `Shepherd Mobile` Debug iOS Simulator unsigned build 통과.
- CoreProtocol: Swift 6 18개 그룹 / 2,397 assertions, Python wire vectors 12개, iOS 17 typecheck 통과.
- AgentProxyCore: Debug/optimized 각각 5,837 checks, iOS typecheck 통과 (`/private/tmp/shepherd-swift6-proxy.bXSjVm/run`).
- Conversation client/model: Debug/optimized 각각 18/9 checks 및 iOS 17 typecheck 통과.
- Conversation DB: Debug/optimized synthetic tests 통과 (`/private/tmp/shepherd-swift6-db.uDGYFJ/run`).
- Pairing: core 359 / SSH 33 checks 통과 (`/private/tmp/shepherd-swift6-pairing.PoIkWz/run`). 실제 서버/키체인/사용자 키에 접속하지 않았다.
- File drop: owned fixtures 9 stages 통과 (`/private/tmp/shepherd-swift6-drop.z2wMw9/run`).
- File preview: remote reader/model/pane-state 테스트는 통과했으나 derived panel UI의 스크롤 유지 assertion에서 실패 (`/private/tmp/shepherd-swift6-preview.Z2pPdN/run`). 전체 suite 통과로 기록하지 않는다. HEAD `9f8c55a` 소스의 별도 비교 실행도 scroll restoration assertion에서 실패했으나 메시지는 달랐다 (`/var/folders/tt/vcy538pn26v6r2km0psjrg0h0000gn/T/shepherd-preview-head-baseline.7eegabab`). 같은 원인이라 단정하지 않고 Plane 후속 작업으로 조사한다.
- 변경한 다른 장시간 runner와 실제 CEF browser self-test는 모두 실행한 것이 아니다. Debug self-test의 non-Sendable JSON continuation/Task 결과는 String 또는 Sendable scalar로 고쳤으며 제품 빌드로 컴파일을 검증했다.

### A2 첫 구현: RPC 상관관계와 수명 상태

`CoreRPC.swift`에 한 connection epoch의 요청 등록/응답 매칭, 정확한 UInt64 ID, typed result, deadline/cancel/close 처리를 구현했다. 취소·timeout된 요청의 metadata는 제한된 tombstone으로 유지하여 늦은 attach 응답도 원래 method와 연결한다. slot/payload quota와 ID 고갈을 처리하고, 잘못된 응답으로 active waiter 목록을 잃지 않는다. raw server message/hint는 error 상태에 노출하지 않는다.

이 첫 구현의 `CoreRPC.swift` 자체는 순수 상태 관리다. 이후 추가한 live local 연결은 다음 절과 같으며, 그 뒤 SSH/attach/CREDIT/orphan channel 정리까지 추가했다(아래 검증 절). 요청 취소나 timeout을 원격 rollback으로 해석하지 않으며 자동 재시도하지 않는다. `CoreRPCTests.swift`와 Python UInt64 교차 검증을 기존 Swift 6 runner에 추가했다. Swift 6 테스트/빌드와 iOS 17 typecheck의 5 stages 및 macOS 앱 unsigned Debug build가 통과했다 (`/private/tmp/shepherd-hc-rpc.PC8W24/run/validation.json`). SHPHRD-150 전체를 완료 처리하지 않는다.

### A2 추가 구현: 실제 local process 연결

- `CoreByteTransport`는 single-use transport 계약이다. local 구현은 `CoreProcessTransport`, live channel-0 소유자는 `CoreRPCConnection`이다.
- 로컬 child를 POSIX spawn + 비차단 stdin/stdout pipe로 실행한다. PTY나 shell을 거치지 않고 caller가 지정한 환경/cwd만 전달한다. stderr는 별도 경로에서 제한된 양씩 읽어 버리며 내용은 로그에 노출하지 않는다.
- stdout은 consumer의 read 요청이 있을 때만 읽는다. writer의 bytes/count admission은 GCD 큐에 넣기 전 lock으로 제한하고, frame 단위 쓰기를 직렬화한다.
- hello/RPC continuation, deadline, cancel, EOF/프로토콜 실패, 명시적 close를 연결했다. 미전송 큐의 취소/만료 요청은 제거한다. 이미 전송을 시작한 frame은 개별 RPC 취소로 끊지 않으며 remote rollback이나 자동 재시도를 가정하지 않는다.
- 종료는 해당 미회수 connect child에 한정한다. PID/start evidence를 재검사하고 fd close와 waitpid 회수까지 기다린다. process group이나 core daemon은 kill하지 않는다. 종료 확인이 안 되면 supervisionLost를 반환한다.
- `terminal.attach`/`events.subscribe`는 현재 generic RPC에서 전송 전에 명시적으로 거부한다. 별도 stream ownership 없이 임의 nonzero 채널을 받아들이지 않는다.
- Python 독립 peer를 실제 pipe child로 실행하여 split hello, 역순 응답, late cancel/timeout, stderr flood, 마지막 응답/EOF, malformed payload, EPIPE, blocked writer, SIGTERM/EOF 무시 child의 회수를 검증한다. 네트워크는 sandbox로 금지한다.
- 실제 `herdr-core 0.1.16` macOS ARM64 배포 archive를 checksum 검증 후 임시 폴더에만 추출하는 opt-in runner를 추가했다. 별도 HOME/XDG/HC_SESSION/HC_SOCKET과 private Unix socket만 허용하는 sandbox를 사용한다. TCP 거부는 owned ephemeral listener로 검증한다. archive hash는 무결성 확인이지 독립 서명 검증은 아니다.
- 실제 core smoke는 hello/status/list, doc CAS와 conflict, Double 정밀도를 넘는 UInt64, connect child를 닫아도 core PID/document가 유지되는 재접속, 해당 isolated core의 stop 및 소켓 제거·daemon 종료를 확인한다. 사용자 core/설정/agent/자격증명과 installed hc는 사용하지 않는다.

검증 결과:

- fixture suite: 7 stages 통과. wire/hello 2,397 assertions, RPC 67 assertions, 실제 pipe child 연결 65 assertions. Swift 6 및 iOS 17 typecheck 포함 (`/private/tmp/shepherd-hc-local.praDMn/run/validation.json`).
- 실제 0.1.16 core: 별도 smoke 통과. private core stop 응답, daemon 종료, connect child 회수, socket 제거 확인 (`/private/tmp/hc-real.3JlKCh/run/validation.json`). 같은 폴더에 archive/binary hash, 소스 hash 및 core-report 보존.
- macOS `Shepherd` 및 iOS Simulator `Shepherd Mobile` unsigned Debug build 통과. 코드 변경 후 최종 검증과 현재 source hash 일치 확인.

실행 방법과 검증 artifact 형식은 `Tests/CoreProtocol/README.md`에 기록했다. 앱 UI의 기존 backend는 아직 그대로다. 이 시점 이후의 SSH/stream 구현 및 실제 호환성 gate는 다음 절에 기록한다.

### A2 SSH/stream 구현과 실제 호환성 차단

- `CoreSSHTransport`: SwiftNIO/NIOSSH의 실제 SSH authentication/exec. 명시적 host-key pin과 fresh auth factory, no PTY, shell-quoted 환경/실행 파일, inherited core terminal identity 제거. 저장된 자격증명이나 SSH config를 직접 읽지 않는다. paired address policy는 기존 machine factory에서 적용한 뒤 전달해야 한다.
- 채널 initializer의 lifetime guard로 취소 후 늦은 TCP/session 완료가 권한을 되살리지 못하게 한다. read demand와 `autoRead=false`, event-loop에서의 동기 bounded queue로 중간 unbounded AsyncStream을 만들지 않는다. close는 idempotent이며 shutdown한 EventLoop에 deinit이 다시 작업을 보내지 않는다.
- `CoreStream`/`CoreRPCStreams`: RPC 응답을 caller에 노출하기 전에 채널을 원자적으로 등록. reply+DATA가 한 read로 와도 보존하며 실제 wire 계약을 어기는 pre-reply data는 fail-closed. 최대 stream/packet/byte 수, 압축된 used-channel interval 상한, epoch/nonce 검사.
- DATA 처리 후 명시적 receipt ACK에만 CREDIT 반환. 중복/다른 채널 receipt 거부. 600,000-byte 출력과 stalled stream 중 RPC 처리 검증. RESIZE/FOCUS/FACTS/CLOSE, observer input 차단, late timeout/cancel open의 CLOSE, read/close deadline 처리.
- 새 SSH connection/epoch에서 reattach해 기존 terminal의 first paint를 받고 옛 handle의 입력을 거부한다. 변이 요청이나 브라우저/credential 권한을 자동 재생하지 않는다.
- 독립 fixture 최종 run: 7 stages 통과, wire/hello 2,397 + RPC 67 + connection/stream 110 assertions (`/private/tmp/hc-streams.xrhvot/run/validation.json`).
- macOS 및 iOS Simulator 앱 unsigned Debug build 통과. 제품 UI backend는 아직 전환하지 않았다.

실제 통합은 `run-ssh-stream-tests.py`로 검증했다. 임시 localhost SSH server + pinned 공식 core + 실제 SwiftTerm view를 사용한다. 서버는 생성한 host key/fixture password를 쓰고, 오직 미리 정한 quoted exec 명령만 private shell에서 실행한다. 외부 사용자 서버/계정/agent에 접속하지 않는다.

**실제 통합 전체 gate는 실패다.** `/private/tmp/hc-ssh.p4YctX/run/validation.json`은 `passed: false`, `blocker: SHPHRD-157`이다. SSH, 취소, CJK/emoji, SGR, 실시간 OSC8, IME, kitty Ctrl+B, raw Ctrl+B-q, SGR mouse, resize, display query, 대량 출력 CREDIT, events, observer 제한, reconnect 및 cleanup의 나머지 31 checks는 완료했다. 테스트 core 종료와 socket 제거, SSH worker 정리도 확인했다.

실패 원인: official core 0.1.16의 first paint에는 링크 label만 있고 OSC8 destination이 없다. git tag `v0.1.16` (`e07c2a1bedd62cf4787ee026ee23ee79c7d95491`)의 Ghostty gitlink `1e5cdb865807abc990181efb8ebfa9122955cce2`를 확인했고, 해당 formatter는 per-cell hyperlink를 HTML에만 출력한다. VT cursor의 active hyperlink 복원 옵션으로는 이를 보존할 수 없다. 실시간 OSC8는 동일 경로에서 통과한다.

상세 재현·source 근거·수정 조건: [hc-osc8-first-paint-blocker.md](hc-osc8-first-paint-blocker.md). 이 assertion은 삭제하지 않고 다른 체크/정리 후에도 최종 nonzero exit로 유지했다. **core/formatter 수정과 재검증 전에는 SHPHRD-150을 완료하거나 UI를 새 backend로 전환하지 않는다.** upstream 수정/배포 또는 관리할 patched-core 선택이 필요하다. 사용자 core를 임의로 교체하지 않았다.

### A2 차단 해소: 기존 upstream OSC8 수정 백포트

새 upstream 구현이 필요하다는 초기 판단은 정정한다. Ghostty #14711은 이미 2026-10-15에 머지됐으며, release-pinned Ghostty에 원본 patch가 그대로 적용된다. `formatter.zig` 하나만 변경하고 Rust/C ABI/wire/Cargo.lock은 유지했다. 격리된 Rust 1.95.0·Zig 0.16.0으로 빌드했다.

- `Tests/CoreProtocol/backport/`: 고정 recipe, upstream patch/라이선스, build/test receipt 생성과 재현 절차.
- 백포트 실제 SSH/core/SwiftTerm: 최초 attach·live·새 SSH 재접속의 OSC8 URI 모두 보존, 전체 gate 통과. 기존 32 checks와 BURST-DONE 재표시 검사 유지 (`/private/tmp/qualified-backport-ssh.TbWItL/run/validation.json`).
- 공식 0.1.16 대조군: 최초 attach/재접속 링크 모두 실패하고 최종 exit 1 유지 (`/private/tmp/final-official-ssh-negative.oVTIqW/run/validation.json`).
- 양쪽 모두 owned core/holder/terminal 종료와 소켓 제거 확인. 사용자 core/자격증명/전역 설정은 사용하지 않았다.
- upstream formatter 309 tests, Rust VT 10 tests, core library 89 passed/1 ignored(별도 child helper 1 test 실행), artifact 검증 14 tests 통과. 독립 Swift 6 fixture 7 stages와 iOS 17 typecheck 재통과.
- 백포트 local RPC smoke도 통과 (`/private/tmp/qualified-backport-rpc.F0pbDe/run/validation.json`).

상세 hash·범위: [hc-osc8-first-paint-blocker.md](hc-osc8-first-paint-blocker.md). 버전 문자열은 여전히 0.1.16이므로 검증된 binary hash/receipt 또는 향후 검증한 공식 고정 릴리스로 구분해야 한다. 임의의 installed 0.1.16을 승인하지 않는다. 제품 backend와 사용자 daemon은 교체하지 않았다.

관련 Ghostty #14725는 blank gap/erased background/wrap 복원 개선으로 검토했으나 최소 OSC8 백포트에는 포함하지 않았다. 해당 TUI 보존 사례는 B의 화면·에이전트 기능 동등성 검증에 포함해야 한다. A2 완료를 B–E나 배포 완료로 해석하지 않는다.

### B 첫 구현: 로컬 foreground 그룹 관찰

`CoreLocalForeground.swift`는 명시적으로 지정한 This Mac의 PTY/session leader를 kernel PID/start/parent/session/tty로 고정하고 foreground process group 전체를 조회한다. 최대 256개, 이중 membership/fingerprint 검사, 변경·초과·소멸 시 fail-closed. argv/environment나 전체 프로세스 목록은 읽지 않고, tty를 열거나 signal/job-control을 변경하지 않는다. 단일 leader로 full foreground list를 꾸미지 않으며 leader가 종료된 그룹도 실제 남은 구성원을 반환한다.

이는 관찰이지 권한 부여가 아니다. PID/start가 같은 exec도 가능하므로 `isShellForeground` 대신 `isAnchorOnlyForeground`로 명명했다. 기존 native peer/정확한 argv/session/exec-exit watcher 검증은 그대로 필요하다. iOS/원격 PID에는 이 inspector를 적용하지 않는다. 아직 앱의 기존 launch coordinator를 교체하지 않았다.

- 격리 PTY의 두 worker·leader 종료·그룹 복귀·anchor 소멸·위조 start/session/tty·quota를 Debug/optimized 각각 27 checks로 검증 (`/private/tmp/hc-observation.r1zTVw/run`).
- 실제 owned hc의 run PID도 anchor 생성과 SSH 재접속 후 동일 인스턴스 관찰 통과. 기존 OSC8 포함 전체 34 checks 통과 (`/private/tmp/hc-native-ssh.WYDBW2/run`).
- macOS/iOS Simulator unsigned Debug build 통과 (`/private/tmp/hc-observation-build.OFDajs/`). 사용자 core/agent/자격증명/전역 설정은 변경하지 않았다.

다음은 managed/unmanaged readiness/session, passive attributed screen 및 observer resize/초기 snapshot 경계다. 공식 0.1.16의 size event를 stream 순서 보장으로 간주하지 않는다. B 전체는 미완료다. 자세한 검증·제약은 `Tests/CoreObservation/README.md`에 기록한다.

### B 추가 구현: passive attributed-screen 후보

`CorePassiveScreenSequence`에 observer resize 협상, 초기 RESIZE 선행, packet epoch/channel/nonce와 순서, zero/oversized viewport 거부를 구현했다. control frame에도 provenance/ordinal을 붙여 연결이 바뀐 뒤 같은 channel 번호의 오래된 RESIZE를 받아들이지 않는다. 최대 dimension 2,048 / visible cells 262,144다. 이는 전체 parser/image/scrollback 메모리 상한이나 snapshot-complete/ready/empty-editor 증거가 아니다.

별도 후보에는 기존 upstream `5a9de29`의 observer resize/repaint 순서와 Ghostty #14725를 원본 그대로 추가했다. 기존 최소 OSC8 artifact는 보존했고 launchd 등 무관한 HEAD 변경은 가져오지 않았다. `Tests/CoreObservation/backport/`의 source-file hash recipe와 builder/validator/log hash receipt로 구분한다.

- formatter 321, Rust VT 10, core library 95 passed/1 ignored 및 notice 재생성 통과.
- 실제 passive SwiftTerm 33 checks 통과: initial/resize/headless geometry, blank gap, background-only row, dim, CJK/emoji, OSC8, program input=0 (`/private/tmp/candidate-passive-final.SoWGIV/run`).
- 원래 #14711-only build는 passive gate에서 resize 협상 부재로 exit 1을 유지하며 cleanup 완료 (`/private/tmp/baseline-passive-negative.YKeITx/run`).
- 후보와 기존 OSC8 build 모두 전체 SSH/SwiftTerm 34 checks 재통과. 독립 protocol 7 stages / connection-stream 140 assertions, macOS/iOS unsigned build도 통과.

아직 앱 backend/launch coordinator에는 연결하지 않았다. 실제 agent readiness/session, native owner integration, 초기 attributed snapshot의 완료 증거와 safe resume, remote/multi-hop 전체 및 배포는 별도 검증이다. synthetic fixture의 PAINT-DONE marker를 실제 CLI에도 있다고 가정하지 않는다. B는 계속 진행 중이다.

### B 실제 CLI 시작·세션 관찰 (명시적 허용 후)

기존 계정/자격증명/부모 descriptor 없이 별도 HOME과 OS sandbox에서 설치된 CLI를 실제 실행했다. 버전은 Claude Code 2.1.317, Codex 0.166.0, Pi 1.4.0이며 예전 2.1.288/0.154.0의 동작 증거를 그대로 승계하지 않는다. 모델 프롬프트·로그인·약관 확인·브라우저 권한 부여는 하지 않았다. Pi에는 문서화된 로컬 `/new` 명령만 보냈다.

- 파일/네트워크 canary와 버전/help 6회 검증 통과. 원래 설정 내용과 keychain/pasteboard 서비스는 차단했다. core/CLI가 동일 정책을 상속하며 private Unix socket과 PTY 생성만 예외로 둔다. 이는 모든 same-user tty나 악성 바이너리에 대한 완전한 VM 격리 주장이 아니다.
- Claude 일반 모드는 Anthropic 서비스 접속 불가로 exit 1. `--bare`는 온보딩 테마 화면과 resize까지만 관찰했고, 준비 완료로 간주하지 않았다. 이 private terminal은 cancel keys 뒤 명시적 kill이 필요했다.
- Codex `--no-daemon`은 관리형 환경설정 동기화에서 중단됐다. hc 없는 별도 owned PTY에서도 같은 오류를 재현했으므로 hc 회귀로 단정하지 않는다. 정책/보안 서비스 접근을 풀거나 기존 관리자 설정을 우회하지 않았다.
- Pi는 실제 TUI와 자동 OSC7501 idle, resize, 정상 종료를 관찰했다. native session_start → before_switch → old shutdown → new session_start의 ID 변화가 있었지만 kernel PID/start와 core terminal은 그대로였다. **core/PID/idle만으로 이전 native/browser lease를 유지하면 안 된다는 실증**이다. ctx.model 객체 존재도 사용 가능한 모델/인증을 뜻하지 않았다.

최종 artifact: `/private/tmp/hc-cli-final.m6lBLZ/{inventory,startup,control}/`. 관찰과 Pi lifecycle smoke는 통과했고 전체 agent parity/authenticated readiness는 false로 유지했다. 모든 owned 프로세스/소켓 정리 완료. 상세 경계·재현·제약: `Tests/CoreObservation/CLI-README.md`.

이 허용 범위로는 Claude의 온라인 시작 및 인증된 작업 상태, Codex의 정상 managed-preference 경로, 각 CLI의 safe resume/생산 native bridge binding을 완료 처리할 수 없다. B는 계속 진행 중이며 앱 backend와 사용자 core는 변경하지 않았다.

### 공식 0.1.17 재검증 및 설치 UX 범위 명시

공식 manifest/tag 확인 후 macOS ARM64 archive를 별도 SHA256 `cedbd4d4d9ba1385588198dd4d3c67d2654478f33add5b6445d4d0eb9da5fcf3`로 고정해 임시 경로에서 재검증했다. 기존 0.1.16 pin/negative control은 그대로 유지한다.

- 로컬 hello/RPC/doc CAS/UInt64/reconnect/stop: 통과 (`/private/tmp/hc017-rpc.ekeZX7/run`).
- SSH/native SwiftTerm: live OSC8는 통과하지만 initial/reconnect OSC8는 여전히 실패 (`/private/tmp/hc017-ssh.mGBQVx/run`). 실패를 정상 성공으로 바꾸지 않았고 exit 1 유지.
- passive: observer resize 협상은 true로 개선됐다. 그러나 빈 칸이 앞선 배경색을 물려받는 formatter 문제에서 실패 (`/private/tmp/hc017-grid.yXOfxm/run`).
- 같은 수정된 harness에서 기존 고정 패치 candidate의 SSH/passive positive control은 통과. 즉 observer 백포트는 0.1.17에서 불필요하지만 Ghostty formatter 수정은 아직 필요하다.
- 이 검증은 명시적 `SSH_CONNECTION=owned-fixture-no-launchd`로 direct/SSH 시작 경로를 사용했다. 전역 launchd job 생성·청소를 피하며, 0.1.17의 launchd 앱 생존성 수정까지 검증했다고 주장하지 않는다. 모든 테스트 소유 프로세스/소켓은 정리했다.

hc 탐색→사용자 승인 설치→재검증/연결, 버전 호환성·실패/재시도 안내를 SHPHRD-153 완료 조건으로 추가했다. 전역 설치나 앱 backend 전환은 하지 않았다. VM/실제 계정/유료 모델 호출을 독립적인 workspace 구현의 선행 조건으로 두지 않는다.

## 최종 권고

장기 목표는 **hc 단일 backend + 앱 소유 workspace + 독립적인 agent observation/authority**로 정한다. 이전 데이터 마이그레이션을 하지 않는 조건은 이 방향을 단순하게 만든다.

첫 구현 단위는 A의 wire/attach spike와 B의 agent identity·screen observation 검증이다. 두 가지를 확인하기 전에 HerdrClient의 메서드 이름만 일괄 치환하거나 앱 전체를 먼저 이식하지 않는다. 비용의 중심은 framing보다 기존 core가 대신하던 agent 기능과 workspace 책임을 옮기는 데 있다.
