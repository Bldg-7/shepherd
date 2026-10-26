# herdr のための hrdrhrdrhrdr

[English](README.md) · [한국어](README_KO.md) · [日本語](README_JP.md)

Herdr のターミナルとコーディングエージェントのためのネイティブ macOS ワークスペースです。

[リリース済み macOS アプリをダウンロード](https://github.com/Bldg-7/shepherd/releases/latest/download/hrdrhrdrhrdr.dmg) · [Web サイト](https://bldg-7.github.io/shepherd/) · [リリース](https://github.com/Bldg-7/shepherd/releases)

## 概要

hrdrhrdrhrdr は、ローカルまたは SSH 接続したマシン、保存済みの herdr マシン、ターミナル pane、コーディングエージェントのセッションを macOS 上の Herdr ワークスペースにまとめます。ネイティブのファイルプレビューとマシン管理に加え、対応する管理対象エージェント用の、pane ごとに分離されたオプトインの In-app Browser を提供します。

このリポジトリには、macOS アプリ、iPhone および iPad アプリ（`ShepherdMobile/`）、共有の `ShepherdKit` パッケージ、Web サイトとリリース用素材のソースが含まれます。上のダウンロードリンクはリリース済み macOS バイナリ用です。モバイルのソースがあることは、公開モバイル配信を意味しません。

## 主な機能

- This Mac、Settings で追加した SSH マシン、herdr が保存したマシンで作業できます。
- OSC 8 のファイルリンクを読み取り専用プレビューで開き、Markdown レンダリング、見出しの目次、検索、再読み込みを利用できます。
- ターミナルの Web リンクは対象 pane の In-app Browser で開き、Command キーを押しながらクリックすると macOS のデフォルトブラウザで開きます。対応する場合、HTML ファイルリンクも同じ境界に従います。
- QR コードと Remote Login で iPhone または iPad を This Mac とペアリングできます。ペアリングには Secure Enclave の鍵と、利用者による明示的な確認が必要です。
- 実験的ブラウザの準備が完了すると、新規タブのランチャーから新しいローカル管理対象 Claude Code、Codex、Pi セッションを開始できます。

詳しい操作、リモートマシンの動作、ペアリングのセキュリティ、会話キャプチャの範囲、機能上の注意は、**[英語のユーザーガイド](docs/user-guide.md)**を参照してください。

## 必要条件と制限

- macOS **26.6.2 以降**と、別途インストールした **Herdr** が必要です。
- 実験的な Chromium ベースの In-app Browser は既定で **オフ** で、Apple silicon でのみ動作します。Intel Mac では利用できませんが、ターミナル機能は利用できます。
- 管理対象ブラウザエージェントは任意です。Claude Code と Codex には Node **>=20** が必要です。Pi は **1.x (`^1.0.0`)** に対応し、Node **>=22.19.0** が必要です。
- エージェント CLI とその認証は利用者が管理します。ブラウザの準備、MCP の登録、ブラウザ接続、プロバイダ接続、資格情報の承認は、それぞれ別の状態です。
- Pi は新しいローカル管理対象 TUI セッションに対応します。保存済みセッションの再開、ブラウザを有効にした child/headless プロセス、セッション変更後の自動再認可、競合する MCP dispatch の抑止には対応しません。**Block other browser tools** は Pi には適用されません。

## はじめに

1. Herdr を別途インストールしてから、上のリンクでリリース済み macOS バイナリを入手するか、以下の手順でソースからビルドします。
2. hrdrhrdrhrdr を開き、This Mac に接続するか、**Settings → Machines** で SSH マシンを追加します。
3. 実験的ブラウザを使うには、**Settings → Experimental Features** で有効にし、Preparation が完了するまで待ちます。
4. 新規タブを開き、Shell、Claude Code、Codex、または Pi を選びます。エージェントは、CLI を自分でインストールして認証してから選んでください。

ブラウザリソースは新しい管理対象セッションにだけバンドルして注入されます。hrdrhrdrhrdr がグローバル MCP サーバーやスキルをインストールしたり、実行時に npm パッケージをダウンロードしたり、信頼を自動承認したり、エージェントの指示や拡張機能を置き換えたりすることはありません。認証済みブラウザ endpoint は pane ごとです。

**従来の `npx skills … --global` または `setup.sh` インストーラは実行しないでください。** 現在はインストールを拒否します。以前にグローバルな hrdrhrdrhrdr 登録をインストールした場合は、自分で確認して削除してください。アプリが暗黙に変更することはありません。

## ソースからのビルド

**Xcode 27** とその command-line tools を使います。リポジトリでは Swift 依存関係を `Package.resolved` に、Chromium/CEF を `scripts/cef.sh` に、ブラウザ用 Node パッケージを `package-lock.json` に固定しています。

```sh
scripts/cef.sh
npm ci --prefix Shepherd/Agents/AgentRuntime --ignore-scripts --no-audit --no-fund
open shepherd.xcodeproj
```

CEF と `node_modules` はコミット済みバイナリではなくビルド入力です。Xcode から求められた場合は、正確に SwiftTerm 1.20.0 のビルドプラグインだけを承認し、プラグイン検証をグローバルに無効化しないでください。Debug ビルドには Sparkle の更新フィードはありません。署名なしのローカルビルドには `CODE_SIGNING_ALLOWED=NO` を使用します。

## ドキュメント

- **[ユーザーガイド（英語）](docs/user-guide.md):** 詳細な使い方、プライバシーと信頼の境界、制限事項、商標に関する注意。
- **[Pi サポート](docs/pi-agent-support.md):** 管理対象 Pi の範囲と技術的なサポート境界（韓国語）。
- **[リンクを開く UX](docs/link-opening-ux.md):** 現在のリンクを開く規則と設計履歴（韓国語）。
- **[macOS リリース手順](docs/releasing-macos.md):** メンテナー向けのリリース手順（英語）。
- [0.3.1 リリースノート](notes/0.3.1.md) · [0.3.0 機能ノート](notes/0.3.0.md)
