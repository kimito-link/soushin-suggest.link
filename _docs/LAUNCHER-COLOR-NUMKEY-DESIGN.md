# 設計書: クイックペーストの色付け・数字キーショートカット

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 実測388行)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・5/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-15 ／ 対象ブランチ: feature/launcher-tabs-snippets
> 前提: [`LAUNCHER-TABS-SNIPPETS-DESIGN.md`](LAUNCHER-TABS-SNIPPETS-DESIGN.md)（実装済み）の拡張

## 裏取りメモ（司令塔による検証）

Fableが引用した行番号（グローバル宣言L26、XButton1:L236、LoadSnippets:L253、
ShowLauncher:L273、PasteHistoryItem:L312、UseSnippetItem:L322、PasteText:L341、
CheckLauncherFocus:L350、CloseLauncher:L360、LoadSitesConfig呼び出し:L370）はすべて
実ファイルと完全一致。ファイル総行数388行も実測と一致。設計の中核判断（ホットキーの
常設登録+HotIfスコープ限定による残留バグの構造的排除、ListBox据え置きでの色付け）は
いずれも実装的に妥当と判断。

## 会議での重要な指摘

gpt-oss-120bが会議で指摘した致命的リスク: 「ポップアップ表示中だけ数字キーを捕捉する」
という設計を素朴に実装すると、AutoHotkeyの`Hotkey`はグローバルスコープで動作するため、
ポップアップがフォーカスを失った瞬間（UACダイアログ・ゲームのフルスクリーン等）に
ホットキーが解除されず、他アプリの数字キー入力を乗っ取ってしまう致命的バグになりうる。
この指摘はFableの設計に完全に反映されている（B節参照）。

## 結論の要約

| 論点 | 結論 |
|---|---|
| 要望B（数字キー即選択） | **採用**。グローバル`Hotkey`＋フラグ判定は禁止。**起動時に一度だけ、`HotIf`（ウィンドウアクティブ判定のスコープ限定）付きで登録**し、有効/無効のライフサイクル管理そのものを設計から排除する |
| 要望A（色付け） | **採用（最小形）**。ListView置き換えは却下。既存ListBoxの**タブ別背景色**＋**数字プレフィックス**＋既存`▶`の3点で視覚分離する |
| 数字キー割り当て | 1〜9＋**0=10番目**（Clibor慣習に倣う）。上限10は`ClipHistoryMax`と一致 |
| 規模 | 388行 → **約398行**。**400行防衛線内に収まる** |

---

## A. 理想の体験フロー

1. 対応アプリでサイドボタン長押し（0.35秒）→ カーソル位置にポップアップ（既存のまま）
2. リストの各行の先頭に **`1`〜`9`、10件目は `0`** の番号が付いている。履歴タブは**淡い青**、定型文タブは**淡いクリーム色**の背景で、「いまどちらの手札を見ているか」が一瞥でわかる
3. 目当ての行の番号キーを**1回押す** → 即座にペースト（`run:`行なら起動）してポップアップが閉じる。マウスで行をクリックする従来動作もそのまま生きている
4. ポップアップがフォーカスを失えば従来どおり150msで自動クローズし、**その瞬間から数字キーは完全に普通のキーに戻る**（他アプリへの乗っ取りゼロ）

ブランド軸との整合: 数字キーは「単発キー1回」であり、既存の右クリック長押し送信と同じ「タイピング（連続文字入力・検索）ではない補助操作」。検索ボックスは今回も一切導入しない。マウスだけでも全操作が完結する（数字キーは省略可能なショートカット）。

## B. 要望B（数字キー）の結論と安全な実装方針

**採用。実装方式は「常設登録＋`HotIf`スコープ限定」の一択とする。**

会議指摘の残留リスクの本質は「有効化/無効化というライフサイクルを持つと、無効化が走らない経路（フォーカス喪失、例外、UACによる中断）が必ず残る」こと。よって**ライフサイクル自体を持たない**設計にする:

- 数字キー`1`〜`0`のホットキーは**スクリプト起動時に一度だけ**、`HotIf`条件付きで登録する。`ShowLauncher`/`CloseLauncher`では**一切登録・解除・Suspend操作をしない**
- `HotIf`条件は `IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)`。AutoHotkeyはこの条件を**キー押下のたびに評価**し、条件が偽ならキーは捕捉されず**ネイティブにパススルー**される
- 二重ガード構造:
  - **第1ガード（状態）**: `CloseLauncher`が`LauncherGui := 0`にした瞬間、`IsObject`が偽 → 不発。既存のEsc・項目選択・フォーカス喪失タイマーの全クローズ経路がここを通る（既存コードL360-367、変更不要）
  - **第2ガード（フォーカス）**: 万一GUIオブジェクトが生きていても、UACダイアログ・フルスクリーンゲーム・セキュリティソフトのポップアップ等でランチャーが前面でなくなれば`WinActive`が偽 → 不発。つまり**「GUIは存在するがフォーカスがない」150msの隙間ですら乗っ取りは起きない**
- 条件式は`IsObject`が先（短絡評価）なので、ランチャー非表示時の全システムの数字キー押下コストは実質ゼロ

修飾キー付き（Shift+1等）は登録しないので影響なし。数字キーの`ClipHistoryMax`超過分（該当項目なし）は無音の無効打とし、ポップアップは開いたまま。

## C. 要望A（色付け）の結論と実装方針

**ListBox据え置き＋3点セットで採用。ListView全面置き換えは却下。**

1. **タブ別背景色**: 履歴タブのListBoxに`BackgroundF0F6FF`（淡青）、定型文タブに`BackgroundFFF9E6`（淡クリーム）。`Gui.Add`のオプション文字列に足すだけで**追加行数0**。「コピーした物＝クール系／自分で仕込んだ物＝ウォーム系」という色のメンタルモデルを与える
2. **数字プレフィックス**: `1 〜` `0 〜` を各行頭に付与（要望Bのキー割り当ての可視化を兼ねる。既存Push行の修正のみで追加0行）。定型文の11件目以降は番号なし（クリックのみ）
3. **既存`▶`プレフィックス**: `run:`行の区別は現状のまま

項目単位の色分けはWin32 ListBoxの構造的制約（オーナードロー必須）により、400行防衛線内では原理的に不可能。上記3点で「色による識別」の実用価値の大半（タブの取り違え防止・番号との対応付け）は満たせると判断した。

## D. 具体機構（既存実装との差分）

差分は5ブロック。すべて `dist/soushin-suggest.ahk`（行番号は現ファイル実測・裏取り済み。実装時は`grep -n`で再特定すること）。

**(1) グローバル宣言の統合＋`LauncherTab`追加（L26-28相当、3行→1行で2行回収）**

```autohotkey
; 変更前
global LauncherGui := 0
global LauncherTarget := 0
global Snippets := []
; 変更後（1行）
global LauncherGui := 0, LauncherTarget := 0, LauncherTab := 0, Snippets := []
```

**(2) ShowLauncher の修正（既存の`ShowLauncher`関数全体、行数増減なし・既存行の書き換えのみ）**

```autohotkey
    global ClipHistory, LauncherGui, LauncherTarget, Snippets, LauncherTab   ; LauncherTab追加
    ...
    LauncherTab := LauncherGui.Add("Tab3", "w460 -Wrap",                     ; tab→LauncherTabにリネーム
        ["履歴 " . ClipHistory.Length, "定型文 " . Snippets.Length])
    rows := Min(Max(ClipHistory.Length, Snippets.Length, 3), 10)
    LauncherTab.UseTab(1)
    histItems := []
    for v in ClipHistory {
        s := RegExReplace(v, "\s+", " ")
        histItems.Push(Mod(A_Index, 10) . " " . (StrLen(s) > 58 ? SubStr(s, 1, 58) . "…" : s))  ; 番号付与・58字に短縮
    }
    lbH := LauncherGui.Add("ListBox", "w440 r" . rows . " BackgroundF0F6FF", histItems)          ; 淡青
    lbH.OnEvent("Change", (lb, *) => PasteHistoryAt(lb.Value))
    LauncherTab.UseTab(2)
    snipItems := []
    for i, s in Snippets                                                     ; インデックス付きfor
        snipItems.Push((i <= 10 ? Mod(i, 10) . " " : "   ") . (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . s.label)
    lbS := LauncherGui.Add("ListBox", "w440 r" . rows . " BackgroundFFF9E6", snipItems)          ; 淡クリーム
    lbS.OnEvent("Change", (lb, *) => UseSnippetAt(lb.Value))
    LauncherTab.UseTab()
    if (ClipHistory.Length = 0)
        LauncherTab.Value := 2
```

**(3) ペースト関数をインデックス引数化（既存の`PasteHistoryItem`/`UseSnippetItem`、各-1行。クリックと数字キーの共通入口にする）**

```autohotkey
PasteHistoryAt(idx) {
    global ClipHistory
    if (idx < 1 || idx > ClipHistory.Length)   ; 数字キーの空振りガード（上限チェック追加）
        return
    text := ClipHistory[idx]
    CloseLauncher()
    PasteText(text)
}

UseSnippetAt(idx) {
    global Snippets
    if (idx < 1 || idx > Snippets.Length)
        return
    s := Snippets[idx]
    CloseLauncher()
    ; …以下、既存のrun:分岐/PasteText(s.value)は無変更…
}
```

**(4) 数字キーの常設登録（「起動時」セクション、`LoadSitesConfig()`呼び出し(L370)の直後に4行）**

```autohotkey
; 数字キー1-9,0=10: ランチャーがアクティブな間だけ有効（HotIfスコープ限定・解除処理は不要）
HotIf (*) => IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)
Loop 10
    Hotkey Mod(A_Index, 10) . "", LauncherPickKey
HotIf
```

`#HotIf`ディレクティブ（静的）ではなく`HotIf`関数（動的登録のコンテキスト指定）を使う。ループで10キーを4行に畳むため。末尾の`HotIf`（条件リセット）は省略禁止。

**(5) ディスパッチ関数（`CloseLauncher`の直後に7行＋空行）**

```autohotkey
LauncherPickKey(hk, *) {
    n := (hk = "0") ? 10 : Integer(hk)
    if (LauncherTab.Value = 1)
        PasteHistoryAt(n)
    else
        UseSnippetAt(n)
}
```

`LauncherTab`・グローバル読み取りのみなので`global`宣言不要（v2は読み取りassume-global）。ホットキーは`HotIf`条件が真＝ランチャー表示中しか着火しないため、`LauncherTab`が未初期化(0)のまま呼ばれる経路は存在しない。

**行数収支**: 388 −2(グローバル統合) −2(関数の引数化) +4(登録ブロック) +8(関数+空行+コメント) ＝ **約398行。400行防衛線内**。万一実装時に2〜3行はみ出た場合の削りしろは(4)のコメント1行と(5)前後の空行（機能に影響なし）。それでも超えるなら数字キー機能を削るのではなく空行・コメントの整理で吸収すること（機能スコープはこれ以上削れないほど既に最小）。

## E. MVP（今すぐやるなら最小の一手）

1. **(1)+(2)のみ**（色付け＋番号表示）。ホットキーなしでも「番号が見える・色で区別できる」だけで要望Aは完了。ここまでは既存行の書き換えだけで**追加行数マイナス**
2. **(3)+(4)+(5)**（数字キー実働）。要望B完了
3. `scripts/build.ps1` でビルド（Git BashからAhk2Exe直叩き厳禁。今回iniの追加はないのでzip同梱リストの変更は不要）→ reality-checker に動作判定を委任（検証観点はGの表）

## F. 捨てた案と理由

- **ListView＋`NM_CUSTOMDRAW`による項目単位の色分け**: 却下。60〜100行増で400行防衛線を確実に突破。イベント処理も`Change`から`ItemSelect`系に総取り替えになり回帰リスク大
- **グローバル`Hotkey`登録＋「ランチャー表示中」フラグ判定**: 却下。会議で特定された残留バグの温床そのもの。フラグ方式はキーを**捕捉してから**捨てるため、判定を誤ると他アプリの数字入力を食う
- **`ShowLauncher`でHotkey On／`CloseLauncher`でHotkey Off の動的ライフサイクル**: 却下。Offが走らない経路（例外・強制クローズ・タイマー競合）が構造的に残る。常設登録＋`HotIf`なら「解除し忘れ」という概念自体が存在しない
- **静的`#HotIf`ディレクティブで`1::`〜`0::`を10行並べる**: 却下。ループ登録と等価で6行損。ただし挙動は同じなので、実装者がデバッグしやすさで選び直すのは可（その場合の行数超過は自己責任で別の削りしろを確保）
- **Numpad1〜0の追加対応**: 見送り。`Loop`内に1行足せば済むが、行数が惜しい。要望が出たら+1行で追加可能とだけ記録
- **タブ切替イベントでGUI全体の背景色を変える**: 却下。`Tab3`のChangeイベント購読が増える割に、ListBox背景色で識別目的は達成済み
- **絵文字による履歴項目の内容分類（URL/パス/テキスト等）**: 却下。分類ヒューリスティクスの外れが認知負荷になる（想起機能を却下したのと同じ理屈）
- **0キーを未割り当てにする案**: 却下。Clibor経験者の指が「0=10番目」を覚えており、履歴上限10とも綺麗に対応する

## G. 地雷と回避策

1. **【最重要】ホットキー残留の検証を必ず行う**。実装後の必須テスト:
   - (a) ランチャー表示中にAlt+Tabで他窓へ → 150ms以内に自動クローズ → メモ帳で`1`〜`0`を打鍵 → **全て普通に数字が入力される**こと
   - (b) Esc・項目クリック・数字キー実行、の各クローズ経路の直後にも同じ打鍵確認
   - (c) ランチャー表示中に他アプリが前面を奪った**直後の150ms未満**（タイマー発火前）に数字キー → 乗っ取られない（`WinActive`ガードの確認。手動では難しいので、`CheckLauncherFocus`のタイマーを一時的に5000msにして再現するとよい。**テスト後必ず150に戻す**）
2. **`HotIf`の条件式は`IsObject(...)`を必ず左に書く**（短絡評価）。順序を逆にすると`LauncherGui=0`のとき`.Hwnd`アクセスで毎打鍵エラーになる
3. **数字キー登録ブロックの末尾`HotIf`（引数なし＝条件リセット）を消さない**。消すと以後に追加される動的ホットキーが全部ランチャースコープに巻き込まれる
4. **`CloseLauncher`の`LauncherGui := 0`に触らない**。これが第1ガードの実体。`Destroy()`だけして0代入を忘れる改変は残留バグの復活を意味する
5. **数字プレフィックスと`Change`イベント**: ListBoxは行頭文字のインクリメンタル検索を持つが、`1`〜`0`はホットキーが**制御より先に**捕捉・抑止するので誤ジャンプは起きない。ただしIME ON状態での打鍵をテスト観点に含めること（ListBoxはテキスト入力を受けないためIMEは介在しない見込みだが、実機確認）
6. **`Background`オプションが効かない環境があった場合**のフォールバックは`lbH.Opt("BackgroundF0F6FF")`を`Add`直後に置く（+2行。この場合の行数超過は空行削減で吸収）
7. **既存構造の不可侵領域**: XButton1ハンドラの許可リストゲート、`Tab3`構成、`LoadSnippets`、`CheckLauncherFocus`/`CloseLauncher`の`Show→WinActivate→SetTimer`順序は一切変更しない。今回の差分はこれらに1行も触れない設計になっている
8. **ビルドは必ず`scripts/build.ps1`**（Git BashからAhk2Exe直叩き厳禁・既知の地雷）。今回は同梱ini・zipリストの変更なし、exe再ビルドのみ
9. **回帰確認**: 許可リスト外でXButton1短押し→即スクショ／クリック選択でのペースト／`run:`起動／`\n`改行展開、の既存4系統が無傷であること（数字キーはあくまで**追加の入口**で、クリック経路と同じ`PasteHistoryAt`/`UseSnippetAt`に合流する設計のため、共通部の回帰はクリック側テストで兼ねられる）
10. **規模**: 今回で約398行。400行防衛線は維持。次に何かを足す要望（Numpad対応・タブ色連動・項目色分けの再燃を含む）が来たら実装せず、次の機能会議に差し戻すこと
