# 実装ハンドオフ: クイックペースト機能の追加

このファイル1枚を読めば実装に着手できる。設計の背景・会議の議論・捨てた案は
[`QUICK-PASTE-LAUNCHER-DESIGN.md`](QUICK-PASTE-LAUNCHER-DESIGN.md) 参照（着手には必須ではない）。

## スコープ（MVPのみ）

- `dist/soushin-suggest.ahk` に、設計書D(1)〜D(4)のコードを追加する
- クリップボード履歴（メモリ内10件・非永続）と、XButton1長押しでのポップアップ選択→ペーストのみ実装
- Phase 2（snippets.ini定型文機能）はやらない
- LP文言修正（設計書G-7）は本タスクではやらない。必要なら別タスクとして起票する

## 着手手順

1. ブランチを切る: `git checkout -b feature/quick-paste-launcher`
2. `dist/soushin-suggest.ahk` を確認（`.ahk`ファイルはこの1つのみ、`src/`ディレクトリは存在しない）
3. 設計書D(1): グローバル宣言群（`global CopyOnSelect := true` 等がある箇所）に
   `ClipHistory` / `ClipHistoryMax` / `LongPressSec` / `LauncherGui` / `LauncherTarget` を追加
4. ファイル冒頭 `#SingleInstance Force` の直後に `CoordMode "Mouse", "Screen"` を追加
5. 設計書D(2): sites.iniパーサの `else if` 分岐に `[general] longpress=` の読み取りを追加。
   `dist/sites.ini` に `[general]` セクションのコメント付き雛形を追記
6. 設計書D(3): なぞってコピー成功時の分岐（`if (A_Clipboard != "" && A_Clipboard != prev)` の中）に
   `PushClipHistory(A_Clipboard)` の呼び出しを追加し、`PushClipHistory`関数を新規定義
7. 設計書D(4): 既存の `XButton1::Send("#{PrintScreen}")` の1行を、長押し判定つきの新ハンドラに置換。
   `ShowLauncher` / `PasteFromLauncher` / `CheckLauncherFocus` / `CloseLauncher` を新規定義
8. 右クリック長押しの `"T0.35"` を `"T" . LongPressSec` に統一

## ビルド

**Git Bashから直接Ahk2Exeを呼ばない。** 必ず `scripts/build.ps1`（PowerShell経由）を使うこと。

## 完了判定（機械的に確認できるもの）

- [ ] `grep -c 'ClipHistory' dist/soushin-suggest.ahk` が3以上（宣言・Push・参照）
- [ ] `grep -c 'ShowLauncher' dist/soushin-suggest.ahk` が2以上（定義＋呼び出し）
- [ ] `scripts/build.ps1` がエラーなく完走し、`.exe`が生成される

## 実機検証（reality-checkerに委任推奨）

- [ ] 許可リスト外アプリ（例: ゲーム、Excel）でXButton1を押下→即座にスクリーンショットが起動する（遅延なし）
- [ ] ブラウザ（Chrome/Edge）でXButton1を短押し→スクリーンショット
- [ ] 同じくXButton1を0.35秒以上長押し→カーソル位置にリストがポップアップ
- [ ] なぞってコピーを2〜3回行った後に長押し→それぞれの履歴がリストに並ぶ（新しい順）
- [ ] リストの1項目をクリック→リストが消え、フォーカスが戻ったウィンドウにその内容が貼り付けられる
- [ ] リスト表示中にリスト外をクリック、またはEscキー→何もペーストされずリストだけ消える
- [ ] 履歴が0件の状態で長押し→「履歴がありません」というToolTipが出るだけ
- [ ] マルチモニタ環境がある場合、サブモニタ上でもポップアップが正しいカーソル位置に出る

## 地雷（実装時に必ず守ること）

- `CoordMode "Mouse", "Screen"` を入れ忘れるとマルチモニタ/最大化以外でポップアップ位置がずれる
- `ShowLauncher`内の処理順序（`Show` → `WinActivate` → `SetTimer`）を変えない。順序を崩すとGUI表示直後に自分自身を閉じてしまう競合状態が起きる
- `PasteFromLauncher`内の`Sleep 150`を削らない。フォーカス移行前にペーストが飛んで失敗することがある。Electron系アプリ（ChatGPT.exe等）で失敗する場合は250まで伸ばす
- クリップボード履歴は「なぞってコピー」経由のみで積む。`OnClipboardChange`のようなグローバル監視は追加しない（パスワードマネージャ等の機密情報が混入するリスクがあるため、設計上意図的に除外している）
- 履歴をディスクに保存する処理を追加しない（意図的に非永続設計）

## 検証

verify skillまたはreality-checkerエージェントに検証を委任すること。特にゲーム中の誤爆リスクがゼロになっているか（許可リスト外での短押し即発火の維持）は、この機能追加の設計上の核心なので重点的に確認する。

## 次にやること（このタスクの外）

- 設計書G-7に記載のLP文言修正（サイドボタン説明への追記、BY THE NUMBERSの行数更新）は別タスク
- Phase 2の定型文（snippets.ini）機能は別タスク
- HANDOFF-next-session.mdにある他の未完了項目（LINE Bot実機テスト、ref付きURL変更）とは無関係
