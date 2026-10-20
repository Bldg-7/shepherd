# Pi 관리형 브라우저 연동

## 현재 상태: macOS 로컬 새 세션 런처 활성화

실험적 브라우저를 켜고 Preparation이 완료되면 새 탭 런처에서 **Pi**를 선택할 수 있다.
지원 기준은 **Pi 1.x (`^1.0.0`), Node >=22.19.0, Herdr 0.9.1**이다. Pi가 설치되어 있지 않으면
기존 Claude/Codex의 Node 20 환경에 불필요한 Pi 업그레이드 경고를 추가하지 않는다.
범위는 npm caret과 같아 `1.y.z` 정식 버전만 받는다. 2.x, 0.x, pre-release(`1.3.0-beta.1`)는
`pi-package-unsupported`로 거절한다.

실제로 확인한 Pi는 **1.1.0, 1.2.0, 1.3.0**이다.

- Pi 1.1.0: 기본 MCP와 **pi-mcp-adapter 5.1.0** 모두 실제 `AgentLaunchService.launch` 경로에서
  Herdr → Pi → MCP → native CEF 페이지 이동/내용 확인 → 권한 폐기 → 자연 종료를 검증했다.
- Pi 1.2.0: hrdrhrdrhrdr가 쓰는 CLI 인자, 확장 API, 진입부가 1.1.0과 같은 것을 확인하고
  `run-pi-bridge-tests.py`로 실제 TUI 기동 → 확장 → native bridge → MCP metadata → 자연 종료를 검증했다.
  native CEF 경로(`run-pi-native-tests.py`)는 아직 실행하지 않았다.
- Pi 1.3.0: shim을 절대 경로로 타이핑하는 런치로 `run-pi-native-tests.py`(기본 MCP)를 실행해
  Herdr → Pi → MCP → native CEF 페이지 이동/내용 확인 → 권한 폐기 → 자연 종료를 검증했다. 이 실행의
  private HOME에는 진짜 Pi를 PATH 앞에 두는 `.zshrc`가 있다(아래 검증 절).

로그인 확인이나 실제 비밀정보 입력이 완료되었다는 뜻은 아니다.

### 사용 범위와 제한

- 로컬 Mac의 **새 관리형 Pi TUI 세션**을 지원한다. 기본 fullscreen UI를 유지한다.
- 사용자 Pi 설정, 모델 선택, 지침, 확장과 스킬을 교체하지 않는다. 전역 등록도 하지 않는다.
- Pi metadata 확인은 executable/package 정보만 읽으며 `pi --version`도 실행하지 않는다.
- 브라우저 준비, MCP 등록, 실제 browser socket 연결, Provider 연결, credential 승인은 서로 다른 상태다.
- **정확한 저장 파일 재개, 자식/headless 실행, 경쟁 MCP dispatch 차단은 미지원**이다.
- 경쟁 MCP dispatch 차단을 지원하지 않으므로, 설정 Experimental Features의 Advanced에 있는
  "Block other browser tools"는 Pi에 적용되지 않는다. 이 설정을 켜도 Pi 실행은 거부되지 않는다.
  Pi에는 차단 인자를 넘기지 않으므로 Pi는 자기 MCP 서버를 모두 그대로 쓴다. 이 설정의 도움말에도
  같은 내용이 적혀 있다.
- 현재 launch는 최초 session ID와 session directory에 묶인다. `/new`, 다른 저장 파일 선택,
  새 ID를 만드는 fork는 이전 권한을 폐기하고 자동 재승인하지 않는다. 브라우저가 필요한 새 대화는
  새 관리형 실행을 사용한다. 같은 세션의 tree/reload는 별도 epoch로 retire/rebind한다.
- 세션용 PATH shim은 해당 새 터미널에만 존재한다. 복사된 인자나 부모 descriptor로
  자식/다른 프로세스가 같은 native 권한을 얻을 수 없다. Shell fallback이나 자동 재시작은 없다.
- Node 실행 경로를 명시적으로 사용한다. Bun으로 설치한 Pi JS package는 찾을 수 있지만
  Bun runtime 자체의 실행 계약을 검증했다고 주장하지 않는다.
- 공통 credential broker의 native binding/ticket/proxy 조합은 별도 미완료 작업이다.
  Provider Ready를 비밀번호 자동 입력 Ready로 표시하지 않는다.

## 실행·소유권 구조

### 준비와 최초 실행

`runtime.mjs:stagePi`는 실행하지 않고 private launch 폴더, 세션용 `pi` shim, session directory와
extension/skill/append 지침 인자를 준비한다. 셸 인자로 token 값은 전달하지 않는다.
`pi-launch.mjs`는 실제 Pi를 import하기 전에 native host의 bind 승인을 기다린다.
패키지가 선언한 실제 bin과 버전을 다시 확인하며 잘못된 인자/cwd/신원에서는 종료한다.

shim은 `AgentLaunchService.launchPi`가 **절대 경로로** pane의 셸에 타이핑한다(`HerdrClient.runCommand`,
Herdr `pane.send_input` = `herdr pane run`과 같은 요청: 인자마다 따옴표를 치고 Enter까지 한 번에 보낸다).
Herdr `agent.start`를 쓰지 않는 이유: `agent.start`는 kind의 실행 파일 이름 `pi`만 타이핑하고 셸이 PATH로
찾게 한다. 그 셸은 대화형이라 startup 파일(`~/.zshrc` 등)이 먼저 실행되는데, 그 파일이 `~/.bun/bin`이나
`~/.local/bin`을 PATH 앞에 다시 붙이면 `pi`는 거기 설치된 CLI가 되고 shim은 실행되지 않는다. 그러면 bind가
끝내 오지 않아 20초 뒤 `pi-foreground-binding-lost`로 실패하고, 그 실패는 남겨진 pane에 붙은 채로 남는다.
Herdr 0.9.1~0.9.5의 `agent.start`에는 실행 파일 경로나 env를 주는 방법이 없고, `tab.create`의 env로는
startup 파일 뒤의 PATH 순서를 바꿀 수 없다. 절대 경로로 실행해도 최종 foreground 프로세스
(`process.title = "pi"`인 node)는 같으므로 Herdr의 감지도 같다. stage된 PATH는 Pi의 자식 프로세스를 위해
그대로 pane env로 간다.

`agent.start`를 쓰지 않으므로 Herdr가 agent.start한 agent에만 주는 live agent 이름(`pi-<id>`)과
`interactive_ready`는 없다. hrdrhrdrhrdr는 agent를 pane ID로만 다루고, Pi의 준비 상태는 아래 native MCP
소유권으로 판단하므로 둘 다 쓰지 않는다.

`PiLaunchCoordinator`는 이 타이핑과 다른 Herdr connection으로 같은 pane/terminal의
foreground 프로세스를 관찰한다. Pi가 아직 시작을 기다리는 동안 전체 argv를 pin할 수 있으므로
Herdr readiness와 Pi session_start가 서로 기다리는 교착이나 짧은 argv 수집 경쟁을 피한다.
`AgentLaunchService`는 shim을 타이핑한 직후 New Tab launcher를 닫게 한다. 이 시점을 hand-off라 한다.
그 뒤 두 가지를 차례로 기다린다. 먼저 Herdr가 같은 pane/terminal에서 `pi`를 감지하는 것이고, 다음은 native MCP 소유권이다.
hand-off 뒤의 대기와 실패는 launcher가 아니라 사이드바에만 보인다("Waiting for agent readiness…", "Agent launch failed").
실패해도 선택한 pane은 남기며 재실행·다른 CLI·Shell로 우회하지 않는다.

### 프로세스와 제어 채널

- `PiProcessIdentity`: 동일 UID의 kernel PID/start/parent/executable/cwd/argv 확인.
  환경을 반환하거나 argv를 상태 로그로 serialize하지 않는다.
- `PiProcessLifetime`: 최초 argv 검사 전에 kqueue exec/exit 감시를 등록한다.
  Pi의 알려진 `process.title = "pi"` 형식만 원본 신원과 exec lifetime이 유지될 때 허용한다.
  같은 PID/같은 Node로 exec한 뒤 제목을 맞춰도 이전 권한은 이어지지 않는다.
- `PiBridgeListener`: private directory/0600 Unix socket, `LOCAL_PEERPID`, 크기·연결·시간 제한.
  클라이언트 JSON의 PID는 신원 증거가 아니다.
- `PiHostBridge`: 앱만 launch expectation을 등록한다. root Pi, revoke 전용 직접 자식 helper,
  정확한 MCP wrapper의 역할을 구분하고 매 요청에서 owner를 재검증한다.
  attempt tombstone과 미확인 cleanup을 유지하며, 실패를 성공으로 간주하는 backend는 없다.
- `pi-control.mjs`, `pi-host.mjs`: protected bootstrap, 동기 revoke helper, monotonic heartbeat,
  응답 유실/late acquire 보상, acknowledged close. 불확실한 상태에서는 quarantine한다.

같은 OS 사용자의 임의 메모리/파일 변경을 막는 sandbox가 아니다. 사용자 확장은 정상대로 로드한다.
설치된 pi-patty-bg-tasks의 기존 headless liveness 결함은 수정하거나 숨기지 않았다.

### Herdr 상태와 실제 MCP

`pi-herdr.mjs`는 실제 Pi session/agent_settled 이벤트를 authenticated host에 보고한다.
앱이 검증한 Herdr client/pane으로 공식 report-agent/session API를 호출한다.
상속된 `HERDR_SOCKET_PATH`나 `HERDR_PANE_ID`로 대상을 선택하지 않고 전역 hook도 설치하지 않는다.
이 상태 보고는 UI/lifecycle 힌트이며 native browser 권한 자체가 아니다.

`pi-session-name.mjs`는 앱의 Rename Pane이 정한 이름을 bridge의 `status` 응답(`sessionName`, launch마다 매기는 순번)으로 받는다. 순번마다 한 번 `pi.setSessionName()`을 호출하는데, Pi가 idle이고 보낼 메시지가 남아 있지 않으면 바로, 아니면 Pi의 다음 `agent_settled` 이벤트 때 호출한다. 터미널에는 아무것도 입력하지 않는다. Pi가 새 session을 시작하면 아직 적용하지 않은 이름은 버린다.

`pi-entry.ts`는 TUI만 허용하고 `pi-lifecycle.mjs`를 nonblocking으로 시작한다.
`agent_end` 대신 `agent_settled`, idle/pending 및 native quiescence를 사용한다.
명시적인 전환 전에 동기 revoke → MCP unregister ack → native detach/프로세스 종료를 기다린다.

`pi-mcp-registration.mjs`는 기본 MCP와 adapter를 구분한다. adapter가 응답하면 그 거부도
최종 결과이며 기본 MCP로 fallback하지 않는다. adapter의 session-only 등록 및 mediated connect로
initialize/tools metadata만 확인하고, 브라우저 tool은 자동 호출하지 않는다.
사용자 approval/config 정책은 보존한다. own runtime server만 idle shutdown 없이 세션에 묶는다.

`pi-mcp-run.mjs`는 kernel-authenticated 직접 자식 및 정확한 descriptor인 경우에만
기존 pinned Playwright MCP wrapper를 실행한다. 실제 initialize/tools 응답 후에만 native Ready를 낸다.
등록 API 성공, 서버 이름 또는 다른 서버의 비슷한 도구 목록만으로는 Ready가 되지 않는다.

### CEF 권한과 퇴역

`PiBrowserLeaseProvider`는 실제 `CDPProxy`와 연결된다. `CDPRouteLeases`는 해당 pane의
기존 unleased 경로를 차단하고 epoch별 `/lease/<UUID>` 경로를 발급한다. UUID는 bearer secret의
대체물이 아니며 기존 protected token 인증도 필요하다.

WebSocket admission, 대기 admission 완료, native command dispatch 및 응답에서 live owner를
재검사한다. revoke는 즉시 새 dispatch를 막고 connection을 retire한다. close는 pending admission,
실제 native detach ack와 MCP process exit까지 확인한다. old-route replay, stale revoke 및
terminal 변경으로 권한을 넘기지 않는다. 불확실한 cleanup은 새 lease나 legacy 경로로 풀지 않는다.

## 검증과 구분

- `PiIntegrationTests.mjs`: fake host/Pi registry 수명·late completion·retirement 경계.
- `PiMcpRegistrationTests.mjs`: backend 선택, no fallback, late connect, 비동기 unregister ack.
- `run-pi-bridge-tests.py`: 실제 Unix peer/PID/exec lifetime와 실제 Pi CLI boot barrier 및 MCP metadata.
- `run-pi-native-tests.py`: 실제 public launch service, Herdr/owned PTY, Pi fullscreen, MCP, CEF,
  폐기된 경로의 실제 HTTP upgrade 거부와 자연 종료. 기본 MCP/adapter 모두 별도 실행한다.
  private HOME의 `.zshrc`가 진짜 Pi의 폴더를 PATH 앞에 붙이므로, pane 셸에서 bare `pi`는 shim이 아니다.
  이 조건에서 `agent.start`로 시작하던 이전 런치는 실패하고(preflight가 있던 a37fcf6은
  `pi-shim-shadowed-by-shell-path`로 거절), 절대 경로 타이핑은 통과한다.
  Pi readiness 판정(`AgentLaunchReadiness`)은 Herdr가 같은 pane에서 `pi`를 감지하고, 상태가 idle/done이며
  `launch_pending`이 아닌 것이다. hand-off 뒤에는 사용자가 이미 prompt를 보냈을 수 있으므로 working도 준비로 친다.
  blocked와 unknown은 준비가 아니다. Pi는 `agent.start`가 아니라 타이핑으로 시작하므로, Herdr가 `agent.start`한
  agent에만 붙이는 `interactive_ready`는 판정에 쓰지 않는다. fixture는 두 파일을 남긴다. `started.json`에는
  hand-off 시각, 그때의 사이드바 상태, 그때의 Herdr agent 행을 남기고, `ready.json`의 `returnedAt`에는 launch가 끝난 시각을 남긴다.
- native 테스트는 private HOME/agentDir의 **정상 설정 로딩**으로 사용자 지침/확장이 유지되는지 확인한다.
  모델은 loopback fake provider만 사용한다. adapter credential store는 테스트 전용 memory이며
  실제 Keychain, Vendor 로그인, Vault, 사용자 프로필을 사용하지 않는다.
- 앞선 실패도 보존한다: 잘못 지정한 development CLI 경로, PTY attachment 전 shell busy,
  `/tmp` alias 차이, bridge env handoff, raw start 응답과 interactive readiness 혼동,
  종료 중 process-info 필드 생략. 빌드 성공과 helper 강제 종료 여부는 따로 기록한다.
- 실제 GUI 버튼 조작, signing/notarization, remote routing, 실제 Vendor 인증은 이 테스트의 증명이 아니다.

참고: 설치된 Pi 1.1.0 공식 CLI/extensions/MCP/session 문서와 Pi 1.2.0 CHANGELOG, adapter extension/protocol API 문서,
private HOME에 생성하여 확인한 Herdr Pi integration v9.
