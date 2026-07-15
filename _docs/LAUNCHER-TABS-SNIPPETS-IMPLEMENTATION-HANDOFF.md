# 実装ハンドオフ: クイックペーストのタブUI・定型文・お気に入り起動

このファイル1枚を読めば実装に着手できる。設計の背景・会議の議論・捨てた案は
[`LAUNCHER-TABS-SNIPPETS-DESIGN.md`](LAUNCHER-TABS-SNIPPETS-DESIGN.md) 参照（着手には必須ではない）。

前提: [`QUICK-PASTE-LAUNCHER-DESIGN.md`](QUICK-PASTE-LAUNCHER-DESIGN.md)のクイックペースト機能が
`dist/soushin-suggest.ahk`に実装済み・実機確認済みであること（`feature/quick-paste-launcher`ブランチ、
コミット`009e791`）。

## スコープ（MVPのみ）

- `dist/soushin-suggest.ahk` の `ShowLauncher` / `PasteFromLauncher` を、設計書D節のコードで置換・拡張
- `dist/snippets.ini` を新規作成
- **フルスペックの検索・アプリ起動機能は実装しない**（設計書Bで明確に却下済み）。定型文の`run:`プレフィックスのみ実装

## 着手手順

1. ブランチを切る（`feature/quick-paste-launcher`から派生、または同ブランチで継続）: `git checkout -b feature/launcher-tabs-snippets`
2. `dist/soushin-suggest.ahk` を確認し、`grep -n "^ShowLauncher\|^PasteFromLauncher\|^XButton1"` で現在の行番号を再特定
3. 設計書D(1): `global`宣言群に `Snippets := []` を追加
4. 設計書D(2): `LoadSnippets()` 関数を新規追加（sites.iniのパーサとは別関数にすること — 地雷3）
5. 設計書D(3): 既存の `ShowLauncher()` を、Tab3を使った2タブ版に置換
6. 設計書D(4): 既存の `PasteFromLauncher` を `PasteHistoryItem` / `UseSnippetItem` / `PasteText` の3関数に分割
7. `dist/snippets.ini` を新規作成（設計書D(5)の内容）
8. `scripts/build.ps1` を確認し、zip同梱ファイルのリストに `snippets.ini` が含まれているか確認。含まれていなければ追加

## ビルド

**Git Bashから直接Ahk2Exeを呼ばない。** 必ず `scripts/build.ps1`（PowerShell経由）を使うこと。

## 完了判定（機械的に確認できるもの）

- [ ] `grep -c 'Tab3' dist/soushin-suggest.ahk` が1以上
- [ ] `grep -c 'LoadSnippets' dist/soushin-suggest.ahk` が2以上（定義＋呼び出し）
- [ ] `grep -c 'run:' dist/soushin-suggest.ahk` が1以上
- [ ] `test -f dist/snippets.ini` が真
- [ ] `wc -l dist/soushin-suggest.ahk` が400行を超えていない（設計書の防衛線）
- [ ] `scripts/build.ps1` がエラーなく完走し、`.exe`が生成される

## 実機検証（reality-checkerに委任推奨）

- [ ] 許可リスト外アプリでXButton1押下→即座にスクリーンショット（既存機能の回帰なし）
- [ ] ブラウザでXButton1を長押し→タブが2枚（「履歴 N」「定型文 N」）のポップアップが出る
- [ ] 履歴タブの項目を1クリック→元ウィンドウにペースト（既存機能の回帰確認）
- [ ] 定型文タブの項目（`run:`なし）を1クリック→本文がペーストされる。`\n`が実際の改行になっている
- [ ] `snippets.ini`に`run:`で始まる行を追加し、長押し→定型文タブでその行をクリック→対象のexe/ファイルが起動する（リスト上に「▶」印がついている）
- [ ] `run:`の対象パスをわざと間違えてクリック→エラーで落ちず、ToolTipで「起動できませんでした」とだけ出る
- [ ] クリップボード履歴が0件、`snippets.ini`に内容がある状態で長押し→定型文タブが自動的に開く
- [ ] クリップボード履歴・`snippets.ini`ともに空の状態で長押し→「履歴がありません」のToolTipのみ
- [ ] `snippets.ini`をアプリ実行中に編集して保存→アプリを再起動せずに次の長押しで変更が反映される
- [ ] リスト外クリック、またはEscキー→ポップアップが閉じるだけで何も起きない

## 地雷（実装時に必ず守ること）

- `Tab`ではなく`Tab3`を使うこと（AHK v2でのネイティブタブ実装として正しいのはTab3）
- `snippets.ini`のパーサは、既存の`sites.ini`用パーサ（インラインコメント`;`を剥がす仕様）を流用・共用しない。定型文の本文には`;`が普通に含まれうるため、別関数として実装すること
- `IniRead`は使わない。日本語キー（定型文のラベル）を誤読する既知の罠がある
- `ShowLauncher`内の処理順序（`Show` → `WinActivate` → `SetTimer`）を変更しないこと。順序を崩すと表示直後に自分自身を閉じる競合状態が起きる
- `run:`の起動処理は必ず`try`で包むこと。パスの誤りや移動済みファイルで例外が飛ぶ可能性がある
- クリップボード履歴機能（`ClipHistory`, `PushClipHistory`）・XButton1ハンドラの許可リストゲーティング構造には一切手を加えないこと
- **400行を超える追加提案が出た場合、実装を進めず設計上の防衛線として一旦立ち止まり、報告すること**

## 検証

verify skillまたはreality-checkerエージェントに検証を委任すること。既存のクイックペースト機能（履歴タブ）の回帰確認と、`run:`起動処理のエラーハンドリング（存在しないパスでクラッシュしないこと）を重点的に確認する。

## 次にやること（このタスクの外）

- 設計書G-10に記載のLP文言修正（クイックペースト説明への追記）は別タスク
- HANDOFF-next-session.mdにある他の未完了項目（LINE Bot実機テスト、ref付きURL変更）とは無関係
