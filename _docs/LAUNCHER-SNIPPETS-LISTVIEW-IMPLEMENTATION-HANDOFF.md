# ランチャー「定型文」タブ ListView化 実装ハンドオフ

設計書: [`LAUNCHER-SNIPPETS-LISTVIEW-DESIGN.md`](LAUNCHER-SNIPPETS-LISTVIEW-DESIGN.md) を先に読むこと。
このファイル単独でMVP(第1コミット)に着手できる粒度でまとめる。

## スコープ(MVPのみ)

設計書E節の「第1コミット」だけ。具体的には:
1. `LauncherLbS`(ListBox)を`LauncherLvS`(ListView)に置き換え(C-1)
2. `FillLauncherSnippetsLB`を`FillLauncherSnippetsLV`に改修(C-2)
3. `LauncherSnipSelect`を新設し、選択イベントをListBoxの`Change`からListViewの`ItemSelect`へ(C-3)
4. `LauncherLbS`への全参照(グローバル宣言・`LauncherTabChanged`・`LauncherFilterChanged`・`LauncherWatchHover`)を`LauncherLvS`に置換
5. `LauncherItemUnderMouse`(LB専用ヒットテスト)を削除、`LauncherLVItemUnderMouse`へ統一

高さ調整(C-4)・ドキュメント相互参照(C-7)は次のコミットで良い。

## 着手手順

1. ブランチを切る(例: `feature/snippets-tab-listview`)
2. `dist/soushin-suggest.ahk`で現状の該当箇所を実測確認(以下は目安の行番号、実装時にはGrepで再確認すること):
   - `LauncherLbS`の宣言・生成箇所(グローバル宣言40行付近、`ShowLauncher`内1293行付近)
   - `FillLauncherSnippetsLB`(2704行付近)
   - `LauncherItemUnderMouse`(2555行付近)・`LauncherLVItemUnderMouse`(2566行付近、変更不要・参照先として確認のみ)
   - `LauncherWatchHover`(2586行付近)の`LauncherLbS`参照
   - `LauncherTabChanged`・`LauncherFilterChanged`(1211〜1241行付近)の`LauncherLbS`参照
3. 設計書C-1のコードで`LauncherLvS`を生成(`LauncherLvH`の生成コードを引き算コピー、ImageList関連は付けない)
4. 設計書C-2のコードで`FillLauncherSnippetsLV`を実装(既存`FillLauncherSnippetsLB`の中身をほぼそのまま移植)
5. 設計書C-3のコードで`LauncherSnipSelect`を新設し、`OnEvent("ItemSelect", LauncherSnipSelect)`に差し替え
6. `LauncherLbS`への残る参照を全て`LauncherLvS`に置換(`grep -n "LauncherLbS" dist/soushin-suggest.ahk`で0件になるまで)
7. `LauncherItemUnderMouse`関数を削除(呼び元が無くなったことを確認してから)
8. 実機ビルド&手動確認(下記チェックリスト)

## 機械的な完了判定

- [ ] `grep -n "LauncherLbS" dist/soushin-suggest.ahk`が0件
- [ ] `grep -n "LauncherItemUnderMouse(" dist/soushin-suggest.ahk`が0件(定義・呼び出しとも削除済み)
- [ ] サイドボタンでスクショを撮った直後、定型文タブを開いてもリストが白くならない(これが今回の主目的)
- [ ] 定型文をクリックすると即座にペーストされる(現状と同じ挙動)
- [ ] 1〜9,0キーで先頭10件が選択・使用される
- [ ] 検索ボックスに文字を入力すると絞り込まれ、絞り込み後の1〜9,0キー・クリック・ホバーツールチップが正しい実体を指す
- [ ] 40件超の定型文でスクロールバーが機能し、最後まで遡れる(これがListBox却下の決定打だった実機事象。同条件での回帰確認が受け入れ基準)
- [ ] `run:`で始まる定型文が「▶ 」付きで表示される
- [ ] ホバーで全文ツールチップが表示される
- [ ] `grep -n "TEMP-VERIFY" dist/soushin-suggest.ahk`でデバッグコード残置なし

## 地雷(設計書G節から特に着手時に注意すべきもの抜粋)

- ListBoxのスタイルフラグ調整による延命は絶対に検討しない(過去に2回試して実機で失敗が確定している)
- 定型文に件数上限(`DisplayMax`相当)を新規導入しない(意図的な非対称、設計書G-3参照)
- サムネイル機構(`HistThumbIL`等)を定型文タブに持ち込まない
- `LauncherWatchHover`の「アクティブタブでヒットテストを限定」ガードは両タブLV化後も必須、削らないこと
- 検証には必ず「40件超の定型文でのスクロールバー動作」を含めること

## 次チャットでの着手案内

実装は別モデル・別チャットで行う。次チャットでは、まずこの`LAUNCHER-SNIPPETS-LISTVIEW-IMPLEMENTATION-HANDOFF.md`と設計書本体を読ませてからブランチを切り、上記「着手手順」の順に進めること。高さ調整(C-4)は白化解消の実機確認が取れてから、別コミットで追加する。
