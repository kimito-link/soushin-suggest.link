# 実装ハンドオフ: /shindan/ 診断ページのUI構造リグレッション確認拡張（MVP）

設計は完了済み。このファイル1枚で着手できる。設計の全文は [`SHINDAN-UI-STRUCT-DESIGN.md`](SHINDAN-UI-STRUCT-DESIGN.md) 参照（読む場合はE節・G節だけで足りる）。

## スコープ（MVPのみ）

`dist/soushin-suggest.ahk`の4箇所のみ。ビューア拡張（`shindan/index.html`）とverifyスクリプト新設はスコープ外（設計書E節、後続タスク）。

1. L100付近（`DiagEndpoint`宣言の直後）にグローバル2つ追加（設計書C-2(a)）
2. `BuildDiagText()`（L289付近）の直後に`DiagCaptureUiSnapshot()`を新設。**必ず`;@Ahk2Exe-IgnoreBegin`/`;@Ahk2Exe-IgnoreEnd`で囲むこと**（設計書C-2(b)）
3. `ShowLauncher()`の`LauncherSearchEdit.Focus()`（L1542付近）の直後に呼び出しを追加。**これも同様にIgnoreブロックで囲むこと**（設計書C-2(c)、G-2の地雷）
4. `BuildDiagText()`の`return`文（L288付近、`return s . "}}"`）を設計書C-2(d)の形に変更

## 着手手順

1. `git status`で作業ツリーがクリーンか確認（他の未コミット変更と混ぜない。現時点で`_docs/winv-ab-test-log.md`・`shindan/index.html`のダークモードCSS等が未コミットのまま残っている可能性がある）
2. ブランチを切る（例: `feat/shindan-ui-struct`）
3. 上記4箇所を実装
4. `AppVersion`をパッチバージョン+1に更新
5. **`scripts/build.ps1`を1回通してexeが正常に起動することを確認**（設計書G-2: Ignoreブロックの片割れを消し忘れると本番exeが起動時ロードエラーで全機能死する）
6. 検証（下記）

## 検証（機械的な完了判定）

1. **開発モード（.ahk直接実行）**: `dist/soushin-suggest.ahk`をAutoHotkey64.exeで起動→ランチャーを開く→トレイ「診断情報をコピー」→クリップボードのJSONに`"ui":{...}`が含まれ、`ctrls`配列にランチャーのコントロール一覧（Text/Tab3/Edit/ListView×2）が入っていることを確認
2. **本番モード（コンパイル後exe、最重要の逆アサート）**: `scripts/build.ps1`でビルドしたexeを起動→同様に「診断情報をコピー」→JSONに`"ui"`キーが**存在しないこと**を確認（設計書G-3）。これが通らない限りマージしない
3. `+Grid`回帰確認: `ctrls`内のListViewエントリの`rows`が実際の表示件数（最大10、Min(Max(...),10)の仕様どおり）と一致すること
4. 白化バグの再発が無いこと（ランチャーを複数回開閉して確認、既存の回帰確認と同じ）

reality-checkerへの委任を推奨。特に検証2（本番exeへの非混入）はコードレビューだけでなく実機ビルドでの確認が必須。

## 地雷（設計書G節から転記、特に重要なもの）

- **Win32 UI読み取りをタイマー/送信経路に置かない**（白化バグと同じクラスの再発防止、G-1）。`DiagCaptureUiSnapshot()`はランチャー表示時の1回のみ呼ぶこと。5分自動送信タイマー側からは絶対に呼ばない。
- **Ignoreブロックは定義と呼び出しの両方を囲む**（G-2）。片方だけだと本番exeがロードエラーで起動しなくなる。
- コントロールの`.Text`・ListView項目文字列・ウィンドウタイトルは読まない（G-5、プライバシー原則）。座標・種類・件数・可視性のみ。

## 対象外（今回やらないこと・設計書F節参照）

- ハッシュ＋オンデマンド差分方式（過剰設計と判断）
- 環境変数/iniによるオプトインゲート（`A_IsCompiled`の方が誤設定不可能で安全）
- 専用トレイメニュー項目の追加
- UI構造用の別APIエンドポイント/別KVキー
- 5分タイマーでの再キャプチャ
- `/shindan/`ビューアへの表示（`shindan/index.html`の`renderUiSection()`）— MVP後の後続タスク
- `scripts/verify-ui-snapshot.ps1`の新設 — MVP後の後続タスク

## 次にやるとしたら

MVP（AHK側の`ui`フィールド送信）が動作確認できたら、`shindan/index.html`のビューア拡張（設計書C-5）→`scripts/verify-ui-snapshot.ps1`新設（設計書C-6）の順で着手する。
