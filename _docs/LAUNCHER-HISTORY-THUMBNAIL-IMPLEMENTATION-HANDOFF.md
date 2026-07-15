# 実装ハンドオフ: ランチャー履歴タブへの実サムネイル表示

設計本体は [`LAUNCHER-HISTORY-THUMBNAIL-DESIGN.md`](LAUNCHER-HISTORY-THUMBNAIL-DESIGN.md)。

## 読む順
1. 上記設計書全体（特にB節の判断理由、G-1の`LVS_SHAREIMAGELISTS`地雷）
2. `dist/soushin-suggest.ahk`の`ShowLauncher()`（`LauncherLbH`生成箇所）、`LauncherWatchHover`、`LauncherItemUnderMouse`、`LauncherContextMenu`、`LauncherPickKey`、`RefreshLauncherHistory`、`HistoryListItems`
3. [`CLIPBOARD-IMAGE-THUMBNAIL-DESIGN.md`](CLIPBOARD-IMAGE-THUMBNAIL-DESIGN.md)（前提のサムネイル機構、既に実装済み）

## スコープ（MVP、設計書E節）
- ランチャーの履歴タブをListBoxからListViewに置換し、画像行にサムネイル表示
- 定型文タブのListBoxは変更しない
- ImageList共有（`LVS_SHAREIMAGELISTS`）とResponsibility分離（`EnsureHistThumbIL`/`RebuildHistThumbILIfBloated`）を必ず含める

## 着手手順
1. 現在のブランチで継続、または新規ブランチ
2. `LauncherLbH`を`LauncherLvH`に改名（変数宣言含め全参照箇所を機械的に置換）
3. 設計書C-2〜C-5のコード断片を適用
4. `SnipMgrHistLV`生成オプションに`+0x40`（LVS_SHAREIMAGELISTS）を追加
5. バージョン文字列更新
6. ビルド: `scripts/build.ps1`経由、ビルド前にプロセス終了

## 機械的な完了判定
- [ ] ビルドがエラーなく完了
- [ ] ランチャーを開くと、画像履歴の行に実際のサムネイルが表示される
- [ ] クリックでペーストされる（従来通り）
- [ ] 数字キー（1-9,0）でペーストされる（従来通り）
- [ ] ホバーでToolTipが表示される（従来通り）
- [ ] 右クリックでメニューが出る（ペーストが暴発しないこと！）
- [ ] **最重要**: ランチャーを何度か開閉した後、「定型文の管理」ウィンドウの履歴タブを開き、サムネイルが健在であることを確認（`LVS_SHAREIMAGELISTS`が正しく効いているかの検証）
- [ ] ランチャーの最終行が欠けずに見える（スクロールバーが不要に出ていない）
- [ ] 「定型文の管理」を先に一度も開かずにランチャーだけ先に開いても正常動作する（`EnsureHistThumbIL`の責務分離確認）
- [ ] 既存のテキスト履歴・定型文タブの動作に回帰がないこと

## 地雷（再掲・最重要のみ）
- `LVS_SHAREIMAGELISTS`(+0x40)を絶対に外さない。外すとランチャーのGUI破棄のたびに共有ImageListがOSに破棄され、「定型文の管理」側のサムネイルまで巻き添えで消える（G-1）
- 右クリックによるItemSelect発火で誤ペーストしないよう、`GetKeyState("RButton", "P")`ガードを外さない（G-4）
- `Icon0`をテキスト行に明示しないと、全行に1枚目のサムネイルが表示される（G-5）
- Rebuild時は「生存ビューへの再アサイン→旧IL破棄」の順序を守る（G-3）

## 転記元（設計書からコピーする実在パス）
- `dist/soushin-suggest.ahk` — 唯一の実装対象ファイル
- `scripts/build.ps1` — ビルドスクリプト（変更不要）

## 完了後
- コミットメッセージは設計書へのリンクと変更概要を含める
- 非自明だった実装判断（設計書との差分が生じた場合）があればメモリに記録
