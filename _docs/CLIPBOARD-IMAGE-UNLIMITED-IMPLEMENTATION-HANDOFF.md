# クリップボード画像履歴「体感無制限」実装ハンドオフ

設計書: [`CLIPBOARD-IMAGE-UNLIMITED-DESIGN.md`](CLIPBOARD-IMAGE-UNLIMITED-DESIGN.md) を先に読むこと。
このファイル単独でMVP(第1歩)に着手できる粒度でまとめる。

## スコープ(MVPのみ、第2歩・第3歩・Phase Bはやらない)

設計書E節の「第1歩」だけ。具体的には:
1. `PushClipImage`のホット窓超過ループを「削除」から「降格」に変更
2. `GetImageDib(v)` / `LoadPngAsDib(path, w, h)` の新設
3. push時のサムネイル即時生成(`HistThumbIndex(v)`をpush直後に呼ぶ)
4. 貼り付け・履歴表示など`v.dib`を直接参照している箇所を`GetImageDib(v)`経由に置き換え

`ClipImageMax`の**数値は5のまま変更しない**。第2歩(`SweepImageStore`)・第3歩(画像検疫)・Phase B(再起動後の復元)はやらない。

## 着手手順

1. ブランチを切る（例: `feature/image-history-demote`）
2. `dist/soushin-suggest.ahk`で現状の該当箇所を実測確認（設計書執筆時から行番号がずれている前提で、関数名でGrepし直すこと）:
   - `PushClipImage(dib, w, h)` — ホット窓超過ループ、`SaveDibAsPng`呼び出し箇所
   - `v.dib`を参照している全箇所（貼り付け処理・`MakeHistThumb`・`HistThumbIndex`）
3. `DemoteClipImage(v)`ヘルパーを新設: `v.DeleteProp("dib")`のみ。明示解放しない（Bufferは参照カウントで自動解放、二重解放を避ける）
4. `GetImageDib(v)`ヘルパーを新設: `v.HasOwnProp("dib")`ならそのまま返す。なければ`LoadPngAsDib`で復元し、失敗時は`Flash`でエラー表示して呼び出し元に「該当行を履歴から除去すべき」ことが伝わるよう戻り値(0など)で示す
5. `LoadPngAsDib(path, w, h)`を新設: GDI+の`GdipCreateBitmapFromFile`→`GetDIBits`で、`CaptureRectToDib`が返すのと同じCF_DIB形式のBufferを組み立てる。GDI+ハンドルは`SaveDibAsPng`と同じtry-finallyパターンで確実に解放する
6. `PushClipImage`の画像専用whileループ（`RemoveAt`している箇所）を、`pngPath`がコミット済みの画像に限り`DemoteClipImage`に置き換える。未コミット(検疫中)の画像は据え置き
7. `PushClipImage`内でpush直後に`HistThumbIndex(v)`を呼び、サムネイルを即時生成する
8. `v.dib`を直接参照している貼り付け・表示箇所を`GetImageDib(v)`経由に差し替える
9. 実機ビルド＆手動確認（下記チェックリスト）

## 機械的な完了判定

- [ ] `ClipImageMax`は5のまま(コードに変更なし、または明示コメント付きで維持)
- [ ] 6枚目の画像をコピーしても履歴リストの行数が減らない（5枚→6枚に増える、消えない）
- [ ] 6枚目コピー後、1〜5枚目のいずれか（降格された画像）をクリックして貼り付けると、正しい画像が貼られる
- [ ] 降格された画像のサムネイルが履歴リストに正しく表示される（白紙・壊れたアイコンにならない）
- [ ] `archive.image=off`設定時は現行どおり5枚で最古削除される（フォールバック確認）
- [ ] `grep -n "TEMP-VERIFY" dist/soushin-suggest.ahk`でデバッグコード残置なし
- [ ] 大量（20枚程度）連続スクショ後もPCの動作が重くならない（体感確認）
- [ ] アプリ再起動後、画像履歴は現行どおり消える（Phase A範囲、想定どおりの後退なし確認）

## 地雷（設計書G節から特に着手時に注意すべきもの抜粋）

- `ClipImageMax`の数値を上げたい誘惑に負けない。上げてもリスト枚数は変わらない設計であることをコード側にもコメントで明記する
- push時のサムネイル即時生成を追加しても、`RefreshLauncherHistory`の`SetTimer(-1)`遅延は崩さない（今セッションで直したランチャー白化バグと競合させないため）
- `GetImageDib`が返したBufferを`v`へ再キャッシュしない（ホット窓の計数が壊れる）
- GDI+ハンドルの解放漏れに注意（`SaveDibAsPng`の確保・解放パターンを踏襲する）

## 次チャットでの着手案内

実装は別モデル・別チャットで行う。次チャットでは、まずこの`CLIPBOARD-IMAGE-UNLIMITED-IMPLEMENTATION-HANDOFF.md`と設計書本体を読ませてからブランチを切り、上記「着手手順」の順に進めること。
