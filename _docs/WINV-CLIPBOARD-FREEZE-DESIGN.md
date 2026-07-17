# Win+Vクリップボード無反応問題 — 診断主導の設計書

> **横断課題の注記**: この課題はsoushin-suggest.link単体の話ではなく、`reply-copilot-openrouter-v2`(Chrome拡張)とWindows OS自体も容疑者に含む横断調査。正本はここ(soushin-suggest.link/_docs/)に置くが、対象は3者。
>
> 作成経緯: council-fableスキル(3段構え: 会議ハーネス→Fable設計→実装は次セッション)。会議ハーネスが提示した具体的数値(30回/秒、Event ID 3000/3001等)は司令塔Claudeが個別にWeb再検索し、裏付けなしの幻覚と判定して除外済み。

## 0. スタンスの宣言

実測データがゼロの現時点で「原因はAである」と確定する設計は行わない。本設計書の主軸は**最小コストで再現条件を3分岐(拡張/AHK/OS)のどれかに絞り込む診断計画**であり、恒久対策は「分岐ごとの型」までに留める。

## 1. 診断の前に確定できた構造的事実(コード実読・環境実測ベース)

**(a) 本機のOSビルドは 10.0.26200 = Windows 11 25H2。** 25H2は24H2(26100)と同一のGermaniumコードベースに対する有効化パッケージであり、**「24H2にクリップボード履歴が固まる既知バグ」という裏取り済み事実は本機にそのまま適用されうる**。OS犯人説は最後まで生きた仮説として扱うこと。

**(b) AHK側の`ClipChanged`ハンドラ自体は安全に書かれている**(`dist/soushin-suggest.ahk` 1213-1239行)。ハンドラ内ではクリップボードを開かない。`ClipHasIgnoreFormat()`は`IsClipboardFormatAvailable`のみで判定でき、実装もその通り。重い処理はすべて`SetTimer(-120)`で切り離されている。

**(c) 「ClipWatchOn OFF」はリスナー解除ではない。** `OnClipboardChange(ClipChanged)`の登録は常に生きており、トレイの監視OFFはハンドラ内の早期returnにすぎない。**A/Bテストで「AHK OFF」条件を作るときは、トレイの監視OFFでは不十分。スクリプト完全終了が必須**。

**(d) AHKが実際にクリップボードを「開いて保持する」瞬間は限定的に4箇所。**
- `CaptureClip`の`try text := A_Clipboard`(1256行) — 変更の120ms後に読む。遅延レンダリング元への`WM_RENDERFORMAT`要求を含みうる
- `GetClipDib`(1280-1297行) — 開いて最大36MBをコピー。`finally`で必ず閉じる
- `SetClipboardImage`と`PasteText`経由の`A_Clipboard :=`(1204行) — 書き込み

**(e) Chrome拡張側はOSフックなし・ユーザー操作起点のみ。** ただし`content/clipboard-monitor.js`の`copy`イベントリスナーは**コピー操作の途中に同期実行される**。リスナーが重ければChromeのクリップボード書き込み自体が遅延しうる。現実装は軽い(storage保存のみ)が、これは拡張が唯一OSクリップボードのタイミングに影響を与えられる経路。

**(f) 症状の切り分け上の重要な区別**: 「Win+Vパネルが開かない」は、(1) UIホスト(explorer側)の問題、(2) `cbdhsvc`(実体サービス)の問題、の2層がありうる。explorer再起動で直った実績はUI層、PC再起動が必要だったケースはサービス層を示唆する。**発生時にどちらだったかを毎回記録する**こと自体が診断データになる。

## 1.5 実証拠(`_docs/winv-ab-test-log.md`に全件記録)

**2件連続で発生・記録済み(2026-07-17 19:57、21:58)。** 両方とも:
- `clip-incident.ps1`の`GetOpenClipboardWindow`は「誰も掴んでいない」(保持ロック型ではない)
- `cbdhsvc`はRunning状態(サービス自体はクラッシュしていない)。Applicationログにもエラーなし
- **`Get-Service cbdhsvc* | Restart-Service -Force`は「サービスを開けません」という権限エラーで失敗**
  (per-userサービスは通常のユーザー権限では停止できない。管理者PowerShellでも同じエラーだった)
- **`Stop-Process -Name explorer -Force`で直った**(2件とも)

1件目はsoushin-suggestが`not running`、2件目は`running`の状態でそれぞれ発生。

この2件から言えること:
1. **AHK(soushin-suggest)の有無に関わらず発生する** → AHK側の関与は薄いと見てよい方向に証拠が
   積み上がっている。ただし決定的な棄却ではなく、A/Bテストの継続で頻度差を見ることが引き続き有効
2. **cbdhsvc再起動は2件とも権限エラーで実行不能、explorer再起動は2件とも成功** → §1(f)で想定した
   2層のうち、**cbdhsvc本体ではなくExplorerシェル(UIホスト)側**に障害がある、という見立てが
   一貫して裏付けられている。実用上は最初からexplorer再起動を試す方が速い(§2で反映)
3. 2件目では発生直前(21:22台)にChromeプロセスが複数同時起動した形跡があった
   (拡張のservice worker再起動かタブ大量リロードの可能性。件数が増えたら要継続観察)

## 2. 今すぐできる応急運用(原因特定と無関係に運用可能)

発生したら以下のエスカレーションで復旧する。**ただし§3 Phase 2の証拠採取を先に実行してから**復旧すること。

1. **explorer再起動**(管理者PowerShell): `Stop-Process -Name explorer -Force`(通常は自動再起動)。
   実証拠2件とも、これで直っている(§1.5参照)。まずこれを試すのが最速
2. それでもだめならPC再起動

参考: `Get-Service cbdhsvc* | Restart-Service -Force`は理論上の選択肢として設計時に想定していたが、
実証拠2件とも「サービスを開けません」という権限エラーで実行できなかった(per-userサービスは
管理者PowerShellでも通常操作を拒否される)。優先度を下げ、上記の手順からは外した。

補足: Win+Vが死んでいても通常のCtrl+C/Vは大抵生きている。soushin-suggest自身がクリップボード履歴UIを持っているので、業務継続の観点ではWin+V死亡は即致命ではない。焦らず証拠採取を優先できる。

## 3. 診断計画(本設計の主軸)

### Phase 0: 事前準備 — 「発生時証拠採取キット」

**実装済み・動作確認済み(2026-07-17)。** `C:\Users\info\OneDrive\デスクトップ\clip-incident.ps1` に配置。正常時に1回実行し、全セクションが期待通り出力されることを確認済み(cbdhsvc生存確認、GetOpenClipboardWindowの正常判定、A/Bテスト用プロセス一覧まで動作)。

**地雷**: 当初は日本語コメント入りで書いたところ、PowerShellがコンソール実行時にShift-JISと誤読し構文エラーで壊れた(CLAUDE.mdに記載の既知の地雷と同型)。**このファイルはコメント・文字列とも英語のみ**にして解決済み。今後このスクリプトを編集する際も日本語を混ぜないこと。

使い方: Win+Vが反応しなくなったら、復旧作業より先に管理者PowerShellで実行する:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\info\OneDrive\デスクトップ\clip-incident.ps1"
```

仕様(実装済みの内容):

```powershell
# clip-incident.ps1 — Win+V無反応の瞬間に実行する証拠採取
# 出力はデスクトップの clip-incident-<日時>.txt に追記

# 1) 今クリップボードを開きっぱなしにしているプロセスの特定(最重要)
Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
'@
$h = [W.U]::GetOpenClipboardWindow()
if ($h -ne [IntPtr]::Zero) {
    $procId = 0; [W.U]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
    Get-Process -Id $procId | Select-Object Name, Id, Path   # ← 犯人の名前が出る
} else { "クリップボードを開いているプロセス: なし" }
"シーケンス番号: $([W.U]::GetClipboardSequenceNumber())"

# 2) cbdhsvcの生死
Get-CimInstance Win32_Service -Filter "Name like 'cbdhsvc%'" | Select-Object Name, State, ProcessId

# 3) 直近30分のクラッシュ痕跡(特定のEvent IDは前提にしない。時間窓で見る)
Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddMinutes(-30)} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Application Error|Windows Error Reporting' -or $_.Message -match 'cbdhsvc|svchost' } |
    Format-List TimeCreated, ProviderName, Message

# 4) 履歴設定が勝手にOFFになっていないか
Get-ItemProperty HKCU:\Software\Microsoft\Clipboard -ErrorAction SilentlyContinue
```

このキットの核心は**(1)の`GetOpenClipboardWindow`**。「誰かがクリップボードを開いたまま固まっている」型の障害なら、犯人のプロセス名(chrome.exe / AutoHotkey64.exe / svchost / その他)が一発で出る。何も出なければ「保持ロック型ではない=cbdhsvc内部の問題」の方向に証拠が傾く。ProcMonより先にこれ。

あわせて開始時点の環境を1回だけ記録: `Get-ComputerInfo -Property OsName, OsBuildNumber` / `Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5`

### Phase 1: A/B切り分けマトリクス(1〜2週間、普段の作業のまま)

観測単位=普段どおりの作業1日。1日数回(朝・昼・夕・作業の節目)Win+Vを押して開くか確認、結果を表に1行記録する。

| 条件 | Chrome拡張 | soushin-suggest | 正しいON/OFF手順 |
|---|---|---|---|
| A(現状) | ON | ON | ベースライン。まず再現頻度を知る |
| B | **OFF** | ON | `chrome://extensions`でトグルOFF(Chromeを閉じるだけでは不可) |
| C | ON | **OFF** | **トレイから完全終了**(§1(c))。タスクマネージャでAutoHotkeyプロセス消滅を確認 |
| D | OFF | OFF | 対照群 |

運用ルール:
- 条件Aから始める。ベースラインの再現間隔が分からないと、B〜Dで「再現しない」の判定基準が作れない
- 各条件はベースライン再現間隔の2〜3倍続けてから「この条件では出ない」と仮判定する
- 発生したら即`clip-incident.ps1`実行→記録→§2で復旧→同じ条件を継続
- 判定表: Bで出ない+Cで出る→拡張が濃厚。Bで出る+Cで出ない→AHKが濃厚。B・C両方で出ない+Aで出る→**同時実行時のみの競合**。Dでも出る→OS(25H2)側
- **1件目の実証拠(1.5節)は条件Bに近い状態(拡張ON・AHK停止中)での自然発生**。これ単独では「AHK不要でも起きる」ことしか言えず、まだCでも出るか(=AHKがあってもなくても同頻度か)の比較材料がない。件数を積み重ねて頻度差を見ること
- 余裕があれば条件C'として「soushin-suggestの代わりにClibor+拡張ON」を挟む。C'で出ずCで出るなら、AHK実装固有の何かに絞れる

### Phase 2: 発生した瞬間のチェックリスト(復旧より先に、5分)

1. `clip-incident.ps1`を実行(管理者PowerShell推奨)
2. **soushin-suggestが生きている条件下なら、トレイの「診断情報をコピー」(`CopyDiagnostics`)を実行**してAIチャットに貼る。Win+Vが死んでいても通常コピーは大抵生きているので取得可能。`ClipDiag`カウンター(selfSuppress / evtText / capText / rejUserText等の回数と最終時刻)は「直前にAHKが何をしていたか」の一次証拠になる
3. 直前1〜2分に何をしていたかをメモ(何をコピーした? 画像? Chrome内? RDP?)
4. §2のエスカレーションで復旧し、**どの段階で直ったか**(cbdhsvc再起動/explorer再起動/PC再起動)を記録

### Phase 3: Phase 1-2で絞れない場合のみ — 常駐センチネル

再現が稀すぎて発生時採取が間に合わない場合の追加手段。別プロセスの極小AHK v2スクリプトで、5秒ごとに以下をCSVへ追記する:
- `GetClipboardSequenceNumber()`
- `GetOpenClipboardWindow()`のowner(pid/プロセス名。通常は空)
- cbdhsvcホストプロセスの生死

設計上の要点: **センチネル自身は絶対に`OpenClipboard`しない**(上記3つはどれも開かずに読める)。

なお会議で挙がったProcess Monitorは**クリップボードAPI呼び出しを記録できない**(ファイル/レジストリ/プロセスのみ)ため、本件では優先度を下げる。使うとしてもcbdhsvcホストのクラッシュ・再起動痕跡の確認用に限定。

## 4. 診断結果ごとの対処方針(「型」まで)

### 4-A. Chrome拡張側と判明した場合
- まず条件Bの変種「拡張OFFだがChromeは通常使用」で出ないことを再確認し、Chrome本体ではなく拡張であることを固める
- 対処の型: (1) `copy`イベントリスナー内の処理を最小化し、実作業を非同期化。(2) `navigator.clipboard.read/write`にリトライ・失敗許容を入れ、失敗時は諦める(fail-closed)。(3) Edgeで再現しないか試し、Chromiumチャネル差の情報を集める

### 4-B. AHK(soushin-suggest)側と判明した場合
- 対処の型: (1) クリップボード保持時間の短縮・一本化 — `CaptureClip`の`A_Clipboard`読みと`GetClipDib`の36MBコピー。(2) デバウンス120msの再設計 — **実測(Phase 3のタイムライン)を根拠に**間隔をずらす/設定化する。今の時点で数値を決め打ちしない。(3) テキスト/画像タイマーの直列化
- 修正後は同じPhase 1マトリクスで回帰確認

### 4-C. Windows OS側(条件Dでも発生)と判明した場合
- 対処の型: (1) `Get-HotFix`の記録とWindows Update追跡。(2) Feedback Hubへの報告。(3) 運用回避 — Win+V履歴を諦めてsoushin-suggestを履歴UIの正とする

## 5. AHK側で特に注視すべき箇所

[[ahk-drag-race-condition-pattern]](同期ループ+別所でのGUI破棄=クラッシュ)の教訓に照らして実コードを精査した結果:

1. **`CaptureClip` 1256行 `try text := A_Clipboard`** — 最重要。クリップボードを開き、コピー元が遅延レンダリングなら`WM_RENDERFORMAT`で元アプリ(Chrome等)の応答を待つ。`#ClipboardTimeout`指定なし=既定1秒。「AHKが開いて待つ ⇔ Chromeがレンダリングで詰まる ⇔ cbdhsvcが読めない」の三者絡みが起きるとしたらここ。
2. **`ClipOpen` 1272-1276行の`Loop 5 { ... Sleep 20 }`** — Sleepで擬似スレッドが割り込み可能になり、他のタイマーが同時進行しうる。Sleep境界前後でグローバル状態の再検証がない。現状は実害未確認だが、テキスト+画像の連続コピー時に交錯する窓がある。
3. **`GetClipDib` 1290-1291行** — 最大36MBの`RtlMoveMemory`をクリップボードを開いたまま実行。`finally`で閉じる実装は正しい(閉じ忘れ型の事故はない)。
4. **良い点として記録**: ハンドラ本体の軽量性、fail-closed設計、`SelfClipTick`の書き込み前セット、画像ハンドル寿命の扱いはいずれも健全。「AHKが構造的に無実」という意味ではなく「疑うなら上記1〜3の保持時間」という絞り込みとして使うこと。

## 6. やらないことリスト(明示)

- 幻覚数値(30回/秒、Event ID 3000/3001、100ms/5秒閾値)を根拠にしたコード修正
- 実測前の「頻度をXms以下に」式の数値入り恒久対策
- Cliborの内部実装の推測に基づく設計(対照群としての利用のみ)
- ProcMonを第一手にすること(クリップボードAPIは映らない)

---

## 次のチャットへの引き継ぎ用ハンドオフ

**課題**: Win+V無反応の原因切り分け。犯人候補は Chrome拡張(reply-copilot-openrouter-v2) / AHK常駐(soushin-suggest) / OS(本機はbuild 26200=25H2、24H2既知バグを引き継ぎうる) の3つ。断定禁止、診断先行。

**最初にやること(順番厳守)**:
1. `clip-incident.ps1`を本設計書§3 Phase 0の仕様どおりデスクトップに実装(核心は`GetOpenClipboardWindow`で犯人プロセス名を採る部分)。動作確認は正常時に1回実行して出力が読めることまで。
2. ユーザーにA/Bマトリクス(§3 Phase 1)の運用を開始してもらう。条件Aから。**「AHK OFF」はトレイの監視OFFでは無効、スクリプト完全終了が必須**(OnClipboardChange登録は監視OFFでも生きている — dist/soushin-suggest.ahk 2316行)。
3. 発生したら: 復旧より先にclip-incident.ps1実行→soushin-suggestトレイの「診断情報をコピー」→直前操作メモ→cbdhsvc再起動→explorer再起動→PC再起動の順で試し**どこで直ったかを記録**。

**禁止事項**: Event ID 3000/3001・30回/秒・100ms/5秒等の数値は全て幻覚と判定済み。使わない。実測前の数値入りコード修正もしない。

**判定表**: 拡張OFFで消える→4-A(copyリスナー非同期化の型)。AHK終了で消える→4-B(注視点はCaptureClip 1256行のA_Clipboard読み・ClipOpen 1272行のSleepループ・GetClipDibの保持時間)。両方OFFでも出る→4-C(OS。Win+Vを諦めsoushin-suggestを履歴の正とする運用回避が現実解)。

**関連コード**: `dist/soushin-suggest.ahk`(ClipChanged系は1211-1384行、診断カウンターは55-79行)、拡張は`reply-copilot-openrouter-v2/content/clipboard-monitor.js`ほか。
