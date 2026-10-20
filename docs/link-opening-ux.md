# 터미널 링크를 어디서 열지 고르는 UX (설계 초안)

> **바뀜 (SHPHRD-86).** 이 문서의 추천안 중 0.5.0에 들어간 "Open links in" 설정(5절의 1층 "기본값"과 7절)과 첫 클릭 팝오버(6절)는 없앴다. 지금 규칙은 10절에 있다.

In-app Browser가 켜져 있을 때, 터미널 안의 `http(s)` 링크를 **In-app Browser**로 열지 **macOS 기본 브라우저**로 열지 사용자가 고를 수 있어야 한다. 이 문서는 가능한 방식들을 모아 비교하고 추천안을 적는다. 코드 변경은 포함하지 않는다.

**결론부터.** 한 가지 방식으로는 부족하고, 세 층을 겹쳐 쓰기를 추천한다. (1) 설정에 "링크를 여는 곳" 기본값을 두되 초기값은 "처음 한 번 묻기"로 하고, (2) ⌘를 누른 채 클릭하면 기본값의 반대쪽에서 열며, (3) In-app Browser 안에서 본 페이지를 기본 브라우저로 보내는 메뉴를 둔다. 우클릭 메뉴는 TUI의 마우스 입력과 겹치므로 보류한다. 근거는 3절과 4절, 세부는 5절부터다.

## 0. 용어

- **In-app Browser**: hrdrhrdrhrdr 창 안에 내장된 Chromium(CEF) 브라우저. Settings → Experimental Features에서 켜며, 기본은 꺼짐이다. Apple silicon에서만 동작하고 Intel Mac에서는 엔진이 로드되지 않는다. 이 문서에서 "엔진 가능"은 그 조건이 맞는지를 뜻한다.
- **pane**: herdr의 터미널 한 칸. hrdrhrdrhrdr는 pane마다 별도의 In-app Browser(탭 묶음과 프로필)를 둘 수 있고, 링크는 클릭한 pane의 브라우저에서 열린다.
- **에이전트의 브라우저 권한**: hrdrhrdrhrdr가 띄운 코딩 에이전트(Claude Code, Codex, Pi)가 자기 pane의 In-app Browser를 조종할 수 있게 주는 권한. 사람이 링크를 클릭해 여는 것과는 별개여야 한다.
- **TUI**: pane 안에서 돌아가는 화면형 프로그램(vim, Claude Code 등). 마우스 리포팅을 켠 TUI는 클릭과 수정키를 터미널로부터 직접 받는다.
- **SwiftTerm**: hrdrhrdrhrdr가 쓰는 터미널 에뮬레이터 라이브러리. **OSC 8 링크**는 프로그램이 이스케이프 시퀀스로 "이 글자는 이 URL"이라고 명시한 링크이고, **암시 링크**는 SwiftTerm이 화면 글자에서 URL처럼 보이는 부분을 찾아낸 것이다.
- **설정 UI 위치**: Settings → Experimental Features 페이지에 "In-app Browser" 카드가 있다. 카드 안에는 켜기 토글, Password Manager 행, Preparation, Advanced, Diagnostics가 순서대로 있다. In-app Browser 툴바의 ⋯ 메뉴에는 Profile(이 pane만 / 다른 pane과 공유) 선택과 Close Browser가 있다.

## 1. 지금 동작 (0.4.0 기준)

- 링크 클릭은 `mouseDown` 시점에 hrdrhrdrhrdr가 선점한다 ([TerminalHostView.swift:186](../Shepherd/Terminal/TerminalHostView.swift:186)). 선점된 클릭은 TUI로 가지 않고, 드래그로 바뀌면 아무것도 열지 않는다 (`TerminalFileGesture`).
- 링크 판정은 OSC 8 명시 링크, SwiftTerm 암시 링크, 클릭한 단어 토큰 순으로 한다 (`TerminalFileHit`). `http:`/`https:`만 웹 링크다 (`TerminalWebLink.isWebLink`).
- 열기 경로는 하나뿐이다. `AgentTerminalView.onOpenLink` → `TerminalWebLinkRequest` → `ContentView.openWeb` → `BrowserStore.shared.openBrowser(for:terminalID:url:)`. 즉 **클릭한 pane의 In-app Browser 새 탭**으로만 열린다 ([ContentView.swift:518](../Shepherd/ContentView.swift:518)).
- In-app Browser가 꺼져 있거나 Intel Mac이면 알림을 띄우고 끝난다. 외부 앱으로 넘기지 않는다는 것이 0.3.2부터의 명시 정책이다 (`TerminalWebLinkError.browserDisabled`, [notes/0.3.2.md](../notes/0.3.2.md)).
- ⌘는 이미 다른 뜻으로 쓰인다. 링크가 아닌 곳을 ⌘를 누른 채 클릭하면, hrdrhrdrhrdr는 SwiftTerm의 링크 강조만 켜고, 클릭 이벤트에서 ⌘ 플래그를 지운 뒤 TUI에 전달한다 ([TerminalHostView.swift:221](../Shepherd/Terminal/TerminalHostView.swift:221)). 링크 위의 클릭은 ⌘를 눌렀든 아니든 위의 선점 규칙대로 hrdrhrdrhrdr가 가져간다.
- 우클릭은 hrdrhrdrhrdr가 손대지 않는다. SwiftTerm 기본 동작대로 TUI의 마우스 리포팅으로 간다.
- 앱 안에서 OS 기본 브라우저를 여는 코드는 설정 페이지의 `NSWorkspace.shared.open` 한 곳뿐이다 ([NotificationSettingsView.swift:90](../Shepherd/Hosts/Views/NotificationSettingsView.swift:90)).
- In-app Browser 툴바의 ⋯ 메뉴에는 Profile 선택과 Close Browser만 있다 ([BrowserColumn.swift:238](../Shepherd/Browser/Views/BrowserColumn.swift:238)).

## 2. 설계 제약

이 기능이 지켜야 하는 것들이다. 선택지 비교의 기준이기도 하다.

1. **TUI 입력과 충돌하지 않는다.** 클릭 선점은 `mouseDown`에서 결정되고, 선점되지 않은 클릭은 그대로 TUI 것이다. 어떤 UX도 "링크가 아닌 곳의 클릭"을 가로채면 안 된다.
2. **마우스 리포팅을 존중한다.** vim, lazygit, Pi 같은 TUI는 마우스를 직접 쓴다. xterm 마우스 프로토콜은 Alt(Option)와 Ctrl을 클릭과 함께 TUI에 보내므로, hrdrhrdrhrdr가 그 키들에 뜻을 주면 TUI가 기대하는 입력을 빼앗게 된다. Shift는 다르다. 다른 터미널들처럼 SwiftTerm도 ⇧-클릭과 ⇧-드래그를 TUI에 보내지 않고 텍스트 선택에 쓰며, 프로그램이 XTSHIFTESCAPE(`CSI > 1 s`)로 ⇧를 달라고 했을 때만 보낸다. hrdrhrdrhrdr도 ⇧를 선택에 쓴다(10절). **Command는 이 프로토콜에 없어서 TUI에 전달되지 않는다.** 그래서 링크를 여는 데 hrdrhrdrhrdr가 쓸 수 있는 수정키는 ⌘뿐이다. 우클릭도 TUI가 받는 입력이라 링크를 여는 데 쓰지 않는다.
3. **사람의 탐색과 에이전트의 브라우저를 섞지 않는다.** 사람이 링크를 열어도 에이전트 권한이 생기지 않는다는 현재 주석의 원칙을 유지한다 (`TerminalWebLinkRequest`, `ContentView.openWeb`).
4. **URL 검증은 목적지와 무관하게 같다.** `TerminalWebLink.urlToOpen`의 검사(스키마, 자격증명 포함 금지, 제어문자 금지, 8 KB 제한)는 기본 브라우저로 보낼 때도 똑같이 거친다. 다만 "브라우저 켜짐/엔진 가능" 검사는 In-app Browser 목적지에만 해당한다.
5. **창은 하나다.** 선택 UI는 팝오버, 메뉴, 알림 수준이어야 하고 새 창을 만들지 않는다.
6. **한 번 정하면 예측 가능해야 한다.** 같은 링크를 클릭했을 때 매번 다른 곳에서 열리면 안 된다.

## 3. 선택지

### A. 우클릭 컨텍스트 메뉴

링크 위에서 우클릭하면 "Open in In-app Browser / Open in Default Browser / Copy Link" 메뉴를 띄운다. 좌클릭은 지금처럼 기본 동작.

- 장점: macOS 사용자에게 익숙하다. 좌클릭 흐름을 건드리지 않는다. Copy Link 같은 보조 동작을 같이 넣기 좋다.
- 단점: TUI가 마우스 리포팅을 켠 상태면 우클릭을 TUI에 줘야 하는지 hrdrhrdrhrdr가 가져야 하는지 애매하다. 링크 위의 우클릭만 가져가는 규칙은 가능하지만, 사용자는 "우클릭이 왜 어떤 때는 메뉴고 어떤 때는 아닌지" 알기 어렵다. 매번 두 번 클릭이라 기본 동작을 바꾸는 수단으로는 느리다.
- 구현 지점: `FocusReportingTerminalView`에 `rightMouseDown` 오버라이드, `TerminalFileHit.link`로 링크면 `NSMenu.popUp`, 아니면 `super`.

### B. 클릭 시 팝오버로 묻고 기본 동작을 기억

링크를 클릭하면 클릭 지점에 작은 팝오버가 뜬다. "In-app Browser에서 열기", "기본 브라우저에서 열기" 두 버튼과 "항상 이렇게 열기" 체크. 한 번 기억하면 그 뒤로는 묻지 않는다.

- 장점: 발견성이 가장 높다. 설정 페이지를 찾지 않아도 첫 클릭에서 결정을 끝낸다. 기본값을 사용자가 고르므로 hrdrhrdrhrdr가 임의로 정하지 않아도 된다.
- 단점: 기억하지 않으면 매 클릭이 두 단계다. 기억한 뒤에는 바꾸는 길이 다시 설정으로 돌아가야 한다. 팝오버가 TUI 위에 겹치고, 키보드 포커스가 잠깐 터미널을 떠난다.
- 구현 지점: `ContentView`에 `@State var linkChoice: TerminalWebLinkRequest?`를 두고 `.popover(item:)`로 띄운다. 앵커를 클릭 좌표에 두려면 `TerminalWebLinkRequest`에 클릭 위치를 실어야 한다.

### C. 설정의 고정 기본값

Settings → Experimental Features → In-app Browser 카드에 "Open links in: In-app Browser / Default Browser" 피커를 둔다. 클릭은 그 값대로 한 번에 연다.

- 장점: 가장 단순하고 예측 가능하다. 구현도 `openWeb`의 분기 하나다.
- 단점: 링크마다 다르게 열고 싶을 때(개발 서버는 In-app Browser, GitHub은 기본 브라우저) 매번 설정을 오가야 한다. 발견성이 낮아 설정이 있는지 모를 수 있다.
- 구현 지점: `@AppStorage("links.destination")`, `ContentView.openWeb` 분기, 설정 카드에 Picker.

### D. 수정키 클릭으로 반대 동작

기본 동작은 C의 값대로 하고, **⌘-클릭이면 반대쪽**에서 연다. iTerm2와 Ghostty가 ⌘-클릭으로 링크를 여는 관례와 맞닿아 있다.

- 장점: 한 번의 클릭으로 두 목적지를 다 쓸 수 있다. TUI와 충돌하지 않는 유일한 수정키가 ⌘이고, 링크 위의 클릭은 이미 hrdrhrdrhrdr가 선점하므로 추가 충돌이 없다.
- 단점: 발견성이 낮다. 설명이 없으면 아무도 모른다. ⌘는 현재 링크가 아닌 곳에서 "링크 강조"에 쓰이는데, 링크 위의 클릭은 지금도 ⌘와 무관하게 hrdrhrdrhrdr가 선점하므로(1절), 링크 위에서만 ⌘에 새 뜻을 줘도 충돌은 없다. 링크가 아닌 곳의 ⌘-클릭(강조만 켜고 TUI에 전달)은 그대로 둔다.
- 구현 지점: `FocusReportingTerminalView.mouseUp`에서 `event.modifierFlags.contains(.command)`를 읽어 `onOpenFileGesture`에 함께 넘긴다. `TerminalWebLinkRequest`에 `alternate: Bool` 추가.

### E. 열고 난 뒤 밖으로 보내기

항상 In-app Browser에서 열되, In-app Browser 툴바의 ⋯ 메뉴와 주소창 우클릭에 "Open in Default Browser"를 둔다. 주소창의 URL을 드래그해 Dock의 브라우저에 떨어뜨리는 것도 같은 범주다.

- 장점: 클릭 흐름에 아무것도 끼어들지 않는다. 이미 있는 메뉴 구조에 항목 하나를 더하는 수준이다. "이 페이지는 여기서 보기 불편하다"는 판단을 페이지를 본 뒤에 할 수 있다.
- 단점: 처음부터 기본 브라우저에서 열고 싶은 사람에게는 항상 한 단계가 더 있다. In-app Browser가 꺼져 있으면 쓸 수 없다.
- 구현 지점: `BrowserToolbar.menu`에 Button 추가, `NSWorkspace.shared.open(URL(string: tab.url))`.

### F. 도메인/패턴 규칙

설정에 규칙 목록을 둔다. 예: `localhost`, `127.0.0.1`, `*.local` → In-app Browser, 그 외 → 기본 브라우저.

- 장점: 사용자의 실제 구분(개발 서버 vs 외부 사이트)을 자동화한다. 한 번 맞추면 클릭마다 고민이 없다.
- 단점: 설정 UI가 커진다. 규칙에 빠진 링크는 결국 C의 기본값으로 떨어지므로 C 없이는 성립하지 않는다. 1차 범위로는 무겁다.
- 구현 지점: C 위에 규칙 평가 함수 하나. 2단계 후보.

### G. 호버 액션

링크 위에 마우스를 올리면 작은 칩 두 개(hrdrhrdrhrdr / 기본)가 떠서 각각 클릭할 수 있게 한다.

- 장점: 클릭 전에 선택지를 보여 준다.
- 단점: 터미널 위에 떠다니는 UI는 TUI 내용을 가리고, 마우스가 조금만 움직여도 사라지는 등 불안정하다. 터미널 앱 관례에 없다. 추천하지 않는다.

### H. 길게 누르기

링크를 길게 누르면 선택 메뉴.

- 단점: 터미널의 드래그 선택과 충돌하고, 트랙패드에서 Force Click과 겹친다. iOS/iPadOS에는 맞지만 macOS에는 맞지 않는다. 추천하지 않는다.

### I. 첫 클릭 한 번만 묻기

B의 변형. 기억 체크박스 대신 "항상 In-app Browser에서", "항상 기본 브라우저에서", "이번만 …" 식으로 버튼을 나누고, 기억한 뒤에는 C의 설정값이 된다.

- 장점: B의 발견성과 C의 예측 가능성을 합친다. 매 클릭 두 단계라는 B의 단점이 없다.
- 단점: "이번만"을 계속 고르는 사람은 B와 같아진다. 결정을 바꾸려면 설정으로 가야 한다는 점은 같다.

## 4. 비교

| | 발견성 | 클릭 수 | TUI 충돌 | 링크마다 다르게 | 브라우저 OFF일 때 | 구현 비용 |
|---|---|---|---|---|---|---|
| A 우클릭 메뉴 | 중 | 2 | 마우스 리포팅과 겹침 | 가능 | 기본 브라우저 항목만 활성 | 중 |
| B 팝오버 + 기억 | 높음 | 2 → 1 | 팝오버가 TUI 위에 | 기억 전까지만 | 가능 | 중 |
| C 설정 기본값 | 낮음 | 1 | 없음 | 불가 | 가능 | 낮음 |
| D ⌘-클릭 반전 | 낮음 | 1 | 없음 | 가능 | 가능 | 낮음 |
| E 사후 전환 | 중 | 1 + 1 | 없음 | 가능 | 불가 | 낮음 |
| F 도메인 규칙 | 낮음 | 1 | 없음 | 자동 | 가능 | 높음 |
| G 호버 칩 | 높음 | 1 | TUI 가림 | 가능 | 가능 | 높음 |
| H 길게 누르기 | 낮음 | 1 | 드래그 선택과 충돌 | 가능 | 가능 | 중 |
| I 첫 클릭 1회 질문 | 높음 | 1 | 1회만 | 불가 | 가능 | 중 |

어느 하나만으로는 부족하다. B는 발견성이 좋지만 매번 두 단계이고, A는 두 단계인 데다 TUI와 겹친다. C와 D는 한 번에 열리지만 있는지 모른다. E는 안전하지만 처음부터 밖에서 열고 싶은 사람에게는 반쪽이다.

## 5. 추천안: 계층을 나눈다

"기본값 하나 + 빠른 예외 + 사후 탈출구"로 구성한다. 각 층은 독립적으로 넣고 뺄 수 있다.

1. **기본값 (C + I).** 설정 In-app Browser 카드에 "Open links in" 피커를 둔다. 값은 `In-app Browser`, `Default Browser`, `Ask`. 초기값은 `Ask`. `Ask` 상태에서 첫 링크를 클릭하면 팝오버가 한 번 뜬다. 버튼은 두 개: "In-app Browser에서 열기", "기본 브라우저에서 열기". 그 아래 체크박스 "다음부터 묻지 않기"(기본 켜짐). 체크가 켜진 채 고르면 설정값이 그 목적지로 바뀐다. 팝오버 하단에 "⌘-클릭하면 반대쪽에서 열립니다" 한 줄을 적어 D의 발견성 문제를 여기서 해결한다.
2. **빠른 예외 (D).** ⌘-클릭은 설정값의 반대쪽에서 연다. 설정값이 `Ask`일 때 ⌘-클릭은 기본 브라우저로 간다 (팝오버 없이). 설정 피커의 도움말에도 같은 문장을 쓴다.
3. **사후 탈출구 (E).** In-app Browser 툴바 ⋯ 메뉴에 "Open in Default Browser"를 추가한다. 주소창을 우클릭해도 같은 항목이 보이게 한다.
4. **우클릭 메뉴 (A)는 보류.** 마우스 리포팅과의 규칙을 정하지 않고는 넣지 않는다. 넣는다면 "링크 위 + TUI가 마우스 리포팅을 켜지 않았을 때"만 hrdrhrdrhrdr가 가져가고, 메뉴 항목은 "In-app Browser에서 열기", "기본 브라우저에서 열기", "링크 복사" 세 개로 한정한다.
5. **도메인 규칙 (F)은 2단계.** 1~3층을 쓴 뒤 "localhost는 항상 In-app Browser"가 실제로 필요한지 보고 결정한다.

### 왜 초기값을 `Ask`로 두는가

In-app Browser는 에이전트 연동이 목적이고, 사람이 읽는 링크(GitHub PR, 문서)는 비밀번호와 확장이 있는 기본 브라우저가 편한 경우가 많다. 반대로 개발 서버 링크는 pane 옆에서 보는 게 낫다. 어느 쪽도 모두에게 맞는 기본값이 아니므로 한 번은 묻는 것이 맞다. 다만 묻는 것은 한 번뿐이어야 하고, 그래서 "다음부터 묻지 않기"를 기본으로 켠다.

### 브라우저가 꺼져 있을 때

지금은 알림만 띄우고 끝난다. 이 기능이 들어가면 그 알림은 의미가 약해진다. 두 가지 길이 있다.

- (권장) 브라우저가 꺼져 있거나 엔진이 없으면 설정값과 상관없이 기본 브라우저로 연다. 지금의 알림은 없앤다. 설정값이 `In-app Browser`였다면 그 사실을 사용자가 알 수 있게, 기본 브라우저로 연 직후 pane 위에 한 줄 배너("In-app Browser가 꺼져 있어 기본 브라우저에서 열었습니다")를 잠깐 보인다. 8절의 결정 함수는 이 규칙을 따른다.
- (보수) 0.3.2 정책대로 외부 앱 전달을 계속 금지한다. 이 경우 이 문서의 기능은 "브라우저가 켜져 있을 때만" 동작한다.

권장안을 고르면 릴리스 노트의 "does not hand the link to another app" 문장을 고쳐야 한다.

## 6. 팝오버 상세

- 앵커: 클릭한 셀의 사각형. `TerminalWebLinkRequest`에 뷰 좌표의 클릭 지점을 추가하고, `TerminalHostView`가 그 지점을 창 좌표로 넘긴다. 셀 사각형을 구하기 어려우면 pane 뷰의 중앙 상단도 무방하다.
- 내용: 링크를 한 줄로 잘라 보여 준다(최대 80자, 가운데 생략). 그 아래 버튼 두 개를 가로로, 아래에 체크박스, 맨 아래 ⌘-클릭 안내 한 줄.
- 키보드: Return은 첫 버튼(In-app Browser), Esc는 닫기. 1/2 숫자키로 각 버튼. 닫히면 포커스는 터미널로 돌아간다.
- 닫힘 조건: 선택, Esc, 바깥 클릭, pane 선택이 바뀜, 앱이 백그라운드로 감.
- 한 번에 하나만 뜬다. 떠 있는 동안 다른 링크를 클릭하면 새 링크로 교체된다.

## 7. 설정 상세

In-app Browser 카드의 토글 바로 아래 (Password Manager 행 위):

```
Open links in   [ Ask each time ▾ ]      ⓘ
```

ⓘ 설명: "터미널의 http/https 링크를 어디서 열지 정합니다. ⌘를 누른 채 클릭하면 반대쪽에서 열립니다. In-app Browser가 꺼져 있거나 이 Mac에서 쓸 수 없으면 기본 브라우저로 엽니다." 저장 키는 `@AppStorage("links.destination")`, 값은 `ask` / `shepherd` / `system`. 브라우저 토글과 독립적으로 저장한다.

## 8. 구현 지점 요약

| 층 | 파일 | 변경 |
|---|---|---|
| 공통 | `Shepherd/Terminal/TerminalWebLinkRequest.swift` | `alternate: Bool`, 클릭 지점 추가 |
| 공통 | `Shepherd/Terminal/TerminalHostView.swift` | `mouseUp`에서 ⌘ 여부와 좌표를 `onOpenFileGesture`에 전달 |
| 공통 | `Shepherd/Terminal/AgentTerminalView.swift` | `onOpenLink` 시그니처 확장 |
| 공통 | `Shepherd/Terminal/TerminalWebLink.swift` | `urlToOpen`을 "검증"과 "In-app Browser 가능 여부"로 분리 |
| 공통 | `Shepherd/ContentView.swift` | `openWeb`에서 목적지 결정, `NSWorkspace.shared.open` 분기, 팝오버 상태 |
| 1층 | `Shepherd/Hosts/Views/ExperimentalFeaturesSettingsView.swift` | Picker + InfoButton |
| 3층 | `Shepherd/Browser/Views/BrowserColumn.swift` | ⋯ 메뉴에 "Open in Default Browser" |
| 공통 | `Shepherd/Localizable.xcstrings` | 새 문자열 |
| 테스트 | `Tests/FilePreview/TerminalLinkTests.swift` | 목적지 결정 함수의 단위 테스트 (설정값 × ⌘ × 브라우저 상태) |

목적지 결정은 순수 함수로 뽑아 테스트한다:

```swift
nonisolated enum LinkDestinationPolicy {
    enum Preference: String { case ask, shepherd, system }
    enum Destination: Equatable { case shepherd, system, ask }

    static func destination(preference: Preference, commandHeld: Bool,
                            browserAvailable: Bool) -> Destination {
        switch (preference, commandHeld) {
        case (.shepherd, false), (.system, true): return browserAvailable ? .shepherd : .system
        case (.system, false), (.shepherd, true), (.ask, true): return .system
        case (.ask, false): return browserAvailable ? .ask : .system
        }
    }
}
```

## 9. 같이 결정해야 하는 것

1. 브라우저가 꺼져 있을 때 기본 브라우저로 여는 것을 허용할지 (5절). 허용하면 0.3.2 정책 문장을 고친다.
2. 마크다운 프리뷰 안의 `http(s)` 링크는 지금 아무것도 하지 않는다 ([FilePreviewPanel.swift:101](../Shepherd/FilePreview/FilePreviewPanel.swift:101)). 같은 정책을 적용할지.
3. 원격 머신 pane의 `localhost` 링크는 Mac의 localhost를 가리킨다 (README). 기본 브라우저로 보내도 같은 문제이므로 이 설계에서는 다루지 않지만, F(도메인 규칙)를 넣을 때 함께 본다.
4. 우클릭 메뉴(A)를 넣을지, 넣는다면 마우스 리포팅이 켜진 TUI에서의 규칙.

## 10. 지금 규칙 (SHPHRD-86)

파일 링크 클릭과 같은 경험을 주려고 설정과 팝오버를 없애고 고정 규칙으로 바꿨다.

| 상황 | 그냥 클릭 | ⌘-클릭 |
|---|---|---|
| In-app Browser 켜짐, Apple silicon | 클릭한 pane의 In-app Browser 새 탭 | 기본 브라우저 |
| In-app Browser 꺼짐 | 기본 브라우저, 알림 없음 | 기본 브라우저 |
| 켜져 있지만 이 Mac에서 실행할 수 없음(Intel) | 기본 브라우저, 터미널 아래에 그 이유를 알리는 알림 | 기본 브라우저 |

- Settings에 추가한 SSH machine의 pane에서도, host의 herdr에 저장된 herdr machine의 pane에서도 같다. 잘못된 URL은 어느 브라우저로 갈지와 상관없이 "Could Not Open Link" 알림창을 띄운다.
- ⌘-클릭 안내는 Settings → Experimental Features → In-app Browser의 ⓘ 설명에 있다.
- 0.5.x가 이 설정을 저장하던 UserDefaults 키 `links.destination`은 읽지도 지우지도 않는다. 설정에서 "Default Browser"를 골랐던 사람도 이제 그냥 클릭하면 In-app Browser에서 열린다.
- 링크를 더블·트리플 클릭해도 한 번만 열린다. 링크를 연 첫 누름에 이어지는 둘째·셋째 누름(clickCount 2 이상)도 터미널 프로그램에 보내지 않고 앱이 가져가며, 아무것도 열지 않는다. 첫 클릭으로 pane 옆에 In-app Browser가 나타나 화면 배치가 바뀌는 바람에 둘째 누름이 링크 밖에 떨어져도 마찬가지로 가져간다(`TerminalFileGesture`). 링크가 아닌 곳의 더블클릭은 전과 같다. 마우스 리포팅(터미널 프로그램이 마우스 입력을 받겠다고 켠 상태)이 꺼져 있으면 단어를 선택하고, 켜져 있으면 프로그램이 받는다.
- ⇧를 누른 채 시작한 누름은 링크 위에서도 hrdrhrdrhrdr가 링크로 가져가지 않는다(SHPHRD-93). ⇧-드래그는 텍스트를 선택하고, ⇧-클릭은 링크를 열지 않으며 선택이 있으면 넓힌다. ⇧를 썼는지는 마우스 버튼을 누르는 순간에 정하고, 버튼을 놓을 때까지 마우스 리포팅을 꺼 둔다. 프로그램이 XTSHIFTESCAPE로 ⇧를 달라고 했으면 ⇧ 누름도 전처럼 링크로 가져간다. 마우스 리포팅이 꺼진 pane(셸, 기본 화면의 Claude Code)에서 링크 위에서 시작한 수정키 없는 드래그는 8pt를 넘게 움직이면 누른 자리부터 선택이 되고, 링크는 열리지 않는다. 그 밖의 누름, 곧 마우스 리포팅이 켜진 pane의 수정키 없는 누름과 ⌘·⌥·⌃ 누름은 전처럼 링크로 가져가고, 8pt 안에서 놓은 수정키 없는 클릭과 ⌘-클릭은 링크를 연다(`FocusReportingTerminalView.mouseDown`·`mouseDragged`).
- 목적지를 정하는 함수: `LinkDestinationPolicy.destination(commandHeld:browserEnabled:engineAvailable:)`. 알림을 띄울지 정하는 함수: `saysBrowserUnavailable(commandHeld:browserEnabled:engineAvailable:)`.
