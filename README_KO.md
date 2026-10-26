# herdr용 hrdrhrdrhrdr

[English](README.md) · [한국어](README_KO.md) · [日本語](README_JP.md)

Herdr 터미널과 코딩 에이전트를 위한 네이티브 macOS 작업 공간입니다.

[릴리스된 macOS 앱 다운로드](https://github.com/Bldg-7/shepherd/releases/latest/download/hrdrhrdrhrdr.dmg) · [웹사이트](https://bldg-7.github.io/shepherd/) · [릴리스](https://github.com/Bldg-7/shepherd/releases)

## 개요

hrdrhrdrhrdr는 로컬 및 SSH 연결 머신, 저장된 herdr 머신, 터미널 pane, 코딩 에이전트 세션을 macOS에서 하나의 Herdr 작업 공간으로 제공합니다. 네이티브 파일 미리보기, 머신 관리, 그리고 지원되는 관리형 에이전트를 위한 선택적 pane 범위 In-app Browser를 추가합니다.

이 저장소에는 macOS 앱, iPhone 및 iPad 앱(`ShepherdMobile/`), 공용 `ShepherdKit` 패키지, 웹사이트와 릴리스 자료의 소스가 들어 있습니다. 위 다운로드 링크는 릴리스된 macOS 바이너리용입니다. 모바일 소스가 있다는 사실은 공개 모바일 배포를 의미하지 않습니다.

## 주요 기능

- This Mac, 설정에 추가한 SSH 머신, herdr가 저장한 머신에서 작업합니다.
- OSC 8 파일 링크를 읽기 전용 미리보기로 열고, Markdown 렌더링, 제목 목차, 찾기, 새로 고침을 사용합니다.
- 터미널 웹 링크는 해당 pane의 In-app Browser에서 열고, Command-클릭하면 macOS 기본 브라우저에서 엽니다. 지원되는 경우 HTML 파일 링크도 같은 경계를 따릅니다.
- QR 코드와 Remote Login으로 iPhone 또는 iPad를 This Mac에 페어링합니다. 페어링에는 Secure Enclave 키와 사용자의 명시적 확인이 필요합니다.
- 실험적 브라우저 준비가 끝난 뒤 새 탭 런처에서 새 로컬 관리형 Claude Code, Codex, Pi 세션을 시작합니다.

상세한 조작, 원격 머신 동작, 페어링 보안, 대화 캡처 범위와 기능 제한은 **[영문 사용자 가이드](docs/user-guide.md)**를 읽어 주세요.

## 요구 사항 및 제한

- macOS **26.6.2 이상**과 별도로 설치한 **Herdr**가 필요합니다.
- 실험적인 Chromium 기반 In-app Browser는 기본값이 **끔**이며 Apple silicon에서만 동작합니다. Intel Mac에서는 사용할 수 없지만 터미널 기능은 계속 사용할 수 있습니다.
- 관리형 브라우저 에이전트는 선택 사항입니다. Claude Code와 Codex에는 Node **>=20**이 필요합니다. Pi는 **1.x (`^1.0.0`)**를 지원하며 Node **>=22.19.0**이 필요합니다.
- 에이전트 CLI와 인증은 사용자가 관리합니다. 브라우저 준비, MCP 등록, 브라우저 연결, provider 연결, 자격 증명 승인은 서로 별도의 상태입니다.
- Pi는 새 로컬 관리형 TUI 세션을 지원합니다. 저장 세션 재개, 브라우저를 쓰는 child/headless 프로세스, 세션 변경 뒤 자동 재승인, 경쟁 MCP dispatch 억제는 지원하지 않습니다. **Block other browser tools**는 Pi에 적용되지 않습니다.

## 시작하기

1. Herdr를 별도로 설치한 뒤 위 링크에서 릴리스된 macOS 바이너리를 내려받거나 아래에서 소스 빌드를 합니다.
2. hrdrhrdrhrdr를 열고 This Mac에 연결하거나 **Settings → Machines**에서 SSH 머신을 추가합니다.
3. 실험적 브라우저를 사용하려면 **Settings → Experimental Features**에서 켜고 Preparation이 끝날 때까지 기다립니다.
4. 새 탭을 열어 Shell, Claude Code, Codex 또는 Pi를 선택합니다. 에이전트는 CLI를 직접 설치하고 인증한 뒤에만 선택하세요.

브라우저 리소스는 새 관리형 세션에만 번들로 주입됩니다. hrdrhrdrhrdr는 전역 MCP 서버나 스킬을 설치하지 않고, 실행 중 npm 패키지를 내려받거나, 신뢰를 자동 승인하거나, 에이전트의 지침·확장을 바꾸지 않습니다. 인증된 브라우저 endpoint는 pane 범위입니다.

**기존 `npx skills … --global` 또는 `setup.sh` 설치 관리자를 실행하지 마세요.** 이제 설치를 거부합니다. 이전에 전역 hrdrhrdrhrdr 등록을 설치했다면 직접 검토하고 제거해야 하며, 앱이 이를 조용히 수정하지 않습니다.

## 소스에서 빌드

**Xcode 27**과 command-line tools를 사용합니다. 저장소는 Swift 의존성을 `Package.resolved`에, Chromium/CEF를 `scripts/cef.sh`에, 브라우저 Node 패키지를 `package-lock.json`에 고정합니다.

```sh
scripts/cef.sh
npm ci --prefix Shepherd/Agents/AgentRuntime --ignore-scripts --no-audit --no-fund
open shepherd.xcodeproj
```

CEF와 `node_modules`는 커밋된 바이너리가 아니라 빌드 입력입니다. Xcode가 요청하면 정확한 SwiftTerm 1.20.0 빌드 플러그인만 승인하고, 플러그인 검증을 전역으로 끄지 마세요. Debug 빌드에는 Sparkle 업데이트 피드가 없습니다. 서명 없는 로컬 빌드에는 `CODE_SIGNING_ALLOWED=NO`를 사용하세요.

## 문서

- **[사용자 가이드 (영문)](docs/user-guide.md):** 상세 사용법, 개인정보 및 신뢰 경계, 제한 사항, 상표 고지.
- **[Pi 지원](docs/pi-agent-support.md):** 관리형 Pi의 범위와 기술 지원 경계 (한국어).
- **[링크 열기 UX](docs/link-opening-ux.md):** 링크를 여는 현재 규칙과 설계 이력 (한국어).
- **[macOS 릴리스 절차](docs/releasing-macos.md):** 관리자를 위한 릴리스 안내 (영문).
- [0.3.1 릴리스 노트](notes/0.3.1.md) · [0.3.0 기능 노트](notes/0.3.0.md)
