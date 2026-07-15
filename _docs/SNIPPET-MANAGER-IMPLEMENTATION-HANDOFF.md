# 実装ハンドオフ: 定型文管理ウィンドウ

この1枚で着手できます。設計本体は [`SNIPPET-MANAGER-DESIGN.md`](SNIPPET-MANAGER-DESIGN.md)（Fable設計・司令塔裏取り済み）。

## 読む順
1. [`SNIPPET-MANAGER-DESIGN.md`](SNIPPET-MANAGER-DESIGN.md) 全体（特にC節のコード断片とG節の地雷）
2. `dist/soushin-suggest.ahk` の以下を実際に読んで現在地を確認: `ShowCsvDialog`(L424-446), `ShowLauncherSettingsMenu`(L449-463), `PromoteHistoryAt`(L770-789), `ImportSnippets`(L377-413)

## スコープ（MVPのみ、設計書E節）
- ListView一覧＋ラベル/本文編集フォーム＋新規追加/上書き保存/削除の3ボタン＋CSV出力/取込ボタン＋全クリアチェックボックス
- 入れないもの: 並べ替え、複数選択削除、列ソート、右クリックメニュー、インライン編集、検索

## 着手手順
1. ブランチ: `feature/snippet-manager-window`（`feature/export-import-file-exec`から派生、または現在のブランチの続き）
2. 設計書C節のコード断片をそのまま`dist/soushin-suggest.ahk`に追記（`ShowCsvDialog`定義の直後が自然な挿入位置）
3. `ShowCsvDialog`関数を削除
4. 歯車メニュー（`ShowLauncherSettingsMenu`内、現在「定型文CSV出力/取込...」の項目）とトレイメニュー（同名項目）を「定型文の管理...」→`ShowSnippetManager`に差し替え
5. バージョン文字列を更新（2箇所: `LauncherGui.Add("Text", ...)`のv1.4.1表示、トレイメニューの無効化されたバージョン項目）。v1.5.0を推奨（UI刷新のため）
6. ビルド: 必ず`scripts/build.ps1`経由。**ビルド前に`soushin-suggest.exe`プロセスを終了すること**（`Stop-Process -Name soushin-suggest -Force`、実行中だとexeがロックされコピー失敗する）

## 機械的な完了判定
- [ ] `scripts/build.ps1 -Version 1.5.0` がエラーなく完了し `dist/soushin-suggest.exe` が更新される
- [ ] 実機起動→歯車メニューから「定型文の管理...」で新ウィンドウが開く
- [ ] 一覧に既存の定型文（`続けて`/`日本語で`/`要約して`）が3行表示される
- [ ] 行クリックでフォームに読み込まれる
- [ ] 「新規追加」でsnippets.iniに1行追記され一覧に反映される
- [ ] 「上書き保存」で該当行だけが書き換わり、他の行・コメント行が消えない（`snippets.ini`をメモ帳で開いて目視確認）
- [ ] 「削除」で該当行だけが消える
- [ ] 「CSV出力」「CSV取込」が動作し、取込後に一覧が自動更新される
- [ ] 列ヘッダをクリックしても並び順が変わらない（`NoSort NoSortHdr`が効いている）ことを確認
- [ ] 既存のクイックペーストランチャー（サイドボタン長押し）の定型文タブでのワンキーペーストが壊れていないことを確認
- [ ] クリップボード履歴（非永続）が引き続きディスクに一切書き込まれないことを確認（設計変更の対象外だが回帰がないか一応確認）

## 地雷（再掲・最重要のみ）
- `NoSort NoSortHdr`を`ListView`のオプションから絶対に外さない（外すと行対応が壊れ誤削除・誤上書きが起きる）
- Editコントロールの改行はCRLF、メモリ上はLF、ini書き込みは`\n`文字列——3層の変換を毎回通す（設計書G-2）
- `SnipMgrWriteLine`の書き換え前ラベル検証（fail-closed）を省略しない。外部（メモ帳）で同時編集された場合に別の行を壊さないための唯一の防御
- 管理ウィンドウに`+AlwaysOnTop`を付けない（FileSelectダイアログが背後に隠れる）
- ランチャーのオーナー付き(`+Owner`)にしない

## 転記元（設計書からコピーする実在パス）
- `dist/soushin-suggest.ahk` — 唯一の実装対象ファイル
- `scripts/build.ps1` — ビルドスクリプト（変更不要、そのまま使う）

## 完了後
- コミットメッセージは設計書へのリンクと変更概要を含める
- `_docs/`の本ハンドオフとDESIGN.mdは実装完了後も残す（次回の参照用）
- 非自明だった実装判断（設計書との差分が生じた場合）があればメモリに記録
