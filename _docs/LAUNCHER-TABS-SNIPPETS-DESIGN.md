# 設計書: クイックペースト機能の拡張（タブUI・定型文・お気に入り起動）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 326行)を実地調査した上で設計
> / 素材収集=会議ハーネス(汎用会議、5体召集・5/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-15 ／ council-fable 3段構えワークフローの手順2〜3の産物
> 前提: [`QUICK-PASTE-LAUNCHER-DESIGN.md`](QUICK-PASTE-LAUNCHER-DESIGN.md)（実装済み・実機確認済み）の拡張

## 背景

既に実装・実機確認済みのクイックペースト機能（XButton1長押しでクリップボード履歴を
ポップアップ表示）に対し、ユーザーから2つの要望が出た。

- 要望1: Cliborのような「クリップボード履歴」タブと「定型文」タブを分けた、見やすいUI
- 要望2: Spotlight/PowerToys Runのような「PC内のファイル・アプリ検索、.exe起動」機能

要望2は、実は前回のcouncil-fable設計セッションで一度「不採用」と明確に判断していた領域。
今回改めて会議にかけ、この判断を維持するか再検討した。

## 裏取りメモ（司令塔による検証）

Fableが引用した行番号（XButton1:L235, ShowLauncher:L249, PasteFromLauncher:L274,
CheckLauncherFocus:L288, CloseLauncher:L298）はすべて実ファイルと完全一致。
ファイル総行数326行もFableの見積もり（327行）とほぼ一致。「BY THE NUMBERS」セクションが
実際には行数を謳っておらず「1ファイル」とだけ表現している点も`grep`で確認済み
（`index.html:2512`）。設計の中核判断（`run:`定型文プレフィックスによる要望2のスコープダウン、
Tab3の採用）はいずれも実装的に妥当と判断。

## 結論の要約

| 論点 | 結論 |
|---|---|
| 要望2（フルスペック検索・起動） | **却下**（前回・今回会議とも維持。ブランド軸衝突・競合・規模崩壊・CPU負荷リスク） |
| 要望2の代替 | 定型文の `run:` プレフィックスで「お気に入りexeのワンクリック起動」のみ採用（約8行） |
| 要望1（タブUI） | **採用**。`Tab3`（AHK v2ネイティブタブ）で実装、約60〜65行 |
| 規模 | 326行 → 約390行。**400行を今後の防衛線**とし、これを超える追加要望は次の機能会議に差し戻す |

---

## A. 理想の体験フロー

製品の中核ループは *なぞってコピー → AIチャットに貼る → 右クリック長押しで送信*。前回の拡張でこのループに「直近コピー10件のストック」が加わった。今回の拡張はそのポップアップを「2枚のタブを持つ手札」に育てる。

1. ブラウザやエディタで、なぞってコピーを何回か行う（既存動作のまま、履歴に静かに積まれる）
2. AIチャット画面でサイドボタン（戻る）を長押し（0.35秒）— 既存トリガーのまま
3. カーソル位置にポップアップ。上部に **[履歴 3] [定型文 5]** の2タブ。既定は履歴タブ（履歴が0件なら定型文タブが開く）
4. 履歴タブ: 直近コピー最大10件。1クリックで元ウィンドウにペースト（従来どおり）
5. 定型文タブ: `snippets.ini` に書いたラベル一覧。1クリックでその本文をペースト。「続けて」「日本語で回答して」のようなAI向け定番プロンプトを、タイプゼロで打ち込める
6. 定型文の本文を `run:C:\...\foo.exe` と書いた行は、ペーストの代わりに **そのexe/ファイルを1クリック起動**（リスト上は「▶」印で区別）。「起動場所を忘れたアプリ」はここに1行登録しておけば二度と探さない
7. リスト外クリックまたはEscでキャンセル（従来どおり）

タイピングは一切不要。検索ボックスはどこにも存在しない。

## B. 要望2（検索・起動機能）の結論

**フルスペックの検索・起動機能: 却下（前回・今回会議の判断を維持）。** ブランド軸との衝突（タイピング前提）、PowerToys Run/Fluent Searchとの正面競合、規模崩壊、そして今回追加されたインデックス走査のCPU負荷リスク。覆す論拠は出なかった。

**会議の発散案（タイピング不要の想起機能）: 却下。** 「マウスだけで完結＝認知負荷の排除」という**再解釈そのものは採用する**が、その実装として「ウィンドウ履歴からの自動想起」は採らない。理由:

1. ウィンドウアクティベーション履歴の収集には常時バックグラウンド監視が要る。既存設計が`OnClipboardChange`を意図的に退けたのと同じ性質の再導入であり、地雷の精神に反する
2. 想起の候補品質はヒューリスティクス次第で、外れた候補を毎回目でスキャンさせるのは「認知負荷の排除」の**逆効果**
3. ユーザーの真のニーズ（「起動場所を忘れたexeを呼びたい」）は、下記のスコープダウン案が1/10のコストで満たす

**スコープダウン案（お気に入りexeのワンクリック起動）: 採用。ただし専用機能としてではなく、定型文の `run:` プレフィックスとして実装する。** 定型文タブの1行 `ビルド起動=run:C:\tools\build.exe` をクリックすると起動する。追加コードは約15行。新しいUI・新しいini・新しいトリガーは一切増えない。ユーザーが自分で登録した行しか出ないので「候補品質」の問題も原理的に存在しない — これが「認知負荷の排除」解釈の最小・確実な実装である。

## C. 要望1（タブUI）の結論

**物理タブ（`Gui.Add("Tab3")`）を採用。** 「AHKのタブは実装コスト高」という会議の指摘はv1時代の感覚で、v2では以下の約10行で成立する（Dに全文）。

```autohotkey
tab := LauncherGui.Add("Tab3", "w360 -Wrap", ["履歴 " . ClipHistory.Length, "定型文 " . Snippets.Length])
tab.UseTab(1)
lbH := LauncherGui.Add("ListBox", "w340 r" . rows, histItems)
tab.UseTab(2)
lbS := LauncherGui.Add("ListBox", "w340 r" . rows, snipItems)
tab.UseTab()
```

会議で出た代替案（ListViewの列見出し・アイコンによる視覚分離）を退ける理由: モード切替のクリック対象は結局必要で、それを自作するとTab3より行数が増える。Tab3はネイティブ描画・ヒットテスト・見た目の慣習（Cliborと同じ「タブ」というメンタルモデル）を全部タダで貰える。

行数見積: 差分合計 **約60〜65行**。現状326行 → **約390行**。LPの「BY THE NUMBERS」は「3操作・ショートカット0個・1ファイル」であり**行数は謳っていない**（`index.html:2512`で確認済み）。「1ファイル・サーバーもAIも使わない」は不変なので売り文句とは両立する。ただしここを今回の上限とし、**400行を超える追加は次の機能会議マターとする**。

## D. 具体機構

差分は5ブロック。対象は `dist/soushin-suggest.ahk`（行番号は現ファイル実測・裏取り済み。実装時は`grep -n`で再特定すること）。

**(1) グローバル追加（既存の`global`群に1行）**

```autohotkey
global Snippets := []           ; snippets.ini から開くたびに再読込（非常駐キャッシュ）
```

**(2) snippets.ini ローダー（LoadSitesConfigの直後に新設・約20行）**

```autohotkey
; --- snippets.ini: ラベル=本文（\n で改行、run:パス で起動）---
; sites.iniパーサと違い、インラインコメント(;)は剥がさない — 本文に ; が入りうるため。
; IniRead は使わない（非ASCIIキー誤読の既知の罠。ラベルは日本語になる）。
LoadSnippets() {
    items := []
    path := A_ScriptDir . "\snippets.ini"
    if !FileExist(path)
        return items
    for line in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "[")
            continue
        eq := InStr(line, "=")
        if !eq
            continue
        label := Trim(SubStr(line, 1, eq - 1))
        val := Trim(SubStr(line, eq + 1))
        if (label != "" && val != "")
            items.Push({label: label, value: StrReplace(val, "\n", "`n")})
    }
    return items
}
```

**(3) ShowLauncher の置換（L249-272。約24行→約42行）**

```autohotkey
ShowLauncher() {
    global ClipHistory, LauncherGui, LauncherTarget, Snippets
    Snippets := LoadSnippets()                ; 開くたびに読む: iniを編集→次の長押しで即反映
    if (ClipHistory.Length = 0 && Snippets.Length = 0) {
        ToolTip("履歴がありません（なぞってコピーすると貯まります）")
        SetTimer () => ToolTip(), -1800
        return
    }
    LauncherTarget := WinExist("A")           ; ペースト先を先に記憶
    CloseLauncher()
    LauncherGui := Gui("-Caption +AlwaysOnTop +ToolWindow +Border")
    LauncherGui.SetFont("s10", "Meiryo UI")
    tab := LauncherGui.Add("Tab3", "w360 -Wrap",
        ["履歴 " . ClipHistory.Length, "定型文 " . Snippets.Length])
    rows := Min(Max(ClipHistory.Length, Snippets.Length, 3), 10)
    tab.UseTab(1)
    histItems := []
    for v in ClipHistory {
        s := RegExReplace(v, "\s+", " ")
        histItems.Push(StrLen(s) > 40 ? SubStr(s, 1, 40) . "…" : s)
    }
    lbH := LauncherGui.Add("ListBox", "w340 r" . rows, histItems)
    lbH.OnEvent("Change", PasteHistoryItem)
    tab.UseTab(2)
    snipItems := []
    for s in Snippets
        snipItems.Push((SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . s.label)
    lbS := LauncherGui.Add("ListBox", "w340 r" . rows, snipItems)
    lbS.OnEvent("Change", UseSnippetItem)
    tab.UseTab()
    if (ClipHistory.Length = 0)
        tab.Value := 2                        ; 履歴が空なら定型文タブで開く
    LauncherGui.OnEvent("Escape", (*) => CloseLauncher())
    MouseGetPos &mx, &my
    LauncherGui.Show("x" . mx . " y" . my)
    WinActivate("ahk_id " . LauncherGui.Hwnd)
    SetTimer(CheckLauncherFocus, 150)         ; リスト外クリックで閉じる
}
```

**(4) ペースト系の分割（L274-286 の PasteFromLauncher を3関数に。約13行→約35行）**

```autohotkey
PasteHistoryItem(lb, *) {
    global ClipHistory
    idx := lb.Value
    if (idx < 1)
        return
    text := ClipHistory[idx]
    CloseLauncher()
    PasteText(text)
}

UseSnippetItem(lb, *) {
    global Snippets
    idx := lb.Value
    if (idx < 1)
        return
    s := Snippets[idx]
    CloseLauncher()
    if (SubStr(s.value, 1, 4) = "run:") {
        target := Trim(SubStr(s.value, 5))
        try Run(target)
        catch {
            ToolTip("起動できませんでした: " . target)
            SetTimer () => ToolTip(), -1800
        }
        return
    }
    PasteText(s.value)
}

PasteText(text) {
    global LauncherTarget
    A_Clipboard := text
    if (LauncherTarget && WinExist("ahk_id " . LauncherTarget))
        WinActivate("ahk_id " . LauncherTarget)
    Sleep 150
    Send("^v")
}
```

`CheckLauncherFocus` / `CloseLauncher`（L288-305）は無変更。XButton1ハンドラ（L235-247）も無変更 — 許可リスト外は最初の分岐で即スクショに落ちる構造に一切触らない。

**(5) 同梱ファイル `dist/snippets.ini` 新規（コードではなく配布物）**

```ini
; 定型文: ラベル=本文
; ・\n と書くと改行になります
; ・本文を run:フルパス にすると、貼り付けの代わりにそのアプリ/ファイルを開きます
続けて=続きをお願いします。
日本語で=日本語で回答してください。
要約して=以下を3行で要約してください。\n
;ビルド起動=run:C:\Users\あなた\tools\build.exe
```

## E. MVP（今すぐやる最小の一手）

1. **(1)+(2)+(3)+(4)のペースト側のみ**（`run:` 分岐の8行をコメントアウトした状態でも成立する）。ここまでで要望1が完了し、履歴0件でも定型文が使える
2. `run:` 分岐を有効化（+8行）。要望2のスコープダウン分が完了
3. `dist/snippets.ini` を作成し、`scripts/build.ps1` の配布物リスト（zipに sites.ini を入れている箇所）に snippets.ini を追加
4. `scripts/build.ps1` でビルド（Git BashからAhk2Exe直叩き厳禁）→ reality-checker に動作判定を委任

検証観点: (a) 許可リスト外でXButton1押下→即スクショ（従来と1msも変わらない）、(b) 長押し→タブ2枚のポップアップ、履歴/定型文の件数がタブ見出しに出る、(c) 履歴タブ1クリック→元ウィンドウへペースト（回帰）、(d) 定型文1クリック→本文ペースト、`\n` が実改行になる、(e) `run:` 行クリック→exe起動、パス誤りならToolTipのみ、(f) 履歴0件・snippets.iniあり→定型文タブで開く、(g) 両方0件→ToolTip案内のみ、(h) snippets.ini を編集→再起動なしで次の長押しに反映、(i) リスト外クリック/Escで閉じるだけ。

## F. 捨てた案と理由

- **フルスペックのファイル・アプリ検索**: 却下（Bで詳述。前回判断維持＋CPU負荷の新論拠）
- **ウィンドウ履歴からの自動想起**: 却下。常時監視の再導入・候補品質の不確実性・`run:` 定型文が同じニーズを15行で満たす（Bで詳述）。ただし「認知負荷の排除」という軸の再解釈は本設計の土台として採用した
- **音声入力・ジェスチャー**: 235行の単一AHKファイルという規模感を無視した提案のため検討対象外
- **お気に入り起動を第3タブ「起動」として独立実装**: 却下。タブ・ini・ローダーが1組増えるのに対し、`run:` プレフィックスなら8行。「定型文＝クリックしたら決まったことが起きる行」という1つの説明に収まる
- **ListView列見出し/アイコンによる視覚的分離（物理タブ回避案）**: 却下。モード切替のクリック対象を自作する分だけTab3より高くつく（Cで詳述）
- **最後に使ったタブの記憶**: 却下。状態の永続化が1つ増える割に、既定ルール（履歴あり→履歴）で十分
- **snippets.iniの常駐キャッシュ＋トレイの再読込メニュー**: 却下。ファイルは数KBで開くたびに読んでも体感ゼロ。「編集→即反映」の方がUXも実装も安い
- **`OnClipboardChange` / 履歴の永続化 / 検索ボックス**: 前回設計で却下済み。今回も維持

## G. 地雷と回避策

1. **ビルドは必ず `scripts/build.ps1`**。Git BashからAhk2Exe直叩きは引数が壊れる（既知）。**snippets.ini をzip同梱リストに足し忘れない** — build.ps1 が配布ファイルを列挙している場合、sites.ini の隣に1行追加が必要
2. **`Tab` ではなく `Tab3` を使う**。旧Tab/Tab2はテーマ描画とサイズ計算に既知の癖がある。v2では `Tab3` が正
3. **snippets.ini のパースに sites.ini のパーサを共用しない**。sites.iniパーサはインラインコメント（`;`）を剥がすが、定型文本文には `;` が普通に入る。LoadSnippets を別関数にしたのはこのため。共通化リファクタ禁止
4. **`IniRead` は使わない**（既存コメントにある日本語キー誤読の既知の罠。定型文ラベルは必ず日本語になる）
5. **ListBoxの `Change` イベントはクリック1回で発火するが、「既に選択済みの行の再クリック」では発火しない**。本設計ではGUIを毎回 Destroy/再生成するので選択状態が持ち越されず問題にならない — GUIを使い回す最適化をしないこと
6. **フォーカス監視タイマーの順序**: `Show` → `WinActivate` → `SetTimer` の順を崩すと開いた瞬間に自滅する（既存設計の回避策を踏襲。タブを足しても順序は同じ）
7. **`Sleep 150` のペースト取りこぼし**: Electron系（ChatGPT.exe等）で落ちる場合は250へ。既存値を触るなら履歴・定型文の両経路（`PasteText` に一本化済み）で回帰確認
8. **`run:` の起動は必ず `try`で包む**。パスtypo・移動済みexeで例外が飛ぶ。失敗時はToolTipのみで、ポップアップを再表示しない（誤爆連打の防止）
9. **定型文のペーストはクリップボードを上書きする**。履歴ペーストと同じ既存挙動であり仕様とするが、READMEに一行明記する
10. **LP文言修正（別タスクに切り出し）**: (a) クイックペーストの説明に「履歴/定型文の2タブ」「`run:` でお気に入りアプリの1クリック起動」を追記、(b) compatibility/機能説明に snippets.ini を追加。「BY THE NUMBERS」は行数を謳っていないため修正不要（確認済み）
11. **規模の上限**: 今回で約390行。**400行が「1ファイル・軽量」の防衛線**。これを超える要望（検索・想起の再燃を含む）は実装せず、次の機能会議に差し戻すこと
