# 実装ハンドオフ: クリップボード履歴のフォルダ永続保存

設計本体は [`CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md`](CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md)。

**これは製品の核心的な安全設計（履歴は非永続）を覆す重大な変更です。実装前に必ず設計書のD節・H節を読み、矛盾解消の論理を理解してから着手してください。**

## 読む順
1. 設計書全体（特にD節の矛盾解消ロジック、G節の地雷、H節の過去判断との関係）
2. `dist/soushin-suggest.ahk`の`MaybeDropAutoCleared`、`PushClipHistory`、`PushClipImage`、`LoadSitesConfig`、`ClipExcludeExes`、既存の`DibBitsOffset`/`MakeHistThumb`（サムネイル機能で実装済みのCF_DIB処理パターン）
3. `_docs/CLIBOR-PARITY-JUDGMENT.md`（過去の却下判断の原文）

## スコープ（2段階MVP、設計書E節）
- **MVP-1（画像のみ）を先に実装・検証してからMVP-2（テキスト・検疫）に進むこと**。検疫ロジックはバグがあると安全性に直結するため、段階的に導入する
- MVP外: 保存容量の自動管理、過去履歴の一括エクスポート

## 着手手順
1. 新規ブランチ（例: `feature/clipboard-history-archive`）
2. MVP-1: `SaveIniKey`/`ArchiveDir`/`SaveDibAsPng`/`SaveDibAsBmp`/`PngEncoderClsid`/`ToggleArchiveImage`を実装。**`SaveDibAsPng`は既存の`DibBitsOffset`関数を再利用すること**（新規に書き直さない）
3. ビルド・実機確認（後述の完了判定）
4. MVP-2: `QueueTextArchive`/`CommitPendingArchive`/`ToggleArchiveText`、`MaybeDropAutoCleared`と削除系へのフック
5. `dist/soushin-suggest.ahk`21行目付近の「永続化禁止」コメントを設計書B節の文言に更新
6. `_docs/CLIBOR-PARITY-JUDGMENT.md`に「2026-07-15改定」節を追加し、本設計書への参照を張る（設計書H節推奨事項）
7. バージョン文字列更新
8. ビルド: `scripts/build.ps1`経由、ビルド前にプロセス終了

## 機械的な完了判定

### MVP-1（画像）
- [ ] ビルドがエラーなく完了
- [ ] トレイメニューで「スクショをフォルダに保存」をONにすると警告ダイアログが出る
- [ ] ONにした状態でスクショをコピーすると、`clip-archive`フォルダに実際にPNGファイルが作られる
- [ ] PNGファイルを画像ビューアで開いて、正しく表示される（色化けしていない）
- [ ] アプリを再起動しても設定がONのまま維持される（`sites.ini`を確認）
- [ ] OFFに戻すと新規保存が止まる

### MVP-2（テキスト・検疫）
- [ ] 「テキスト履歴をフォルダに保存」をONにしてテキストをコピーすると、**45秒+2秒後**に日次ファイルに追記される（即座には書かれないことを確認）
- [ ] KeePass等でコピーし45秒以内にクリアされた場合、日次ファイルに**一切書かれない**ことを確認（最重要）
- [ ] 「履歴を全削除」をすると検疫中の項目も保存されない
- [ ] 既存のテキスト履歴・画像履歴・定型文機能に回帰がないこと

## 地雷（再掲・最重要のみ）
- 検疫窓は`ClipAutoClearSec*1000 + 2000`。短くするとクリア検知より先にディスクへ書いてしまう（G-2）
- `OnExit`時、検疫中の項目は書かずに破棄する（G-3、fail-closed）
- CF_DIBのピクセルオフセット計算は既存の`DibBitsOffset`を再利用する。独自に再実装しない（G-4）
- `SaveIniKey`はread-modify-write。トグル操作時の1回だけ書く設計を守る（G-5）

## 転記元（設計書からコピーする実在パス）
- `dist/soushin-suggest.ahk` — 唯一の実装対象ファイル
- `scripts/build.ps1` — ビルドスクリプト（変更不要）
- `_docs/CLIBOR-PARITY-JUDGMENT.md` — 改定節を追加する対象

## 完了後
- コミットメッセージは設計書へのリンクと変更概要、および「安全設計の大転換である」ことを明記する
- 非自明だった実装判断（設計書との差分が生じた場合）は必ずメモリに記録（project型、今後同種の要望が出た際の判断基準として重要）
