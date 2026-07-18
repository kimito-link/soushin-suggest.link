# クリップボード画像履歴「体感無制限」設計

設計=Fable(claude-fable-5) / 素材集め・裏取り=司令塔Claude / 2026-07-18 / 3段構え(council-fable)の手順2の産物

前段の素材:
- 会議ハーネス(汎用会議、動的ルーティング、COUNCIL_CRITICS=2・COUNCIL_SYNTH=1、3/5成功)の収束点:
  「直近N件だけメモリに生データ/サムネイルを保持し、それ以降はディスクに圧縮PNGで退避、
  オンデマンドでロードするLRU方式」でほぼ全メンバーが一致。「上限を上げるだけ」「警告を出すだけ」は
  却下すべき安易な策と名指しされた。
- 実地調査(Explore)による地雷マップ7項目(下記G節に反映済み)。

**経緯の記録**: この設計に着手する前、司令塔ClaudeがClipImageMaxを5→100へ無審査・無設計で
書き換えてしまい、地雷調査でその事実が発覚したため5に一旦ロールバックした。本設計は
そのロールバック後、正式な3段構え(council-fable)を経て作られたものである。

---

対象: `dist/soushin-suggest.ahk`（AutoHotkey v2） / 前提資料: `_docs/CLIPBOARD-IMAGE-HISTORY-DESIGN.md`、`_docs/CLIPBOARD-HISTORY-PERSISTENT-STORE-DESIGN.md`(F-9節)

基本方針を一行で: **「メモリに置く枚数」は今のまま増やさない。増やすのは「リストに居続けられる枚数」だけ。** 直近5枚（現行`ClipImageMax`）だけが生DIBでRAMに居る「ホット窓」で、それより古い画像は生データを捨てて既存のアーカイブPNG(`clip-archive/screenshot/`)への**参照**に格下げ（demote）する。履歴リストからは消えず、サムネイルも残り、貼り付け時だけPNGを読み戻す。新しいストアは作らない。既にあるPNG保存を正本に昇格させるだけの薄い設計。

---

## A. 理想の体験フロー

1. ユーザーは1日中スクショ・画像コピーを続ける。**6枚目以降も履歴リストから何も消えない。** ランチャー・「定型文の管理」履歴タブには全画像がサムネイル付きで並び続ける（100枚でも300枚でも）。
2. 朝コピーした画像を夕方にクリックすると、そのまま貼り付けられる。直近5枚は今と同じ即時（RAM直）。それより古い画像は裏でPNGを読み戻すため一拍（体感0.1〜0.2秒程度）置いて貼られるが、ユーザーが意識する差ではない。
3. **PCは重くならない。** 画像を何百枚コピーしても、生データでRAMに居るのは常に最新5枚だけ（最悪180MB、現行と同一）。古い画像はサムネイル(1枚約9KB)と参照情報だけになる。
4. アプリ再起動後、履歴リストの画像行は消える（現行と同じ、Phase A）。ただし**PNGファイル自体は`clip-archive/screenshot/`に全部残っている**ので「消えて失った」は起きない。リストへの復元はPhase B（F節参照）。
5. ディスクは合計サイズ上限（既定4GB、0で完全無制限）で古いPNGから自動掃除され、気づかぬうちにCドライブを食い潰すことはない。掃除で消えたPNGを参照していた履歴行は静かにリストから外れる。

「無制限」の正体 = **リスト上の枚数は無制限、RAM上の生データは常に5枚、ディスクは上限付きローテーション**。ユーザーの不安（消える・失う）はディスク側の正本が解消し、ユーザーの最重要要件（PCの軽さ）はホット窓の固定が保証する。

## B. 統合アーキテクチャ（コンポーネント4つ）

```
[1] ホット窓 (メモリ側)                 [2] 画像検疫キュー (書込ゲート)
    ClipHistory 内の直近5画像            PendingImage: 捕捉47秒後に
    {type:"image", dib, w, h, ...}       SaveDibAsPng → v.pngPath 確定
        │ 6枚目が来たら                      │ コミット済みになったら
        ▼ 削除ではなく「降格」               ▼
[3] コールドストア (ディスク側)          [4] オンデマンド復元+サムネイル (UI側)
    clip-archive/screenshot/*.png        ・push時にサムネイル即時生成(9KB/枚)
    既存アーカイブをそのまま正本化        ・貼り付け時 GetImageDib(v):
    SweepImageStore が合計サイズ上限で      dibあり→即 / なし→LoadPngAsDib(pngPath)
    古い順に削除・参照行も同期除去        ・ImageList肥大時の再生成もPNG分岐
```

役割分担:
- **[1] ホット窓**: 現行`ClipImageMax=5`のwhileループ(`PushClipImage`内)の`RemoveAt`を「降格」に置換するだけ。降格 = `v.DeleteProp("dib")`して`v.pngPath`参照のみ残す。Bufferは参照が切れて自動解放（現行コメントの解放メカニズムと同一）。
- **[2] 画像検疫キュー**: 現行の「画像は検疫なし即保存」を、テキストの`QueueTextArchive`→`CommitPendingArchive`と同じ`ClipAutoClearSec+2秒`待ちに揃える。地雷#2（画像だけ検疫の外）をこの機会に解消する。パスワードマネージャ等の自動クリアが発火したら、保留中の画像も書かずに捨てる。
- **[3] コールドストア**: 新フォルダ・新形式は作らない。既存`ArchiveSubDir("screenshot")`のPNGがそのまま正本。追加するのは合計サイズ上限の掃除係(`SweepImageStore`)だけ。地雷#3（ディスク側は既に無条件・無上限）への回答でもある。
- **[4] UI側**: `v.dib`を直接触っている貼り付け・サムネイル生成の各箇所を`GetImageDib(v)`/PNG分岐ヘルパー経由に差し替える。

**前提条件**: 降格は`pngPath`がコミット済みの画像にのみ行う。つまり「体感無制限」は`archive.image=on`（v1.18.0から既定ON）のときに有効。OFFの場合は現行どおり5枚で最古削除（安全側フォールバック、挙動後退なし）。

## C. 具体機構

### 設定キー（sites.ini `[clipboard]`セクション、既存の小文字ベタ命名に合わせる）

| キー | 既定 | 意味 |
|---|---|---|
| `imagemax` | 5 | **既存キーを意味変更なしで続投**: RAMに生DIBを持つホット窓の枚数。「上限」から「ホット窓幅」へ役割名だけ変わる |
| `imagestoremaxmb` | 4096 | `clip-archive/screenshot/`の合計サイズ上限(MB)。0=完全無制限（ユーザーの「完全無制限でもいい」に応える脱出ハッチ。ただし既定は有限） |

新キーは1個だけ。`imagemaxmb`(1件36MB)・`archiveimage`等は不変。設定ウィンドウへのUI追加はMVPでは見送り（ini直編集で足りる。テキスト履歴の999999も同じ扱いだった）。

### データ形状（ClipHistory要素）

```
ホット:   {type:"image", text:label, dib:Buffer, w, h, time, thumbIdx?, pngPath?}
コールド: {type:"image", text:label,             w, h, time, thumbIdx,  pngPath}
```
判別は`v.HasOwnProp("dib")`。`pngPath`は検疫コミット時に絶対パスで確定。

### 処理の流れ

**捕捉時（`PushClipImage`改修）**
1. `InsertAt(1, {...dib...})` — 現行どおり
2. **サムネイル即時生成**: `HistThumbIndex(v)`をここで一度呼ぶ（現行は表示時遅延。降格後はdibが無く生成不能になるため、dibがあるうちに焼く。1回のGDI操作/枚、コスト増は無視できる）
3. **即時`SaveDibAsPng`を廃止**し`QueueImageArchive(v)`へ（検疫キュー投入）
4. ホット窓超過ループ: `RemoveAt(i)` → `DemoteClipImage(v)`に置換。ただし`pngPath`未コミットの画像は降格スキップ（検疫中の数十秒だけdibを余分に持つ。`ClipUserWindowMs`ガードがあるので現実には数枚・一時的）
5. 複合上限(`ClipHistoryMax`)のテキスト優先退避ループは**無改修**。コールド画像は軽量なので圧力源にならず、地雷#7の非対称ロジックと自然に整合する

**検疫コミット時（`CommitPendingArchive`拡張 or 並設の`CommitPendingImages`）**
- 47秒経過した保留画像を`SaveDibAsPng` → 成功したら`v.pngPath := path` → 直後に`DemoteOverflowImages()`を呼び直す（コミット待ちで降格保留になっていた分を処理）
- 自動クリア検知時はテキストと同じ規則で保留分を破棄
- 実装はテキスト側`PendingArchive`のパターン流用（+30〜40行想定）。**BOM前置はしない**（AHK自動付与、v1.18.1の二重BOM地雷）——PNGバイナリには無関係だが、同関数を触るとき既存テキスト側を壊さないこと

**貼り付け時**
```
GetImageDib(v) {
    if v.HasOwnProp("dib")
        return v.dib
    dib := LoadPngAsDib(v.pngPath, v.w, v.h)   ; GDI+: GdipCreateBitmapFromFile
    if !dib {                                   ; ファイル消失(手動削除/sweep後)
        Flash("画像ファイルが見つかりません", 1500)
        ; → 呼び出し側で該当行を履歴から除去してリスト再描画
    }
    return dib
}
```
`LoadPngAsDib`: `GdipCreateBitmapFromFile`→`GdipCreateHBITMAPFromBitmap`→`GetDIBits`で、`CaptureRectToDib`が返すのと同じ「BITMAPINFOHEADER+ピクセル連続」のCF_DIB Bufferに詰める（`SetClipboardImage`がそのまま食える形式）。同期実行でよい——**ユーザーのクリック起点・1回きり・数MBのPNGデコードは実測100ms級**であり、会議で警告された「同期I/Oフリーズ」はスクロール中の一括デコードを指す。スクロールはサムネイル(ImageList済み)しか触らないため発生しない。読み戻したdibは`v`に再セットしない（再セットするとホット窓計数が壊れる。使い捨てで参照切れ解放に任せる）。

**掃除（`SweepImageStore`、新設）**
- 起動時+1時間タイマー。`clip-archive/screenshot/`をLoopFilesで列挙し合計サイズ算出、`imagestoremaxmb`超過なら更新日時の古い順に削除。削除したパスを参照するコールド行は`ClipHistory`から除去
- 数百ファイルの列挙はミリ秒オーダー。非同期化は不要（過剰設計）

**ImageList肥大対策（`RebuildHistThumbILIfBloated`改修）**
- 現行の固定閾値は「画像は最大5枚」前提。**「ImageList枚数 > 生存画像行数×2+16」**に変更
- 再生成パス: `MakeHistThumb`にdib無し分岐を追加——`GdipCreateBitmapFromFile(pngPath)`→縮小→既存と同じ`ImageList_Add`。1000枚居ても再構築は稀にしか発火しない設計

## D. 偽陽性潰し

本お題は検証系ではないため省略。

## E. MVP: 「削除→降格」ひとつだけ

**最初に作るのは `PushClipImage`の`RemoveAt`→降格 + `GetImageDib`/`LoadPngAsDib` + push時サムネイル即時生成、の一組だけ**（上記C「捕捉時」1,2,4と「貼り付け時」）。検疫は現行の即時`SaveDibAsPng`のままでよい（pngPathを即コミットとして扱う）。

理由: この一組だけで「6枚目で消える」というユーザーの不満の核心が消え、RAMプロファイルは現行と厳密に同一のまま。しかも純増改修で、`archive.image=off`時は現行挙動に自動フォールバックするため**後退リスクがゼロ**。ディスク無上限(地雷#3)と検疫非対称(地雷#2)は「今日と同じ状態」を一歩も悪化させないので、次の歩に回せる。

歩幅の順序: **第1歩=MVP** → **第2歩=`SweepImageStore`+`imagestoremaxmb`**（無制限化でPNG増加ペースが上がるため優先度が上がる）→ **第3歩=画像検疫キュー**（挙動変更を伴うため単独コミットで） → **Phase B判断**（F節）。

## F. 捨てた案と理由

| 案 | 判定 | 理由 |
|---|---|---|
| `ClipImageMax`の数値を上げるだけ | **却下（再確認）** | 司令塔が一度無審査実行→ロールバック済み。100枚×36MB=3.6GB級のRAM爆発があり得る。会議全員が名指しで否定。本設計はこの数値に触らない |
| GDI+でメモリ上PNG圧縮しRAM節約 | **今回も却下** | 過去に「+100行級で見合わない」で却下済み。状況は変わっていない——ディスク退避なら圧縮コード自体が不要で、既存`SaveDibAsPng`の再利用で済む。「RAM上に圧縮して持つ」は降格方式の下位互換 |
| 画像の完全永続化（再起動後リストへ復元） | **Phase Bとして見送り継続、ただし再判断条件を明記** | 旧却下時の前提「ClipImageMax=5では便益が小さい」は本設計で崩れる（数百枚保持なら復元価値は上がる）。一方、却下のもう半分の根拠「DIB↔PNG往復・ロード・サムネイル再構築の複雑さ」は本設計の`LoadPngAsDib`・PNGサムネイル分岐が**副産物として大部分を解消する**。よって「安易に覆す」のではなく、MVP稼働後に *(a)ユーザーが再起動後の画像復元を実際に求めるか (b)復元は起動時に軽量index(1行=time,pngPath,w,h のCSV。dibは読まずコールド行として復元)で足りるか* を条件に再判断する。実装するとしても起動時に画像バイナリは一切読まない設計に限る |
| `history-store.csv`へ画像行を統合 | 却下 | テキスト専用設計(`FinishHistoryStoreLoad`)を壊すリスクに対し、画像はパス参照だけで足りるため同居の必然性がない。Phase Bをやる場合も別ファイル(`image-index.csv`)とし、既存ストアには触らない |
| 非同期I/Oワーカー / スレッド化 | 却下 | AHK v2に素直なスレッドはなく、擬似非同期(タイマー分割)は複雑さの割に、書込は既に検疫タイマー経由・読込はクリック起点1回きりで同期コストが許容範囲。会議の警告には「スクロール時はサムネイルのみ」の構造で応える |
| 警告ダイアログ(枚数が増えたら知らせる) | 却下 | 会議で「安易な策」名指し。構造で解決すべき問題に通知を貼るだけの案 |

## G. 地雷と回避策

1. **数値変更の誘惑**: 実装中も`ClipImageMax`既定値は5のまま触らない。コード内コメントに「この値はホット窓幅。上げてもリスト枚数は増えない(降格が起きるだけ)」と明記し、将来の「上げるだけ」再発を構造的に無意味化する。
2. **検疫の非対称**: MVPでは現状維持（即時PNG保存）だが、設計上の欠陥として本書に明記し第3歩で解消する。第3歩実装時、`CommitPendingArchive`を触る際は既存テキスト側のBOM地雷(v1.18.1)・`Trim`地雷（改行を明示指定）に接触しないこと。
3. **ディスク無上限**: 第2歩の`SweepImageStore`が回答。それまでの間も「今日より悪化しない」（書込レートは現行と同じ）。なお**`clip-archive`がOneDrive配下にある場合、PNG大量蓄積は同期帯域・CPUを食う**。`archivedir`キーでOneDrive外への移設を推奨事項としてLP/READMEに一行足すこと（既定パスの変更はしない——既存ユーザーのファイルが迷子になる）。
4. **旧却下判断の蒸し返し**: F節のとおり「当時の前提のどれが変わり、どれが変わらないか」を分解済み。Phase B着手はユーザーの実需確認を条件にする。
5. **圧縮案の蒸し返し**: F節で明示的に再却下。`LoadPngAsDib`はGDI+の**デコード**利用であり、却下されたのは**エンコードをRAM節約に使う案**。別物であることをコメントに書く。
6. **`history-store.csv`テキスト専用**: 本設計は同ファイルに一切触れない。`FinishHistoryStoreLoad`の画像行破棄も不変。
7. **非対称退避ロジック**: `PushClipImage`の複合上限ループは無改修で整合（B節）。改修対象は画像専用ループのみ、というdiff境界を守る。
8. **AHK固有・Bufferライフサイクル**: 降格は`DeleteProp("dib")`のみで行い、明示解放しない（参照カウント任せ。二重解放地雷）。`LoadPngAsDib`が返すBufferを`v`へ再キャッシュしない（ホット窓計数の破壊防止、C節）。GDI+ハンドルは`GdipDisposeImage`/`DeleteObject`を`SaveDibAsPng`と同じtry-finallyパターンで対にする。
9. **サムネイル生成→即再描画の白化(既知バグ)**: push時のサムネイル即時生成を追加しても、`RefreshLauncherHistory`は既存の`SetTimer(-1)`遅延のまま維持する（GDI完了待ちの意味が変わらないよう順序を崩さない。今セッションで発見・修正した白化対策と競合させない）。
10. **ドラッグ中のGUI破棄レース**（メモリ[[feedback_ahk_drag_race_condition]]）: `SweepImageStore`が履歴行を除去した直後のリスト再描画は、ランチャー表示中なら既存の再描画経路(`RefreshLauncherHistory`)経由で行い、ループ内で直接`ClipHistory`を走査しながらGUIを触らない。
11. **TEMP-VERIFY残置**: 実機確認コードはコミット前に`grep -n "TEMP-VERIFY" dist/soushin-suggest.ahk`で必ず掃除。

---

**規模感の見積もり**: MVP(第1歩)は `DemoteClipImage`+`GetImageDib`+`LoadPngAsDib`+push時サムネイル+呼び出し箇所差し替えで約120〜150行の純増。第2歩(sweep)約50行、第3歩(画像検疫)約40行。いずれもAutoHotkey v2の既存パターン(`SaveDibAsPng`/`PendingArchive`/`MakeHistThumb`)の転用で、新規のWin32領域には踏み込まない。
