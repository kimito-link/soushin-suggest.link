# 送信サジェスト 設定統合 設計書

設計=Fable(claude-fable-5サブエージェント) / 素材集め=無料会議ハーネス(クラウド無料枠5体・成功5/6) / 裏取り・統合=司令塔Claude
日付: 2026-07-17 ／ 3段構え(council-fableスキル)手順2の産物

対象: `dist/soushin-suggest.ahk`(正本・2012行・AutoHotkey v2)。配布はビルド済みexe単体、管理者権限なし、常駐。

発端: `HANDOFF-next-session.md:52`「設定を押したらすべての設定が一元管理できないと使いづらい」というユーザー要望(方針合意済み・未実装)。現状「設定」は以下5系統に分散していた:
1. `sites.ini` の `[general]`/`[clipboard]` セクション
2. トレイメニュー直下のトグル(自動起動・監視一時停止、iniに保存されずレジストリ/実行時フラグ管理)
3. 「設定...」GUI(`ShowSettingsWindow`、フォルダ保存2項目のみ)
4. `snippets.ini` 直接編集(上級者向け生ファイル導線)
5. `startup-prompted.flag`(初回のみの状態フラグ)

## 設計の背骨(1行)

**「プログラムが書くファイル」と「人間が書くファイル」の所有権を分離し、プログラム側は全文再生成、人間側にはもう手を出さない。** 5系統の分散も、セクション混入バグも、BOM論争も、根っこは「人間のコメント付きファイルをプログラムが文字列手術で書き換えている」一点にある。

Fableは設計にあたり正本ソースを実地確認し、会議ハーネスの推測との差分を以下のとおり訂正している:
- `SaveIniKey`(L1431-1455)の実装は「既存キーがなければ次のセクションヘッダの直前に挿入」方式で、現物の`sites.ini`34-35行目の`archiveimage=on`/`archivetext=on`は**INI文法上は`[clipboard]`内だが、コメント行と空行の後ろ・`[chrome.exe]`の直前**に置かれ、人間には別セクション所属に見える。文法バグというより「人間可読性の破壊」が本質。
- 起動時トグルはレジストリではなく`shell:startup`のショートカット実在(`FileExist`、L184-186)が真実。状態を別に保存する必要はない。

**【2026-07-17 追記・司令塔による実測検証と設計訂正】**

`refactor-instructions.md`(既存のリファクタ指示書、`_docs/`とは別に配置)がBOM問題について実測ベースの絶対制約を既に定めていたため、AutoHotkey v2で新規に実測検証を行った(新規作成4パターンの先頭バイトを直接比較):

| 書き込み方式 | 新規作成時のBOM |
|---|---|
| `FileAppend(..., "UTF-8")` | **BOM付き**(`EF BB BF`) |
| `FileOpen(..., "w", "UTF-8")` | **BOM付き**(`EF BB BF`) |
| `FileOpen(..., "w", "UTF-8-RAW")` | BOMなし |
| 既存ファイル(UTF-8-RAW作成済み)への`FileAppend(..., "UTF-8")`追記 | 増えない(無害) |

結論: **地雷マップの「実測BOM付き」が正しく、コード内コメント(L1450-1451)の「FileAppend(UTF-8)はBOMなし」は誤り**。この実測により、以下2点を確定できる:

1. 本設計書C-2の`FileOpen(..., "w", "UTF-8-RAW")`による新規書き出しは**実測で裏付けられた正しい選択**であり変更しない。
2. ただし`refactor-instructions.md`§3は「iniへの書き込みを新設する場合は既存の`FileDelete`+`FileAppend(...,"UTF-8")`流儀に従う(`FileOpen(...,"w","UTF-8")`は禁止)」を絶対制約としている。これは`sites.ini`/`snippets.ini`という**人間所有ファイルへの追記**を想定した制約であり、本設計が新設する`settings.ini`は**プログラム専有・全文再生成**という別カテゴリのファイルである(A節冒頭の所有権分離の核)。したがって`settings.ini`に限り`FileOpen(..., "w", "UTF-8-RAW")`を採用してよい。`sites.ini`/`snippets.ini`への既存書き込み経路(`SaveIniKey`削除後も残る`snippets.ini`側)は引き続き`refactor-instructions.md`の流儀(`FileDelete`+`FileAppend(...,"UTF-8")`)に従い、変更しない。
3. `FileDelete`→`FileAppend`の2段書きで、間でクラッシュすると`sites.ini`が全損する原子性の穴がある(`settings.ini`側はC-2の原子リネームで対策済み。`sites.ini`/`snippets.ini`側は本設計のスコープ外 — 触らない方針そのものが安全策)。

---

## A. 理想の体験フロー

### 初回起動(現状維持+1変更)
1. exeダブルクリック → 常駐開始トースト(現行どおり)。
2. 自動起動の確認MsgBox 1回(現行どおり。ウィザードは作らない — F節)。
3. **変更点**: `startup-prompted.flag` を廃止し、`settings.ini` の `[state] firstrunprompted=1` に吸収。ユーザーから見える挙動は不変、配布フォルダのファイルが1つ減る。

### 日常利用(初心者)
- 何かを変えたくなったら入口は常に1つ: **トレイ右クリック →「設定...」**。
- 開くと「基本」タブに日本語1行説明付きのチェックボックスが5つ前後。**チェックした瞬間に反映**(保存ボタンなし・OKボタンなし。現行`ApplyArchiveToggle`の即時反映流儀を全項目に拡張)。
- ウィンドウは非モーダル。開いたままでもなぞってコピー・監視・ホットキーは全部動く(現行`SnipMgrGui`と同じシングルトン+Hide方式)。

### 日常利用(上級者)
- スニペットの高速編集: トレイ「定型文の管理...」は**トレイに残す**(頻度が高い実務導線を1クリック深くしない)。
- 設定ウィンドウ下部の「上級者モードを有効にする」をON → 「高度」タブが現れ、longpress閾値・履歴件数・自動クリア秒・除外exe・保存先フォルダと、**「sites.iniを編集」「snippets.iniを編集」「設定フォルダを開く」ボタン**が並ぶ。生ファイル導線は消さない(F節)。
- `sites.ini`を外部エディタで編集 → 保存したら反映は「次回起動時」または高度タブの「ルールを再読込」ボタン。ファイル監視での自動リロードはしない(F節)。

---

## B. 統合アーキテクチャ(コンポーネント4個)

```
┌─ トレイメニュー(薄い) ────────┐      ┌─ SettingsWindow(タブGUI) ─┐
│ 一時停止/履歴全削除/定型文/設定... │      │ 基本タブ / 高度タブ(遅延)   │
└──────┬─────────────┘      └──────┬─────────────┘
        │ 両方とも同じ入口を叩く              │
        ▼                                  ▼
┌─ SettingsStore(唯一の書き手) ──────────────────────┐
│ ・メモリ上のMap(即時の真実)                                  │
│ ・SetSetting(key,val) → applyFn即時実行 + 300msデバウンス書込 │
│ ・settings.ini を毎回「全文再生成」(read-modify-write廃止)     │
│ ・tmp書き→MoveFileEx原子リネーム・UTF-8-RAW(BOM構造的に不可能) │
└──────┬───────────────────────────────┘
        ▼
┌─ Migrator(起動時1回だけ) ─────────────────────────┐
│ settings.ini が無ければ: sites.ini [general]/[clipboard] と    │
│ startup-prompted.flag から現在有効値を吸い上げて生成、          │
│ sites.ini.bak を残す。以後 sites.ini は読み取り専用(ルールのみ) │
└───────────────────────────────────────┘
```

- **「即時反映イベントバス」は作らない。** 代わりに `SettingDefs` という静的Map(キー → {section, default, applyFn})を1個持つ。`SetSetting`が`applyFn`を直接呼ぶ。設定項目十数個の常駐アプリにpub/subは過剰(F節)。
- トレイのトグル(監視一時停止)と設定ウィンドウのチェックボックスは**同じ`SetSetting`を呼ぶ**ので、どちらから変えても食い違わない。ウィンドウ再表示時にStoreから値を読み直す(現行`ShowSettingsWindow` L1589-1592の再同期パターンを踏襲)。

## C. 具体機構

### C-1. ファイルとスキーマの再設計

**所有権で3ファイルに整理する**(ファイル数は増えない: flag廃止と相殺):

| ファイル | 所有者 | 書き手 | 内容 |
|---|---|---|---|
| `settings.ini`(新設) | プログラム | SettingsStoreのみ・全文再生成 | 動作設定すべて |
| `sites.ini` | 人間(+同梱既定) | **プログラムは今後書かない** | 送信ルール([exe]/[sites])のみ |
| `snippets.ini` | 人間+定型文GUI | 既存のまま | 定型文 |

**settings.iniスキーマ**(キー名は既存ini/既存グローバル変数と1対1対応、翻訳コスト最小):

```ini
; このファイルは送信サジェストが自動管理します。手で編集しても次の設定変更で上書きされます。
; 設定はトレイ →「設定...」から。送信ルールは sites.ini、定型文は snippets.ini へ。
[app]
version=1.13.0          ; 書いたアプリのバージョン(将来のスキーマ移行の判定材料)
advancedmode=0          ; 上級者モード(高度タブの表示)
[input]
longpress=0.35
[clipboard]
watch=on
max=30
autoclear=45
exclude=example.exe     ; 組込み既定(keepass等)への「追加分」のみ
imagemax=5
imagemaxmb=36
[archive]
image=off
text=off
dir=
[state]
firstrunprompted=1
```

- セクション粒度は「基本タブのグループボックス」と概ね一致させる(GUIとファイルの対応が目で追える)。
- `[clipboard] archiveimage` → `[archive] image` へ改名するのは settings.ini 新設時だけ(移行はMigratorが1回でやるので互換レイヤ不要)。
- 自動起動はsettings.iniに**書かない**。`shell:startup`のショートカット実在が唯一の真実(現行L184-186)で、二重管理すると必ずズレる。

**sites.ini**: スキーマ変更なし。冒頭コメントに1行追記のみ(移行時1回): 「※ [general]/[clipboard] の設定は v1.13 から設定画面(settings.ini)に移動しました。ここに書いても無視されます」。ローダ(`LoadSitesConfig`)は`settings.ini`存在時、`sites.ini`の`[general]`/`[clipboard]`を読み飛ばす。HANDOFF記載の「混入した`archiveimage=on`を無断削除しない」制約は、**値をsettings.iniに引き継いだうえでsites.ini側は触らず放置**することで満たす(無視されるだけで消えない)。

### C-2. 書き込み方式(混入バグ・BOM・原子性を一括で殺す)

```autohotkey
; SettingsStore の書き出し。settings.ini はプログラム所有なので
; 「読んで・部分修正して・書く」をやめ、メモリ上のMapから毎回全文を組み立てる。
; → SaveIniKey型の挿入位置バグ(セクション混入)は構造的に起き得ない。
FlushSettings() {
    global SettingsMap, SettingsDirty
    if !SettingsDirty
        return
    txt := BuildSettingsText(SettingsMap)      ; ヘッダコメント込みで全文生成
    path := A_ScriptDir . "\settings.ini"
    tmp  := path . ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8-RAW")   ; RAW = BOMを書かない指定。実測論争ごと無効化
        f.Write(txt), f.Close()
        ; 原子的置換: FileDelete→FileAppendの「全損の窓」を閉じる
        if !DllCall("MoveFileExW", "WStr", tmp, "WStr", path
                  , "UInt", 0x1 | 0x8)          ; REPLACE_EXISTING | WRITE_THROUGH
            throw OSError()
        SettingsDirty := false
    } catch {
        try FileDelete(tmp)
        Flash("設定の保存に失敗しました(次の変更時に再試行します)", 2000)
    }
}

SetSetting(key, val) {
    global SettingsMap, SettingsDirty, SettingDefs
    SettingsMap[key] := val
    if SettingDefs[key].HasProp("apply")
        SettingDefs[key].apply(val)             ; グローバル変数へ即時反映(監視等は次tickから新値)
    SettingsDirty := true
    SetTimer(FlushSettings, -300)               ; 連打をまとめる。負値=1回きり
}
```

- **排他ロック**: `#SingleInstance Force` + AHKのシングルスレッド実行モデルにより、プロセス内競合は「デバウンスタイマー vs UIイベント」だけで、どちらも同一スレッド上で直列化される(AHKの擬似スレッドは割込みだが`FlushSettings`内は数十行・ファイルI/Oは1回)。念のため`FlushSettings`先頭に`Critical "On"`を置けば割込みも遮断できる。**ファイルロックAPIやミューテックスは導入しない** — 会議の「排他ロック必須」は多プロセス前提の一般論で、本アプリは単一インスタンス保証済み。外部エディタとの競合は「settings.iniは手で編集しないでください」をヘッダに明記+全文再生成(手編集は上書きされる仕様)で解消する。ハッシュ比較リトライは不採用(F節)。
- **非同期化**: 会議の「タイマー/キューで非同期化」は、実測規模(settings.ini < 1KB、書込み1ms未満)に対して過剰。**300msデバウンス+OnExitでの最終Flush**だけで「UIスレッドをブロックしない」要件は満たされる。書き込みキューは作らない。
- **読み込み側の防御**: 起動時ロードで先頭3バイトが`EF BB BF`ならスキップして読む(過去に生成されたBOM付きファイルの後方互換。1行で済む)。

### C-3. GUI(SettingsWindow)の実装方式

- 現行`ShowSettingsWindow`(L1587-1616)を拡張する形で、`Gui.Add("Tab3", , ["基本", "高度"])`。**高度タブはadvancedmode=0のときタブごと作らない**(コントロールのVisible切替でなくGui再構築: シングルトンGuiをDestroy→再生成。設定画面は開閉頻度が低く再構築コストは体感ゼロ。Tab3への動的タブ追加のWin32メッセージ操作より確実)。
- 「上級者モードを有効にする」チェックはタブの外(ウィンドウ最下部)に置く。ONにした瞬間`SetSetting("advancedmode",1)` → Gui再構築 → 高度タブが現れる。初心者が「高度」を誤って開く経路は存在しなくなる。
- 全コントロールは`OnEvent("Click"/"Change", ...)` → `SetSetting`直結。**保存/OK/キャンセルボタンなし**。破壊的・危険な項目(フォルダ保存ON)だけ現行どおり確認MsgBox(L1620-1641の流儀)。AHK v2のMsgBoxは他の擬似スレッド(OnClipboardChange・ホットキー)を止めないので常駐動作と両立する。
- 数値系(longpress等)はEdit+UpDownではなく**DropDownListで妥当値のみ提示**(0.25/0.35/0.5/0.75秒など)。自由入力のバリデーション実装を丸ごと省け、壊れた値がファイルに入る経路も消える。

### C-4. Migrator(起動時1回)

```
起動 → settings.ini 存在? ──Yes→ 通常ロード
        └No→ ① sites.ini があれば sites.ini.bak-YYYYMMDD としてコピー(バックアップ)
              ② LoadSitesConfig を現行ロジックのまま実行(=現在の有効値がグローバルに載る)
              ③ startup-prompted.flag 存在 → firstrunprompted=1
              ④ グローバル変数の現在値から settings.ini を初回生成(C-2の書き出し経路)
              ⑤ sites.ini 冒頭に案内コメント1行を挿入(この1回だけ・原子的書き出しで)
              ⑥ flagファイル削除
```

移行に失敗したら`settings.ini`を作らず現行動作のまま継続(fail-closed: 移行の失敗が機能停止にならない)。

## D. トレイメニューと設定ウィンドウの役割分担

**原則: トレイ=「今この瞬間の即応操作」、設定ウィンドウ=「状態を変える操作すべて」。**

| 項目 | 行き先 | 理由 |
|---|---|---|
| クリップボード監視を一時停止 | **トレイに残す**(+設定ウィンドウにも同じトグル) | パスワード操作直前の即応。2クリック以内が生命線 |
| クリップボード履歴を全削除 | **トレイに残す** | パニックボタン。深い階層に置かない |
| 定型文の管理... | **トレイに残す** | 上級者の高頻度実務導線(会議の却下理由と同じ) |
| 設定... | **トレイに残す**(入口) | — |
| 診断情報をコピー | **トレイに残す** | 設定ウィンドウ自体が壊れたときの脱出口。窓に依存させない |
| Windows起動時に自動実行 | 設定ウィンドウ基本タブへ**移動** | 状態変更であり即応性不要。HANDOFF合意済み項目 |
| 定型文ファイルを編集(snippets.ini) | 高度タブへ**移動** | 生ini導線は残すが上級者モード配下へ |
| 設定フォルダを開く | 高度タブへ**移動** | 同上 |

結果のトレイ: **一時停止 / 履歴全削除 / 定型文の管理... / 設定... / 診断情報をコピー / v表示 / 終了** の7項目。会議の「3項目まで削減」案は不採用(F節)。

設定ウィンドウ最終形:
- **基本タブ**: 自動起動 / クリップボード監視 / フォルダ保存(画像) / フォルダ保存(テキスト) / 保存フォルダを開くボタン
- **高度タブ**(上級者モード時のみ): 長押し閾値DDL / 履歴件数DDL / 自動クリア秒DDL / 除外exe(Edit) / 保存先フォルダ変更 / ルールを再読込 / sites.ini・snippets.ini編集・フォルダを開くボタン群

## E. MVP(最初の1歩)

**「SettingsStore + Migrator + 現行設定ウィンドウへのトグル2個追加」だけを1コミットで。タブはまだ作らない。**

1. C-2の書き出し機構(全文再生成・UTF-8-RAW・原子リネーム・デバウンス)とsettings.iniロードを実装。
2. Migrator(C-4)。`SaveIniKey`(L1431)を削除し、`ApplyArchiveToggle`(L1635/1638)の呼び先を`SetSetting`に差し替え。
3. 現行`ShowSettingsWindow`に「Windows起動時に自動実行」「クリップボード監視」の2チェックボックスを追加(HANDOFF:52で既に合意済みの最小要望そのもの)。トレイの自動起動トグルを削除。

これで「一元管理」要望・セクション混入バグ・BOM論争・全損の窓、の4つが1歩で消える。タブ/上級者モード/高度項目は第2歩(GUI再構築パターンの追加のみ、ストアは無変更)。

## F. 捨てた案とその理由

| 捨てた案 | 理由 |
|---|---|
| 初回起動ウィザード | 既定値で完結するアプリに選択を迫るのは「何も考えずに使える」の逆行。現行MsgBox 1個で足りている |
| 初回サイレント自動検出(履歴からデフォルト推定) | 会議自身が「過剰設計気味」と認定。監視対象の推定ミスは誤送信リスクに直結し、fail-closed原則に反する |
| トレイ3項目化 | 履歴全削除・診断コピーは「窓が開けない/開く暇がない」状況の脱出口。削ると事故時の導線が消える |
| 生ini編集導線の完全隠蔽(会議内の少数意見) | 会議の却下どおり。加えて本製品はsites.iniのコメント自体がドキュメントとして機能しており、開かせない設計は自己矛盾 |
| ハッシュ比較+競合検出リトライ | settings.iniをプログラム専有にした時点で競合の主因(人間の手編集との衝突)が消える。残るプロセス内競合は単一スレッドモデルが解決済み |
| 書き込みキュー/ロックデーモンによる非同期化 | 1KB未満のファイルに対する1ms未満のI/O。デバウンス1個で足りる。キューは新しいバグの置き場になるだけ |
| sites.ini 1ファイルに全部残しつつ「コメント保存型の賢いINIライタ」を書く | 混入バグの根本原因(人間の文書構造をプログラムが推測して手術する)を温存する。所有権分離の方が実装量も少ない |
| OnChangeイベントバス(pub/sub) | 十数項目・購読者は事実上1個ずつ。静的Mapのapplyfn直呼びで同じ結果 |
| ファイル監視(ReadDirectoryChanges)でのsites.ini自動リロード | 常駐プロセスに監視ループを1本増やす価値がない。高度タブの「再読込」ボタン+次回起動反映で十分 |

## G. 地雷と回避策(1対1)

1. **archiveimage/archivetextの別セクション直前混入(`SaveIniKey` L1431-1455)**
   → 実地確認の結果、現物(sites.ini 34-35行)は文法上`[clipboard]`内だが空行の後ろに落ちて人間には誤読される状態。回避策は「書き方の修正」ではなく**`SaveIniKey`の廃止**: プログラムが書く値はすべて`settings.ini`(全文再生成)へ移し、`sites.ini`への文字列手術コードパス自体を削除する。挿入位置バグはコードごと消滅。既存の混入値はMigratorが有効値として`settings.ini`へ引き継ぐ(HANDOFF:49「無断削除しない」を充足 — 削除せず無視する)。

2. **BOM問題(コメントの主張と実測の矛盾・`refactor-instructions.md` Q4)**
   → 2026-07-17に司令塔が実測検証済み(上記追記参照)。「`FileAppend`/`FileOpen(w,UTF-8)`は新規作成時BOM付き」が事実、コード内コメントが誤り。**新設する`settings.ini`のみ**`FileOpen(..., "w", "UTF-8-RAW")`で新規作成し構造的にBOMを回避する。読み込み側は先頭`EF BB BF`を無条件スキップ(過去に生成された可能性のあるBOM付きファイルの後方互換)。`sites.ini`/`snippets.ini`への既存書き込み経路は`refactor-instructions.md`の絶対制約どおり`FileDelete`+`FileAppend(...,"UTF-8")`のまま変更しない — この実測結果は`refactor-instructions.md`のQ4/D5にもそのまま転記できる。

3. **設定画面を開いている間も監視・ホットキーが動き続ける必要**
   → 非モーダルGui+シングルトン+Hide(現行SnipMgr/Settings両ウィンドウの既存パターンを踏襲、新規発明なし)。書き込みはデバウンス済み同期I/O(1ms級)でメインループを実質ブロックしない。確認ダイアログはAHK v2のMsgBox(擬似スレッドをブロックしない)のみ。Gui再構築(上級者モード切替)も数十ms・ユーザー操作起点なので監視への影響なし。

4. **`refactor-instructions.md`の未回答Q1〜Q6との矛盾リスク**
   → 本設計が依拠する事実はすべて行番号付きで正本ソースから直接確認済み(SaveIniKey実装・sites.ini現物・スタートアップ判定方式・設定ウィンドウの流儀)。`refactor-instructions.md`の記述と食い違う場合は正本ソース側を正とする。Q4(BOM)は上記2で構造解消、Q以外の残項目は本設計に影響しない限り司令塔側の裏取りに委ねる。

5. **(実地調査で追加発見)FileDelete→FileAppendの間でクラッシュするとsites.ini全損**
   → tmpファイル書き→`MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)`の原子的置換に統一(C-2)。加えてMigratorが移行時に日付付きバックアップを残すため、最悪時も復元点がある。

---

**実装規模の見積もり**: MVP(E節)は正味+120〜150行/-40行(SaveIniKey・flag処理削除)程度で、既存の流儀(シングルトンGui・Flash・fail-closedコメント文化)の内側に収まる。新規の依存・DLL・常駐ループの追加はゼロ。

## 会議ハーネスで集めた素材(参考・要約)

召集5体(groq/gpt-oss-120b, nvidia/mistral-large-3-675b[FAILED], groq/qwen3.6-27b, groq/llama-3.3-70b, groq/qwen3-32b)、成功5/6(統合含む)。

- **合意**: 全設定を単一ウィンドウ+基本/高度タブに統合。高度タブはデフォルト非表示、チェックボックスで顕在化。
- **却下された少数意見**: 「生ファイル編集導線を完全に隠す」(llama-3.3-70b) — 上級者のスニペット編集速度を損なうため。
- **合意**: ini書き込みは排他ロック+UTF-8無BOMの二層防御。ただしFableの設計では単一インスタンス保証を根拠にロックを不要と判断(上記G節参照、会議の一般論より実態に即して具体化)。
