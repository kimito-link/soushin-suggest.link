# ランチャー「定型文」タブ ListView化 設計書

設計=Fable(claude-fable-5) / 素材集め・裏取り=司令塔Claude / 2026-07-18 / 3段構え(council-fable)の手順2の産物

前段の素材:
- 会議ハーネス(汎用会議、動的ルーティング、COUNCIL_CRITICS=2・COUNCIL_SYNTH=1、3/5成功)の収束点:
  「定型文タブをListBoxからListView(Reportモード・1列・ヘッダなし)に置き換える」が最有力案。
  ListViewは`LVS_EX_DOUBLEBUFFER`によりダブルバッファリングが自動で効き、白化とスクロールバー破壊の
  両方を同時に解消できる。既に履歴タブで実績があるため実装コストも低い(見積もり1〜1.5人日)。
- 実地調査(Explore)による地雷マップ7項目(下記G節に反映済み)。

対象: `dist/soushin-suggest.ahk` ランチャーGUI 定型文タブ(現 `LauncherLbS` = ListBox)
方針: **履歴タブ(`LauncherLvH`)で実証済みのListView実装を最大限流用し、新規機構をゼロにする**

---

## A. 理想の体験フロー

ユーザーから見た変化は3点、いずれも「履歴タブと同じになる」に集約される。

1. **白化しない**: サイドボタンでスクショを撮った直後に定型文タブを見ても、リストが白く抜けない。ListView(`SysListView32`)の `LVS_EX_DOUBLEBUFFER` によりバックバッファ経由で一括描画されるため、`FlashScreenRect` のAlwaysOnTopウィンドウとZ-orderが競合しても再描画が欠落しない(履歴タブで実証済み)。
2. **表示エリアが履歴タブと同じ高さになる**: 現在は「ListBoxへの事後 `Move()` がスクロールバーを壊す」ため固定 `r10` のままで、履歴タブより短くロゴとの間に数pxの隙間がある。ListViewは `Move()` 後もスクロールバーが正しく再計算される(履歴タブで実証済み)ため、同じ高さ調整ロジックに乗れる。定型文は行アイコンが無くテキスト行高のため、**同じ高さの中により多くの行が見える**(体験としては純増)。
3. **操作は一切変わらない**: クリック即ペースト、1〜9,0の数字キーで先頭10件選択、検索ボックスでの絞り込み、ホバーで全文ツールチップ、`run:` 定型文の「▶ 」表示 — すべて現状維持。見た目の差分は「選択行のハイライトがListView様式になる」程度。

---

## B. 統合アーキテクチャ

**置き換えの全体像**: 定型文タブのコントロールをListBoxからListView(Reportモード・1列・ヘッダなし)へ差し替え、周辺関数を「履歴タブが既に使っているLV版ヘルパー」へ付け替える。データ層(`Snippets` / `LoadSnippets` / `UseSnippetAt` / `ResolveSnipRow` / `LauncherSnipFilterMap`)は**一切変更しない**。

```
[変わらない層]
  Snippets(グローバル) ── LoadSnippets() ── snippets.ini
  ResolveSnipRow() / LauncherSnipFilterMap / UseSnippetAt() / LauncherPickKey()

[置き換える層]                      現在                → 変更後
  コントロール                      ListBox(LauncherLbS) → ListView(LauncherLvS)
  充填関数                          FillLauncherSnippetsLB → FillLauncherSnippetsLV(中身ほぼ同一)
  選択イベント                      OnEvent("Change")    → OnEvent("ItemSelect") ※LauncherHistSelectと同型
  ホバーのヒットテスト              LauncherItemUnderMouse(LB専用) → LauncherLVItemUnderMouse(既存・共用)
  高さ調整                          なし(r10固定)        → LauncherLvH と同じ Move(,,,listH)

[削除される層]
  LauncherItemUnderMouse()          ── LB専用ヒットテスト(LB_GETITEMHEIGHT/LB_GETTOPINDEX)。呼び元が消えるため削除
```

履歴タブとの**意図的な非対称**(そのまま残す):
- ImageList(`HistThumbIL`)・`+0x40`(LVS_SHAREIMAGELISTS)・`RebuildHistThumbILIfBloated` は**持ち込まない**(地雷4)
- `DisplayMax := 500` の表示打ち切りは**持ち込まない**(地雷3、判断はG-3参照)
- `RefreshLauncherHistory` のSetTimer(-1)遅延は**持ち込まない**(地雷5)

---

## C. 具体機構

### C-1. コントロール生成(`ShowLauncher` 内、現行1287〜1295行付近)

```autohotkey
LauncherTab.UseTab(2)
; 定型文タブ: ListView化(1列・ヘッダなし)。履歴タブ(LauncherLvH)と同構成だが、
; 定型文にサムネイルは元々無いためImageList/+0x40(LVS_SHAREIMAGELISTS)は付けない。
; ListBox時代の経緯: 事後Move()でスクロールバー計算が壊れる実機不具合(2026-07-18)が
; あり高さをr指定固定にしていた。ListViewはMove()後も正常なため高さ調整を復活できる。
LauncherLvS := LauncherGui.Add("ListView"
    , "w440 r" . rows . " -Hdr -Multi NoSort BackgroundF0F6FF", ["定型文"])
LauncherLvS.Opt("+LV0x10000")             ; LVS_EX_DOUBLEBUFFER: 白化(Z-order競合の再描画欠落)対策の本丸
LauncherLvS.ModifyCol(1, 416)             ; 440 - スクロールバー/枠ぶん(履歴タブと同値)
FillLauncherSnippetsLV(LauncherLvS)
LauncherLvS.OnEvent("ItemSelect", LauncherSnipSelect)
```

流用元: 1279〜1286行の `LauncherLvH` 生成コードそのまま。差分は「`+0x40` なし・`SetImageList` なし・`RebuildHistThumbILIfBloated` 呼び出しなし」の3引き算のみ。

グローバル宣言(40行)・`ShowLauncher` 冒頭の `global`(1243行)・`LauncherTabChanged`(1234行付近)・`LauncherFilterChanged`(1211行付近)・`LauncherWatchHover`(2587行)の `LauncherLbS` 参照を `LauncherLvS` に置換。**旧名を残すエイリアスは作らない**(正本1つの原則)。

### C-2. 充填関数 `FillLauncherSnippetsLV`(現 `FillLauncherSnippetsLB`、2704行の改修)

```autohotkey
; ShowLauncherのLV初期化とLauncherFilterChangedで共用。ラベル/本文どちらかに部分一致すれば残す。
; ClipHistory側のFillLauncherHistoryLVと同じ「表示行→実インデックス」マップ方式。
; 履歴側と違い表示打ち切り(DisplayMax)は設けない: 定型文はユーザーがsnippets.iniを手動管理する
; 有限リストで、履歴のように無際限に増えない(意図的な非対称。詳細は設計書G-3)。
FillLauncherSnippetsLV(lv, query := "") {
    global Snippets, LauncherSnipFilterMap
    LauncherSnipFilterMap := []
    lv.Opt("-Redraw")
    lv.Delete()
    for i, s in Snippets {
        if (query != "" && !InStr(s.label, query) && !InStr(s.value, query))
            continue
        LauncherSnipFilterMap.Push(i)
        dispRow := LauncherSnipFilterMap.Length
        lv.Add(, (dispRow <= 10 ? Mod(dispRow, 10) . " " : "   ") . (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . s.label)
    }
    lv.Opt("+Redraw")
}
```

- 行テキストの組み立て式(数字キーラベル `Mod(dispRow, 10)`・`run:` の▶印)は**現行2713行を一字も変えず移植**(地雷6)。
- `LauncherSnipFilterMap` の積み方も現行のまま(地雷7: 履歴の `LauncherHistFilterMap` と既に同型なので、LV化で変更不要)。
- `lv.Add(, txt)` の第1引数(オプション)は空。ImageListを付けていないLVでは `Icon0` 明示は不要(「Icon0省略不可」の既知の仕様はImageList装着時のみ発症)。
- `-Redraw`/`+Redraw` 括りは `FillLauncherHistoryLV`(2732/2747行)の踏襲。

### C-3. 選択イベント `LauncherSnipSelect`(新設、`LauncherHistSelect` 1379行の写し)

```autohotkey
; クリック(選択)→即使用。旧ListBox Changeイベントの後継(定型文タブのListView化に伴う)。
LauncherSnipSelect(lv, row, selected) {
    if (!selected || GetKeyState("RButton", "P"))   ; 選択解除時と、右クリック由来の選択では発火させない
        return
    UseSnippetAt(ResolveSnipRow(row))
}
```

ListBoxの `Change` はコールバックに `lb.Value` を読ませていたが、LVの `ItemSelect` は行番号が引数で来るためラムダをやめ名前付き関数にする(履歴タブと完全対称)。`RButton` ガードも履歴タブで実証済みの挙動をそのまま持ってくる。

### C-4. 高さ調整(1300〜1311行の改修)

```autohotkey
if (ih := LauncherLVItemHeight(LauncherLvH)) {
    listH := ih * rows + 6
    LauncherLvH.GetPos(&lvX, &lvY, , &lvH0)
    LauncherLvH.Move(, , , listH)
    LauncherLvS.Move(, , , listH)   ; ListViewはListBoxと違いMove()後もスクロールバー計算が正常(履歴タブで実証済み)
    LauncherTab.GetPos(&tX, &tY, , &tH0)
    LauncherTab.Move(, , , tH0 + (listH - lvH0))
}
```

- 基準行高は従来どおり**履歴LVのアイコン行高**(`LauncherLVItemHeight(LauncherLvH)`、約36px)。両リストを同じ `listH` に揃えることで、フッター(ロゴ)配置の `footerY := Max(lvY + lvH1, lbY + lbH1)` が実質同値になり、**定型文タブの「数px残余の隙間」が消える**。`Max()` 自体は防御として残してよい(コスト0)。
- 「ListBoxは高さが行の整数倍に丸められAutoHotkey側から回避不可」の長文コメントは、前提が消えるため削除し、C-1のコメントに経緯を1行残す。
- `ClipHistory` が0件で履歴LVが空 → `LauncherLVItemHeight` が0 → Move全体をスキップ、は現行と同じfail-closed(定型文LVも `r` 指定高のままになるだけで壊れない)。

### C-5. ホバーツールチップ(`LauncherWatchHover` 2597行の1行差し替え)

```autohotkey
        if (idx := ResolveSnipRow(LauncherLVItemUnderMouse(LauncherLvS))) && idx <= Snippets.Length
```

既存の `LauncherLVItemUnderMouse`(2566行、`LVM_HITTEST`)を共用。これに伴い **`LauncherItemUnderMouse`(2555〜2563行、LB専用)は呼び元ゼロになるため削除**。

### C-6. 変更なしで動く箇所(確認のみ)

- `LauncherPickKey`(2773行): `UseSnippetAt(ResolveSnipRow(n))` — 表示行番号ベースなので無改修。
- `LauncherFilterChanged` / `LauncherTabChanged`: 呼ぶ関数名の置換のみ。
- `LauncherContextMenu`(2607行): 現行も `ctrl = LauncherLvH` のみ処理で定型文には右クリックメニューが無い。**今回スコープ外**(追加しない=過剰設計の戒め)。
- `RefreshLauncherHistory`: 履歴専用。無関係(地雷5)。

### C-7. ドキュメント更新(地雷1)

`_docs/LAUNCHER-HISTORY-THUMBNAIL-DESIGN.md` の `LauncherLbS.Move(, , , listH)` 記述に追記(または本設計書を `_docs/` に置き相互参照):
「ListBoxへの事後Move()は40件超でスクロールバーが機能しなくなる実機不具合により却下(2026-07-18)→ 定型文タブ自体をListView化して解消(本設計)」。コード内コメントだけに残っていた却下経緯をドキュメント側の正本に反映する。

---

## D. 偽陽性潰しの具体ロジック

該当なし(検証系機能ではないため省略)。

---

## E. MVP

**最初の1コミットは「C-1 + C-2 + C-3 + 参照置換」だけ**(高さ調整C-4・ホバーC-5は次コミット)。

理由: この最小差分の時点で、
- 白化問題(問題1)は `LVS_EX_DOUBLEBUFFER` により解消するはず → **サイドボタンスクショ→定型文タブ白化の再現手順で単独検証できる**
- スクロールは `r10` 相当のまま既存どおり動く → デグレ検証が「数字キー・クリック・検索絞り込み・41件以上でのスクロール」に絞れる

白化解消が実機確認できてから C-4(高さ揃え=問題2)を載せる。C-4は3行の追加なので、問題を切り分けたコミット順にする価値の方が高い。

---

## F. 捨てた案と理由

| 案 | 見積 | 捨てた理由 |
|---|---|---|
| **Owner-drawでListBoxを自前ダブルバッファ描画** | 2〜3日 | `WM_DRAWITEM` をAHK v2から捌く新規コードが丸ごと増え、フォント・選択色・DPIを全部自前再現することになる。保守性が低く、白化は直ってもMove()スクロールバー破壊(問題2)は別途未解決のまま。「既存資産を作り直さず薄く束ねる」原則に真っ向から反する |
| **WM_SETREDRAW制御のみで白化を抑える** | 0.5日 | 再描画タイミングの症状緩和にしかならず(欠落の根因のZ-order競合時のWM_ERASEBKGND挙動は残る)、問題2は完全に手つかず。2つの問題に対し0.5個しか解決しない |
| **ListBoxのスタイルフラグ再調整で延命** | — | **検討自体を禁止**(地雷2)。`0x200→0x100` 修正の再挑戦で「フラグが正しくてもMove()でスクロールバーが壊れる」ことが実機で確定済み。これはListBoxコントロール自体の限界であり、3度目の同種期待は踏まない |
| **ListView化(採用)** | 1〜1.5人日 | 履歴タブで**同一プロセス・同一GUI内で既に動いている実装**の引き算コピー。新規Win32知識ゼロ、2つの問題を1つの変更で同時解消。削除できるコード(LB専用ヒットテスト、ListBox丸め対策の長文コメント)もあり、正味の複雑度は減る |

---

## G. 地雷と回避策

1. **Move()却下の経緯がコードコメントにしか無い** → C-7でドキュメント正本に反映。C-1のコード側コメントにも「ListBox時代にMove()が却下された経緯とListViewでは問題ない根拠(履歴タブ実証)」を1行残し、将来「なぜLBに戻さないのか」が追える状態にする。
2. **フラグ調整での延命は提案禁止** → 本設計はListBoxを完全撤去する。レビュー時チェック項目:「`LauncherLbS` / `SysListBox32` / `0x100` / `LBS_` への参照が差分後に残っていないこと」(`+0x100` はDragBarのSS_NOTIFY用途が別にあるため、リスト行のみ確認)。
3. **定型文に件数上限は導入しない(明示判断)** → `DisplayMax` 相当は**不要**。根拠: (a) snippets.iniはユーザー手動管理の有限リスト、(b) LV充填は `-Redraw` 括りで軽量、(c) 数百件を超える運用が現れたらその時に履歴と同じ既存パターンを1行足すだけで済む(YAGNI)。C-2のコメントに「意図的な非対称」と明記し、将来「履歴にはあるのに無い」を不具合と誤認されるのを防ぐ。
4. **サムネイル機構を持ち込まない** → `EnsureHistThumbIL` / `SetImageList` / `+0x40` / `RebuildHistThumbILIfBloated` は定型文LVに一切触れさせない。ImageList未装着なら `+0x40` は不要かつ、`Icon0` 明示問題(既知の仕様)も発症しない。旧コメント「ランチャーのListBoxは非対応」は「定型文はテキストのみ(ImageList非装着)」に書き換える。
5. **SetTimer(-1)遅延を持ち込まない** → `FillLauncherSnippetsLV` はGDI操作を伴わない純テキスト充填なので、`RefreshLauncherHistory` の遅延機構は複製しない。定型文の再充填契機は現行どおり「ランチャー表示時・検索文字変更時・タブ切替時」の3つのみ。
6. **数字キーショートカット(1〜9,0)を壊さない** → 番号ラベルの組み立て式(`Mod(dispRow,10)`)を無変更で移植し(C-2)、`LauncherPickKey` → `ResolveSnipRow` の経路は無改修(C-6)。検証手順: 定型文11件以上+検索絞り込み中の状態で、1キー=絞り込み後1件目・0キー=絞り込み後10件目が正しく実行されること。11件目以降が番号なし表示であること。
7. **検索フィルタのマッピングを壊さない** → `LauncherSnipFilterMap` の積み方・`ResolveSnipRow` の「空マップ=1:1素通し」規約は現行のまま(元々 `LauncherHistFilterMap` と同型設計だったため、LV化での追加作業なし)。検証手順: 検索語入力→クリック選択・数字キー・ホバーツールチップの3経路すべてが絞り込み後の正しい実体(`Snippets[i]`)を指すこと。特にホバーはC-5でヒットテスト関数が変わるため重点確認。

**追加の実装時注意**(地雷マップ外、コード実測で判明):
- `LauncherWatchHover`(2591行)の「アクティブタブでヒットテストを限定」ガード(`LauncherTab.Value` 分岐)は、両タブがLV化しても**必須のまま**(Tab3は非アクティブタブの子も実体保持するため)。削らないこと。
- 検証には「40件超の定型文でのスクロールバー動作」を必ず含める(これがListBox却下の決定打だった実機事象のため、同条件での回帰確認が受け入れ基準)。
