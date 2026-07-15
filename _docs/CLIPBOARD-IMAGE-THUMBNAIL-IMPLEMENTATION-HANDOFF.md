# 実装ハンドオフ: 画像クリップボード履歴への実サムネイル表示

設計本体は [`CLIPBOARD-IMAGE-THUMBNAIL-DESIGN.md`](CLIPBOARD-IMAGE-THUMBNAIL-DESIGN.md)。

## 読む順
1. 上記設計書全体（特にC-1のオフセット計算、G節の地雷）
2. `dist/soushin-suggest.ahk`の`ShowSnippetManager`（`SnipMgrHistLV`生成箇所）、`SnipMgrHistRefresh`
3. [`CLIPBOARD-IMAGE-HISTORY-DESIGN.md`](CLIPBOARD-IMAGE-HISTORY-DESIGN.md)（前提となる画像履歴の実装、既に完了・コミット済み）

## スコープ（MVP、設計書E節）
- 「定型文の管理」ウィンドウの履歴タブ（ListView）にのみサムネイル表示
- クイックペーストランチャー（ListBox）は対象外（プレースホルダーテキストのまま）
- ImageList肥大時のリビルド機構も含める（メモリリーク対策として必須）

## 着手手順
1. 現在のブランチ`feature/clipboard-image-history`で継続、または新規ブランチ
2. 設計書C-1〜C-3のコード断片を追加
3. `ShowSnippetManager`に`EnsureHistThumbIL()`呼び出しを1行追加
4. `SnipMgrHistRefresh`のAdd行を2行に差し替え
5. バージョン文字列更新（v1.7.0）
6. ビルド: `scripts/build.ps1`経由、ビルド前にプロセス終了

## 機械的な完了判定
- [ ] ビルドがエラーなく完了
- [ ] 画像をコピーして「定型文の管理」の履歴タブを開くと、実際のサムネイル画像が行の左に表示される
- [ ] サムネイルが崩れていない（色ズレ・オフセットズレがない）ことを目視確認。特に濃い色/淡い色の両方の画像で確認
- [ ] テキスト履歴の行にはアイコンが付かない（Icon0が効いている）
- [ ] 画像を6件以上コピーし、ImageListの肥大化対策（32件超でリビルド）が発火してもクラッシュしないことを確認（現実的には多数回コピーが必要なので、時間があれば確認）
- [ ] クイックペーストランチャーの履歴タブは従来通りプレースホルダーテキストのまま（サムネイルなし）で問題なく動作する
- [ ] 「定型文の管理」ウィンドウを閉じて再度開いても正常動作する（ImageListの再利用・再構築が壊れていない）
- [ ] 既存のテキスト履歴・定型文機能に回帰がないこと

## 地雷（再掲・最重要のみ）
- CF_DIBのオフセット計算で`+14`（BITMAPFILEHEADER前提）を絶対に使わない。CF_DIBはBITMAPINFOHEADERから直接始まる（G-1）
- `MakeHistThumb`内でHBITMAPを生成したら、`ImageList_Add`直後に必ず`DeleteObject`する（G-4）
- `SelectObject`でDCから外してから`ImageList_Add`する（外さないと失敗する）
- テキスト行に`Icon0`を明示しないと1番目のサムネイルが全行に表示される（G-5）
- `SetStretchBltMode(HALFTONE)`の後は`SetBrushOrgEx`を呼ぶ（G-6）

## 転記元（設計書からコピーする実在パス）
- `dist/soushin-suggest.ahk` — 唯一の実装対象ファイル
- `scripts/build.ps1` — ビルドスクリプト（変更不要）

## 完了後
- コミットメッセージは設計書へのリンクと変更概要を含める
- 非自明だった実装判断（設計書との差分が生じた場合）があればメモリに記録
