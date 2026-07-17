# 実装ハンドオフ: 設定統合(MVP)

この1枚で着手できます。設計本体は [`SETTINGS-UNIFICATION-DESIGN.md`](SETTINGS-UNIFICATION-DESIGN.md)(会議ハーネス→Fable設計・司令塔裏取り済み)。

## 読む順
1. [`SETTINGS-UNIFICATION-DESIGN.md`](SETTINGS-UNIFICATION-DESIGN.md) 全体(特にC節のコード断片・E節のMVPスコープ・G節の地雷)
2. `dist/soushin-suggest.ahk` の以下を実際に読んで現在地を確認:
   - `SaveIniKey`(L1431-1455) — 廃止対象。挿入位置バグの現物
   - `ShowSettingsWindow`(L1587-1616), `ApplyArchiveToggle`(L1620-1641) — 拡張対象
   - トレイメニュー定義(L1984-2011) — 自動起動トグルの削除対象
   - 起動時の自動起動チェック(L184-186、`shell:startup`のFileExist判定) — 変更しない(唯一の真実として維持)
   - `sites.ini`の`[general]`/`[clipboard]`読み込み箇所(`LoadSitesConfig`) — settings.ini存在時に読み飛ばす分岐を追加

## スコープ(MVPのみ、設計書E節)
- `SettingsStore`(メモリMap + デバウンス書き込み + 原子リネーム)を新設
- `Migrator`(起動時1回、settings.ini不在時のみ実行)を新設
- `ShowSettingsWindow`に「Windows起動時に自動実行」「クリップボード監視」の2チェックボックスを追加、即時反映
- トレイメニューから自動起動トグルを削除(設定ウィンドウに一本化)
- 入れないもの: 基本/高度タブ分割、上級者モード、DropDownList化、sites.ini再読込ボタン(すべて第2歩)

## 着手手順
1. ブランチ: `feature/settings-unification`
2. `SettingDefs`(静的Map: キー→{section, default, apply})を定義。既存グローバル変数(`ClipHistoryMax`等)への代入をapply関数に集約
3. `SetSetting(key, val)` / `FlushSettings()` を設計書C-2のコード断片どおり実装(`FileOpen(..., "w", "UTF-8-RAW")` + `MoveFileExW`原子リネーム + 300msデバウンス)
4. `Migrator`を実装(設計書C-4)。`sites.ini`は移行時に日付付きバックアップ(`sites.ini.bak-YYYYMMDD`)を1回だけ作成
5. `SaveIniKey`(L1431)を削除。`ApplyArchiveToggle`の呼び先を`SetSetting`に差し替え
6. `ShowSettingsWindow`に2チェックボックス追加。`OnEvent("Click", ...)` → `SetSetting`直結(保存ボタンなし)
7. トレイメニュー(L1984-2011)から自動起動トグル項目を削除
8. `LoadSitesConfig`に「settings.ini存在時は`[general]`/`[clipboard]`を読み飛ばす」分岐を追加。`sites.ini`冒頭に案内コメント1行をMigratorが挿入
9. 起動時ロードで先頭`EF BB BF`(BOM)をスキップする1行を追加(過去生成ファイルの後方互換)
10. バージョン文字列更新(トレイメニューの無効化されたバージョン項目、設定ウィンドウのタイトル等)。v1.13.0を推奨
11. ビルド: 必ず`scripts/build.ps1`経由。**ビルド前に`soushin-suggest.exe`プロセスを終了すること**(`Stop-Process -Name soushin-suggest -Force`、実行中だとexeがロックされコピー失敗する)

## 機械的な完了判定
- [ ] `scripts/build.ps1 -Version 1.13.0` がエラーなく完了し `dist/soushin-suggest.exe` が更新される
- [ ] 初回起動(settings.ini削除状態)で自動的に`settings.ini`が生成され、旧`sites.ini`の`[general]`/`[clipboard]`値が引き継がれている(`settings.ini`をメモ帳で開いて目視確認)
- [ ] `sites.ini.bak-YYYYMMDD`が1つだけ生成される(重複生成されないことを2回起動して確認)
- [ ] `settings.ini`の先頭バイトがBOM無し(`EF BB BF`で始まらない)であることをバイナリエディタ/`Format-Hex`で確認
- [ ] 設定ウィンドウで「クリップボード監視」チェックを外す→トレイの一時停止と状態が同期する(どちらから変更しても他方に反映)
- [ ] 「Windows起動時に自動実行」チェックのON/OFFで`shell:startup`のショートカットが実際に作成/削除される
- [ ] 設定変更後、`settings.ini`が300ms程度の遅延後に更新される(保存ボタンを押していないのに反映されることを確認)
- [ ] 設定ウィンドウを開いたままクリップボードにコピー操作を行い、履歴監視が継続して動作する(ウィンドウが監視をブロックしない)
- [ ] アプリ終了時(トレイ「終了」)に未反映の変更があれば`OnExit`で最終Flushされ、`settings.ini`に残ることを確認
- [ ] 既存の`sites.ini`に混入していた`archiveimage=on`/`archivetext=on`(該当環境がある場合)が削除されず、値だけ`settings.ini`に引き継がれ、`sites.ini`自体は無変更で残ることを確認
- [ ] 既存のクイックペーストランチャー・定型文管理・送信サジェスト判定が壊れていないことを回帰確認

## 地雷(再掲・最重要のみ)
- `settings.ini`の書き出しは**全文再生成のみ**。read-modify-writeの文字列手術を1行たりとも復活させない(混入バグの再発防止の核心)
- `FileOpen(..., "w", "UTF-8-RAW")`を必ず使う。`FileAppend`との併用や別のエンコーディング指定に戻さない(BOM論争を構造的に解消した部分)
- tmpファイル→`MoveFileExW`の原子リネームを省略しない。`FileDelete`→`FileAppend`の2段書きに戻すと全損の窓が復活する
- `sites.ini`への書き込みコードパス(`SaveIniKey`)を完全に削除する。中途半端に残すと混入バグの温床が残る
- 自動起動の状態を`settings.ini`に二重管理しない。`shell:startup`のショートカット実在が唯一の真実(L184-186の判定ロジックを流用・変更しない)
- 設定ウィンドウは非モーダル・シングルトン+Hideのまま(既存`SnipMgrGui`と同じ流儀)。モーダル化すると常駐監視がブロックされる

## 転記元(設計書からコピーする実在パス)
- `dist/soushin-suggest.ahk` — 唯一の実装対象ファイル
- `scripts/build.ps1` — ビルドスクリプト(変更不要、そのまま使う)

## 完了後(第2歩への引き継ぎ)
- 基本/高度タブ分割・上級者モード・DropDownList化・sites.ini再読込ボタンは設計書D節・C-3節を参照して第2歩として実施
- コミットメッセージは設計書へのリンクと変更概要を含める
- `_docs/`の本ハンドオフとDESIGN.mdは実装完了後も残す(次回の参照用)
- 非自明だった実装判断(設計書との差分が生じた場合)があればメモリに記録
