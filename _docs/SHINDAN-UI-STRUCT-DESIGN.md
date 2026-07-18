# 設計: /shindan/ 診断ページのUI構造リグレッション確認への拡張

設計=Fable（claude-fable-5） / 素材集め・裏取り・統合=司令塔（Claude Sonnet 5） / 2026-07-18 / 3段構えワークフロー手順2の産物

正本の位置づけ: `+Grid`変更（[`LAUNCHER-SNIPPETS-CLIBOR-VISIBILITY-DESIGN.md`](LAUNCHER-SNIPPETS-CLIBOR-VISIBILITY-DESIGN.md)）の実機確認で「スクリーンショットでは空白に見えたが実際はデータが正しく表示されていた」という誤検知が発生したことを契機に、AIによる自動UI確認手段そのものを設計した。

裏取り済み: `;@Ahk2Exe-IgnoreBegin`/`IgnoreEnd`ディレクティブの実在・構文（公式ドキュメント`autohotkey.com/docs/v2/misc/Ahk2ExeDirectives.htm`で確認）、`scripts/build.ps1`が配布zipに`.ahk`ソースを含めないこと、`dist/soushin-suggest.ahk`の該当行番号（L99-100, L270-289, L1503-1517, L1542）、`scripts/verify-diagnostics.ps1`の実在と動作。すべて設計書の記述と一致。

## 結論の骨子

開発ビルド（非コンパイル実行）のみ、ランチャーGUIを開いた瞬間にコントロールの座標・寸法・可視性・行数を読み取ってメモリに文字列としてキャッシュし、既存の診断JSONに`ui`フィールドとして相乗りさせる。本番exeでは**Ahk2Exeコンパイル時にコード自体を除去**し、構造的に送信不可能にする。サーバー側（Cloudflare Functions）は**変更ゼロ**。

## 決定済み事実（現行設計、覆さない）

- `BuildDiagText()`（`dist/soushin-suggest.ahk` L270-289）が送信データを組み立て、末尾は`return s . "}}"` (L288)
- 送信経路: `POST /api/diag/report` → Cloudflare KV(`DIAG_KV`) TTL6時間。閲覧は`GET /api/diag/latest`
- `functions/api/diag/report.ts`は`diag`をスキーマ非依存で素通し保存（token形式と`diag.app`のみ検証）、`MAX_BODY_BYTES=8KB`
- 過去の最重要地雷: 自動送信を同期HTTPで実装した際、5分おきの送信中にランチャーGUI構築が割り込むと画面が白化するバグが発生し、非同期版`DiagPushAsync`に切り替えて解決した実績がある。UI構造ダンプでも同種のリスクを警戒すること。

## A. 理想の体験フロー

**開発者（人間・AIとも）**:
1. `.ahk`を直接実行（＝開発モード。判定は`A_IsCompiled`で自動、設定不要）
2. ランチャーを開く。開いた瞬間、レイアウト確定後のUI構造がメモリにキャッシュされる
3. トレイ「診断ページで見る」→`/shindan/`に既存カード群の下に新セクション「🧩 UI構造（開発ビルドのみ）」が出現。ウィンドウ寸法＋コントロール一覧（種類/x/y/w/h/可視/行数）の表と、はみ出し・寸法ゼロの機械判定が見える
4. **AIによる自動確認**: `scripts/verify-ui-snapshot.ps1`（新規）が既存`verify-diagnostics.ps1`と同じF10パターンで`diag-out.json`を取得し、`ui`フィールドの不等式チェックでPASS/FAILを返す。スクリーンショット不要・ネットワーク不要でレイアウト崩れを検知できる

**本番ユーザー**: 何も変わらない。exeには読み取りコードが物理的に存在せず、送信JSONは今日と同一バイト構造。

## B. 統合アーキテクチャ（変更箇所3つ＋新規1つ）

```
[dev実行 .ahk]                          [本番 exe]
ShowLauncher() 末尾                      (Ahk2Exe-Ignoreで
  └ DiagCaptureUiSnapshot() ──┐          コードごと不在)
      同期・ユーザー操作起点   │
      レイアウト確定後に1回    ▼
                    global DiagUiSnapBody (文字列キャッシュ)
                              │
BuildDiagText() ──────────────┘  ← 送信時はWin32呼び出しゼロ、文字列連結のみ
      │
      ▼ 既存経路そのまま(DiagPush/DiagPushAsync → report.ts → DIAG_KV)
/shindan/index.html renderUiSection()  ← diag.ui があるときだけ表示
```

1. `dist/soushin-suggest.ahk` — グローバル2つ追加、`DiagCaptureUiSnapshot()`新設（Ignoreブロック内）、`ShowLauncher()`末尾に呼び出し3行（Ignoreブロック内）、`BuildDiagText()`に連結2行
2. `shindan/index.html` — `<section data-sec="ui">`追加＋描画関数1つ。`KEY_REGISTRY`・`aggregate()`・総合判定は**不変**
3. `scripts/verify-ui-snapshot.ps1` — 新規。AI自動リグレッション確認の入口
4. `functions/api/diag/*.ts` — **変更なし**

## C. 具体機構

### C-1. 本番混入の構造的防止（3層）

**第1層: コンパイル時除去**。`;@Ahk2Exe-IgnoreBegin`/`;@Ahk2Exe-IgnoreEnd`で関数定義と呼び出し箇所の**両方**を囲む。`scripts/build.ps1`の変更は不要（ディレクティブはソース内で完結し、既存のAhk2Exe呼び出しがそのまま処理する）。

**第2層: バイナリ属性による実行時ガード**。関数冒頭で`if A_IsCompiled return`。`A_IsCompiled`は実行バイナリの性質そのものであり、環境変数・iniと違って誤設定が原理的に不可能。第1層が万一将来のリファクタで剥がれても、コンパイル済みexeでは実行されない。

**第3層（受動的）**: `DiagUiSnapBody`はIgnoreブロックの**外**で`""`初期化され、書き込むコードはIgnoreブロックの**内**にしかない。本番では恒久的に空文字列＝`ui`キー自体が出力されない。

環境変数やini設定によるオプトインは採用しない（F節参照）。「ビルド構成のミスや環境変数の誤設定で本番に紛れる」というリスクは、設定ベースのゲートが持つ弱点そのもの。`A_IsCompiled`＋コンパイル時除去は設定が存在しないので誤設定できない。

### C-2. AHK側実装（行番号は現行`dist/soushin-suggest.ahk`基準）

**(a) グローバル追加** — L100（`DiagEndpoint`宣言）の直後:
```ahk
; UI構造スナップショット(開発ビルド専用)。書き込みコードはAhk2Exe-Ignoreブロック内にのみ
; 存在するため、本番exeでは恒久的に空("")のまま = uiフィールドは絶対に送信されない。
global DiagUiSnapBody := ""      ; '"win":"launcher","w":460,...' 形式(外側の{}なし)
global DiagUiSnapTick := 0
```

**(b) 読み取り関数** — `BuildDiagText()`（L289）の直後に新設:
```ahk
;@Ahk2Exe-IgnoreBegin
; UI構造ダンプ(開発ビルド専用)。
; 【白化バグ回避の不変条件】この関数はユーザー操作起点(ShowLauncher末尾、Show()完了後)から
; しか呼ばない。タイマー・送信経路(BuildDiagText/DiagPushAsync)からWin32 UI読み取りを
; 行うことを禁止する。送信時に触るのはキャッシュ済み文字列のみ。
DiagCaptureUiSnapshot(g, name) {
    global DiagUiSnapBody, DiagUiSnapTick
    if A_IsCompiled            ; 第2層ガード(第1層=Ahk2Exe-Ignoreが剥がれた場合の保険)
        return
    try {
        g.GetPos(, , &gw, &gh)
        s := '"win":"' . name . '","dpi":' . A_ScreenDPI . ',"w":' . gw . ',"h":' . gh . ',"ctrls":['
        n := 0
        for hwnd, ctrl in g {
            if (n >= 40) {                    ; report.tsの8KB上限を絶対に脅かさない
                s .= ',{"trunc":1}'
                break
            }
            ctrl.GetPos(&cx, &cy, &cw, &ch)
            e := '{"t":"' . ctrl.Type . '","x":' . cx . ',"y":' . cy
               . ',"w":' . cw . ',"h":' . ch . ',"vis":' . (ctrl.Visible ? 1 : 0)
            if (ctrl.Type = "ListView")
                e .= ',"rows":' . ctrl.GetCount() . ',"cols":' . ctrl.GetCount("Col")
            s .= (n ? "," : "") . e . "}"
            n++
        }
        DiagUiSnapBody := s . "]"
        DiagUiSnapTick := A_TickCount
    } catch {
        DiagBump("uiSnapFail")   ; 失敗しても本体に一切影響させない(fail-silent)
    }
}
;@Ahk2Exe-IgnoreEnd
```
コントロールの`.Text`は**読まない**（検索Editにはユーザー入力が入る。座標・種類・件数のみ）。

**(c) 呼び出し** — `ShowLauncher()`の`LauncherSearchEdit.Focus()`（L1542）の直後:
```ahk
    ;@Ahk2Exe-IgnoreBegin
    DiagCaptureUiSnapshot(LauncherGui, "launcher")   ; レイアウト確定後・表示直後の1回だけ
    ;@Ahk2Exe-IgnoreEnd
```
※呼び出し側もIgnoreで囲むこと（定義だけ除去すると本番exeが「関数未定義」でロードエラーになる。G-2参照）。

**(d) `BuildDiagText()`の末尾変更** — L288の`return s . "}}"`を:
```ahk
    s .= "}"                                  ; countersを閉じる
    if (DiagUiSnapBody != "")                 ; 本番では恒久的に空(C-1第3層)
        s .= ',"ui":{"agoMs":' . (now - DiagUiSnapTick) . ',' . DiagUiSnapBody . '}'
    return s . "}"
```

### C-3. JSONスキーマ（`diag`直下に追加される任意フィールド）

```json
"ui": {
  "agoMs": 4200,
  "win": "launcher", "dpi": 96, "w": 460, "h": 612,
  "ctrls": [
    {"t":"Text","x":0,"y":0,"w":376,"h":16,"vis":1},
    {"t":"Tab3","x":0,"y":16,"w":460,"h":420,"vis":1},
    {"t":"Edit","x":214,"y":19,"w":242,"h":24,"vis":1},
    {"t":"ListView","x":2,"y":46,"w":460,"h":366,"vis":1,"rows":10,"cols":1},
    {"t":"ListView","x":2,"y":46,"w":460,"h":366,"vis":0,"rows":7,"cols":1}
  ]
}
```
非表示タブ側のListViewは`vis:0`で写る＝タブ切替の壊れも検知対象になる。実測サイズ約0.9KB、診断JSON全体で約2.5KB（8KB上限の1/3以下）。

### C-4. Cloudflare Functions側の変更点

**なし**。`report.ts`は`diag`の中身を検証せず素通しで保存、`latest.ts`はそのまま返すだけ。8KB上限は(b)の40コントロール上限で構造的に守る。

### C-5. `/shindan/index.html`の変更（別セクションに分離）

`KEY_REGISTRY`カード群と混ぜない。理由: (1)ライフサイクルが違う（カード＝本番ユーザー向け常設、UI構造＝開発ビルド限定の臨時）、(2)総合判定`aggregate()`の意味を汚さない（本番ユーザーの赤/黄/緑判定にdev専用情報が影響してはならない）。

- `other`セクションの直後に追加:
  `<section data-sec="ui" hidden><h2>🧩 UI構造（開発ビルドのみ）</h2><div id="uiMeta"></div><div id="uiChecks"></div><div id="uiTable"></div></section>`
- `render()`の末尾に`renderUiSection(snapshot.ui)`を1行追加。`snapshot.ui`が無ければ`hidden`のまま（本番では永遠に非表示。本番で「未取得」灰カードを常設するとユーザーを混乱させるだけなので、KEY_REGISTRYの「未観測もカードを出す」方針はここには適用しない）
- `renderUiSection(ui)`: メタ行（`launcher 460×612 / DPI96 / 取得4.2秒前`）＋機械判定＋表（種類/x/y/w/h/可視/行数、`textContent`で組む）
- 機械判定は不等式のみ3本（等式検証を採らない既存思想と同じ）:
  - 赤: `vis:1`かつ`w=0 || h=0`（描画されないコントロール＝レイアウト崩れの典型）
  - 赤: `vis:1`かつ`x+w > win.w+8 || y+h > win.h+8`（ウィンドウ外はみ出し）
  - 黄: `vis:1`のListViewで`rows=0`かつ`histLen>0`（データはあるのにリストが空）
  - 判定結果はこのセクション内にのみ表示し、ページ最上部の総合verdictには合流させない

### C-6. AI自動確認の入口: `scripts/verify-ui-snapshot.ps1`（新規）

`verify-diagnostics.ps1`の既存パターンを丸ごと流用（ステージング→.ahk直接起動→ドライバAHKでキー送出→ファイル読み）:
1. `^#v`送出でランチャー表示 → 300ms待ち → `Escape`で閉じる（キャッシュは閉じても残る）
2. F10（既存ヘルパー）で`diag-out.json`取得
3. アサート: `ui`フィールドが存在／`ctrls`に`ListView`が2つ／C-5と同じ不等式3本／`ui.w = 460`（`launcherW`定数と一致）
4. ついでに本番混入の逆アサートをG-3の手順で（コンパイル後exeの診断JSONに`ui`キーが無いこと）

**白化バグ再燃リスクへの回答**: 読み取り（十数回のGetPos＋GetCount）は自プロセス・自スレッドのウィンドウへの同期呼び出しで、既にShowLauncher内L1503-1517が同種のGetPos/Moveを実行している場所の直後に1回だけ走る（<1ms、ユーザー操作起点）。5分タイマーの送信経路は文字列連結しか行わず、Win32 UI APIに一切触れない。白化バグの原因だった「タイマー起点の処理がGUI構築と衝突」というクラス自体を、読み取りと送信の時点分離で構造的に排除している。

## E. MVP（1つだけ作るなら）

C-2のAHK側変更（(a)〜(d)）だけ。ビューア・verify新設なしでも、`diag-out.json`／`GET /api/diag/latest`のJSONに`ui`が載った時点で、AIはレイアウト崩れを数値で判定できる（AIはJSONを直接読むのが本来の消費経路であり、ビューアは人間用の後付け）。次いでC-6、最後にC-5。

## F. 捨てた案と理由

| 案 | 理由 |
|---|---|
| **ハッシュ＋オンデマンド差分（会議の発散役案）** | 全ダンプが1KB弱しかない現実の前では、ハッシュで節約するものが存在しない。期待値ハッシュの管理・差分要求の往復という2プロトコル分の複雑さが丸ごと過剰設計。 |
| **環境変数/ini設定によるオプトインゲート** | 「ビルド構成のミスや環境変数の誤設定で本番に紛れる」という会議の批判役の失敗シナリオは、まさに設定ベースのゲートが持つ弱点。`A_IsCompiled`＋コンパイル時除去は設定が存在しないので誤設定できない。 |
| **専用トレイメニュー項目の追加** | 不要。キャプチャは受動（ランチャーを開けば起きる）、送信は既存の「診断ページで見る」／5分自動送信に相乗り。メニューを増やすと本番ビルドから項目を消し分ける新たな分岐が生まれる。 |
| **UI構造用の別エンドポイント/別KVキー** | report.tsがスキーマ非依存である現行の美点を捨てて、サーバー側の面積とfail点を倍にするだけ。8KBに収まる限り相乗り一択。 |
| **5分タイマーでの再キャプチャ（常に最新のUI構造を送る）** | 「タイマー起点でUIを触る」は白化バグと同じクラス。`agoMs`で鮮度を明示する方が安全で十分。 |
| **ピクセル/スクリーンショット比較** | プライバシーの一線（画面内容を送らない）に抵触。却下済みの前提を維持。 |
| **UI判定を総合verdictへ合流** | 本番ユーザー向け判定の意味論を開発専用情報で汚す。セクション内完結にした。 |

## G. 地雷と回避策

- **G-1（最重要・白化クラス再発）**: Win32 UI読み取りをタイマー/送信経路に置かない。不変条件はC-2(b)冒頭コメントとして必ずコードに残す。将来「最新構造も送りたい」となっても再キャプチャは必ずユーザー操作起点（ランチャーopen時）のみ。
- **G-2（Ignoreブロックの片割れ除去）**: 定義だけ除去して呼び出しを残すと、コンパイル後exeが起動時ロードエラーで全機能死する。定義と呼び出しの両方をIgnoreで囲み、実装後は必ず`scripts/build.ps1`を1回通してexeが起動することを確認してからコミット。
- **G-3（本番混入の実証確認）**: 「コードを読んで大丈夫」で終えない。コンパイル後exeを起動→「診断情報をコピー」→JSONに`ui`キーが無いことを目視/スクリプトで確認する逆アサートをリリース手順に入れる（reality-checker委任項目）。
- **G-4（8KB上限）**: ctrls上限40で現状は1/3以下。将来SnipMgr/設定ウィンドウ（コントロール30個超）まで対象を広げる場合は同時1ウィンドウ分のみ保持（`DiagUiSnapBody`上書き）を維持し、複数ウィンドウの蓄積配列にしない。
- **G-5（プライバシー線引きの明文化）**: `.Text`・ListView項目文字列・ウィンドウタイトルは読まない。座標/種類/件数/可視性のみ。`/shindan/`のプライバシーカードに「開発ビルドのみ、画面の内容ではなく枠の座標だけ」の1行を追記する。
- **G-6（uiSnapFailカウンター）**: 意図的に`KEY_REGISTRY`へ登録しない。登録すると本番ユーザーに永遠に灰色の「未観測」カードが常設されるため。生JSON・AI相談コピーには写るので開発時のデバッグには足りる。
- **G-7（DPI差異）**: 座標はDPI依存。`dpi`フィールドを必ず併記し、リグレッション比較は同一DPI環境同士でのみ行う（verify-ui-snapshot.ps1は同一マシン内比較なので影響なし）。
