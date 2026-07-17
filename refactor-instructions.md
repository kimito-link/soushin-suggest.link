# refactor-instructions.md — soushin-suggest.link リファクタリング指示書

> 作成: 2026-07-16 / 分析担当: Claude (Fable 5)
> 渡し方: 「/goal refactor-instructions.md に書かれたことを完遂しろ」
> 対象リポジトリ: `C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link`
> 現在ブランチ: `feature/clipboard-history-archive`

---

## 0. Objective

**既存仕様(特に安全設計)を1ミリも壊さずに**、`dist/soushin-suggest.ahk`(AutoHotkey v2・単一ファイル常駐スクリプト・1714行)の技術的負債を減らし、今後の機能追加で事故が起きにくい状態にする。

これは「全部書き直す」計画ではない。このコードは意図的な設計判断(単一ファイル配布・fail-closed・行単位ini書き換え等)の集積であり、コメントに設計理由が濃密に書かれている。**見た目の綺麗さのための変更は一切しない。** やるのは以下だけ:

1. 未コミット変更の安全な整理(機密データ混入の防止を含む)
2. 重要挙動への自動検証(プローブ)の追加 — 既存の `scripts/verify-*.ps1` パターンの拡張
3. 証拠のある小さな重複の除去と定数化
4. コードコメントと実挙動の食い違い(BOM問題)の実測検証と是正
5. それ以上の設計変更は**提案のみ**(実装しない)

---

## 1. Project Understanding

### 1.1 これは何か

「君斗りんくの送信サジェスト」— ¥980買い切りのWindows常駐ツール(AutoHotkey v2)。なぞってコピー・右クリック長押し送信・サイドボタンスクショ/クイックペーストランチャー・クリップボード履歴(テキスト+画像サムネイル)・定型文管理・Cliborインポート・オプトインのフォルダ保存を提供する。

### 1.2 リポジトリ構成(実測)

| パス | 役割 |
|---|---|
| `dist/soushin-suggest.ahk` | **唯一の実装ファイル**(ソース兼配布物。1714行) |
| `dist/sites.ini` | 送信ルール設定(許可リストの実体)。UTF-8・BOMなし・日本語キーあり |
| `dist/snippets.ini` | 定型文(**ユーザーデータ。実行中のアプリが書き換える**。git追跡中 — 後述の地雷) |
| `dist/README.txt` | 同梱README(zip配布物) |
| `scripts/build.ps1` | Ahk2Exeコンパイル+zip梱包。`-Version` 必須 |
| `scripts/verify-clip-filter.ps1` | セキュリティプローブ(注入クリップボード拒否/ユーザーコピー受理の自動検証) |
| `scripts/verify-numkey-hotif.ahk` | 数字キーHotIfスコープの残留フック検証 |
| `index.html` | LP(Cloudflare Pages。668KB単一ファイル・base64画像インライン) |
| `functions/api/stripe-webhook.ts` | Stripe checkout完了→Resendでダウンロードメール送信 |
| `_docs/*.md` | 設計書・実装ハンドオフ・**判定基準(`CLIBOR-PARITY-JUDGMENT.md`)** |
| `HANDOFF-next-session.md` | セッション引き継ぎ(gitignore済・一部情報は古い: Cliborインポートは実装済) |

### 1.3 データフロー(要点)

- **履歴**: `OnClipboardChange(ClipChanged)` → デバウンス → `CaptureClip`/`CaptureClipImage`(**直近1秒のユーザー操作がなければ捨てる fail-closedフィルタ** + パスワードマネージャ除外) → `PushClipHistory`/`PushClipImage`(メモリ配列 `ClipHistory`、上限30件/画像5件)
- **フォルダ保存(オプトインのみ)**: テキストは `QueueTextArchive` → 検疫(`ClipAutoClearSec`+2秒待ち) → `CommitPendingArchive` がCSV追記。自動クリア検知(`MaybeDropAutoCleared`)で履歴と検疫キューの両方から即削除。画像は即PNG保存
- **定型文**: `snippets.ini`(1定型文=1行、`\n`エスケープ)。GUI編集は `SnipMgrWriteLine` の**行番号+ラベル検証つき行単位書き換え**(外部編集との競合をfail-closedで検出)
- **送信**: `CurrentSendMode()` = `[sites]`タイトルキーワード > プロセス名既定 > 空。誤判定は必ず「manual案内」側に倒れる設計
- **販売**: LP → Stripe Payment Link → `stripe-webhook.ts` → Resendメール(GitHub ReleasesのzipURL)

### 1.4 検証コマンド(現状)

テストフレームワーク・lint・CIは**存在しない**。あるのは:

```powershell
# 構文チェック(コンパイルより速い)
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /validate "dist\soushin-suggest.ahk"

# ビルド(コンパイル成功=最低限の健全性)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Version 1.11.0

# セキュリティプローブ(※副作用あり: 実行中のsoushin/AutoHotkeyプロセスをkillし、実クリップボードを書き換える)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-clip-filter.ps1

# 数字キー残留フックプローブ
& "C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link\scripts\verify-numkey-hotif.ahk" 相当を
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" scripts\verify-numkey-hotif.ahk で実行(exit 0=PASS)

# Cloudflare Functions型チェック
npx tsc --noEmit
```

**Windows注意(build.ps1冒頭コメントより)**: PowerShellスクリプトは必ず `powershell -File` で呼ぶ。Git Bashのインライン `-Command` 経由はMSYSパス変換で壊れる。日本語パスは常に引用符で囲む。

---

## 2. Behaviors To Preserve(絶対に壊してはいけない既存挙動)

1. **許可リスト方式**: 送信・自動操作(Enter送信・貼り付け)は `sites.ini` 登録アプリのみで動く。`CurrentSendMode` の誤判定は「manual案内ToolTip」にしか倒れない
2. **非永続原則(改定版)**: 履歴はメモリのみが既定。ディスク書き出しは (a)項目単位の明示操作(定型文昇格) か (b)既定OFF・警告つきオプトイン+検疫つきフォルダ保存 のみ
3. **ユーザー操作限定フィルタ**: 直近1秒(`ClipUserWindowMs`)のユーザーコピー操作がないクリップボード変化は履歴に入らない(`scripts/verify-clip-filter.ps1` が検証している挙動)
4. **検疫(遅延コミット)**: テキストのフォルダ保存は `ClipAutoClearSec+2秒` 待ち。その間の自動クリアはメモリとディスク予約の両方を取り消す。終了時は検疫中項目を書かずに捨てる(fail-closed)
5. **パスワードマネージャ除外**: `Clipboard Viewer Ignore` / `ExcludeClipboardContentFromMonitorProcessing` フォーマットと `ClipExcludeExes` の除外
6. **snippets.iniの不変条件**: 1定型文=1行。`SnipMgrWriteLine` のラベル検証つき行単位書き換え(全文書き直し禁止)。ListViewの `NoSort NoSortHdr` は行番号↔配列対応の生命線
7. **`LVS_SHAREIMAGELISTS`(+0x40)と `RebuildHistThumbILIfBloated` の再アサイン→破棄の順序**: 外すと共有ImageListが道連れ破壊される
8. **IniRead/IniWrite不使用の掟**: 非ASCIIキー誤読の既知の罠のため、独自パーサ+`FileDelete`+`FileAppend`で統一されている
9. **履歴からのファイル実行の防御**: `RunnablePathFrom` はローカル絶対パスのみ(UNC/相対/複数行は拒否)、実行形式は確認ダイアログ必須
10. **ランチャーのドラッグ中破棄ガード**: `LauncherWatchDrag` のループ内 `IsObject` チェック(過去に実クラッシュした race。メモリ `feedback_ahk_drag_race_condition` 参照)
11. **既存のUI動線**: ランチャーは毎回カーソル位置に開く(Clibor流)、数字キー1-9,0選択、ホバー全文ToolTip、右クリックメニュー
12. **ClipOpen/CloseClipboardの対**: 閉じ忘れはOS全体のコピペを止める。`finally` を崩さない

---

## 3. Non-Negotiables(作業上の絶対制約)

- **最初に `git status --short` を確認**し、結果を記録する
- **既存の未コミット変更(v1.11.0の4修正)と自分の変更を混ぜない**。Phase 0で整理が終わるまでリファクタに着手しない
- **`dist/snippets.ini` の現在のローカル内容(ユーザーの実業務定型文)を絶対にコミットしない。かつ `git checkout` 等で勝手に消さない**(実行中アプリのユーザーデータ。消すとデータ喪失)。同様に `clip-archive/`・CliborエクスポートCSV・その複製もコミット禁止
- 編集前にbaseline検証(§5)を実行し、結果を記録する
- 変更は小さく、1論点=1コミットで戻しやすく
- 無関係な整形・空白変更・コメントの「改善」・ついでのリファクタをしない。**既存の日本語設計コメントは消さない**(このコードの設計判断の正本)
- 既存挙動を勝手に変えない。正しさが不明なら実装を止めて質問する(§4)
- 各フェーズ完了ごとに§9の検証を実行する
- iniへの書き込みを新設する場合は既存の `FileDelete`+`FileAppend(...,"UTF-8")` 流儀に従う(`FileOpen(...,"w","UTF-8")` は禁止 — BOM問題の既知の地雷)
- テストに実データ(ユーザーのCSV・定型文・履歴)を使わない。プローブ用データは必ず合成する(過去に実データ混入でデータ流出防止機構が発動した事例あり)
- 新機能の追加は一切しない。機能要望らしきものに出会ったら `_docs/CLIBOR-PARITY-JUDGMENT.md` G節の4テストを参照しつつ、判断はユーザーに委ねる

---

## 4. Stop And Ask Conditions(実装を止めて質問する条件)

以下に該当したら、作業を止めてユーザーに質問すること:

1. `dist/snippets.ini` / `dist/sites.ini` / 保存済みユーザーデータの内容・形式に影響する変更(BOM正規化を含む)を、実測検証なしに行いたくなったとき
2. `functions/api/stripe-webhook.ts` に触る必要が出たとき(**課金・メール送信系。本指示書では調査のみ許可**)
3. `index.html`(LP)の訴求文言に触るとき(プロダクト判断。既知の懸案「許可リスト訴求と実態の乖離」はユーザー判断待ち)
4. テスト(プローブ)と実装の挙動が食い違ったとき — どちらが正かを勝手に決めない
5. 削除候補コード(例: 使われていないように見える関数)を見つけたとき — このファイルはホットキー・タイマー・コールバック経由の呼び出しが多く、静的な「未使用」判定は当てにならない
6. `scripts/build.ps1` の梱包内容(zipに入るファイル)を変えるとき(配布物互換に影響)
7. 互換性(既存ユーザーのsites.ini/snippets.iniがそのまま動くこと)を壊す可能性があるとき
8. §6の質問(Q1〜Q6)のうち未回答のものに依存する作業に着手するとき

---

## 5. Baseline Commands(着手前に実行し結果を記録)

```powershell
cd "C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link"
git status --short
git log --oneline -5
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /validate "dist\soushin-suggest.ahk"; echo "validate exit=$LASTEXITCODE"
npx tsc --noEmit
# 副作用に同意できる環境でのみ(実行中プロセスkill+クリップボード書換):
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-clip-filter.ps1
& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" scripts\verify-numkey-hotif.ahk; echo "numkey exit=$LASTEXITCODE"
```

期待値: validate exit=0 / tsc エラーなし / clip-filter は `OK Phase1 security probe` / numkey exit=0。
**この時点のgit statusには `dist/snippets.ini`・`dist/soushin-suggest.ahk`・`index.html` の3つの変更が既に存在するはず**(2026-07-16時点の未コミットv1.11.0作業)。これらは「自分の変更」ではないことを記録しておく。

---

## 6. 実装前に確認すべき質問(未回答のものはSTOP)

- **Q1. 未コミットのv1.11.0変更(`dist/soushin-suggest.ahk` + `index.html`)を先にコミットしてよいか?** 内容は4つの不具合修正(極小画像フィルタ・全体上限の間引き変更・SetImageListへのtry・クリック検知のCopyOnSelectApp限定)+メニュー並び替え+LP文言修正で、ビルド済み(v1.11.0)。リファクタはこのコミット後に始めるのが安全。
- **Q2. `dist/snippets.ini` の扱い。** 現在のローカル内容は実機テストのCliborインポートで入った**実業務の定型文**であり、コミットすると業務文面がpublicリポジトリ(GitHub Releases配布と同一リポ)に漏れる。かつ実行中アプリのユーザーデータなので `git checkout` で戻すとデータが消える。推奨は「ローカル内容を退避 → リポジトリ上はgit追跡から外す(またはデフォルト内容へ戻し `skip-worktree`)+build.ps1はデフォルトテンプレを梱包」だが、どれにするか決めてほしい。
- **Q3. `functions/api/stripe-webhook.ts` の `DOWNLOAD_URL` が v1.1.2 のzipに固定されている**(13行目)。製品はv1.11.0まで進んでいる。購入者に旧版が届くのは意図(安定版運用)か、更新漏れか? 更新するならGitHub Releasesに新版を上げるのとセットの作業になるため、本リファクタとは別トラックにすべき。
- **Q4. BOM正規化の方針。**【2026-07-17 実測により回答確定・2回の独立検証で再現】コード内コメント(`SaveIniKey`付近・HANDOFF)は「`FileDelete`+`FileAppend(...,"UTF-8")` はBOMなし」と主張していたが誤り。司令塔がAutoHotkey v2で(1)新規作成4パターン、(2)`SaveIniKey`と同一の`FileDelete`→`FileAppend(UTF-8)`パターンの2回にわたり実機検証し、いずれもBOM付きという同じ結果を得た:
  - `FileAppend(..., "UTF-8")`新規作成 → **BOM付き**
  - `FileOpen(..., "w", "UTF-8")`新規作成 → **BOM付き**
  - `FileOpen(..., "w", "UTF-8-RAW")`新規作成 → BOMなし
  - 既存ファイル(BOMなし)への`FileAppend(..., "UTF-8")`追記 → BOMは増えない(無害)
  - `SaveIniKey`と同一の`FileDelete`(既存削除)→`FileAppend(UTF-8)` → **BOM付き**(削除直後は新規作成扱いになるため)
  - 実運用ファイルの裏取り: `dist/sites.ini`はBOMなし(追記のみで運用)、`dist/snippets.ini`は**BOM付き**(SaveIniKey型の書き込みを経由したため)。実測とファイル実態が一致

  → **採用: (a)コメント修正のみ**。読み取り側(`FileRead`/L475の`RegExReplace(text, "^\x{FEFF}")`)がBOMを吸収しているため実害は確認されていない。書き込み経路変更(`UTF-8-RAW`統一・(b))は`sites.ini`/`snippets.ini`という人間所有ファイルの形式に触るため本リファクタでは見送り — §3の絶対制約(`FileOpen(...,"w","UTF-8")`禁止・既存の`FileDelete`+`FileAppend`流儀を維持)は実測後も変更なしで有効。Phase 2でSaveIniKey付近のコメントを本実測結果に修正済み。
- **Q5. LP(index.html)の「許可リスト方式による安全性」訴求文言の実態乖離**(グローバル監視・フォルダ保存導入後も旧訴求のまま。複数セッション持ち越し中)。本リファクタで直すか、別作業か。文言はプロダクト判断のため案の提示までとする。
- **Q6. `HANDOFF-next-session.md` は「Cliborインポート未実装」と書かれているが実装済み(コミット`d47f721`)。** gitignore済みファイルだが更新または削除してよいか(誤誘導防止)。

---

## 7. Debt Map(証拠つき負債一覧)

### D1. 未コミット変更とユーザーデータの混在【最優先・プロセス負債】
- **根拠**: `git status` → `dist/snippets.ini`(実業務データ) / `dist/soushin-suggest.ahk`(v1.11.0修正) / `index.html`(LP文言) が混在
- **なぜ負債か**: 「修正のコミット」をすると業務文面が漏れる構造。HANDOFFの地雷3(clip-archive混入未遂)と同型の事故が常態化するリスク
- **影響**: 機密漏洩(public配布リポ) / 変更履歴の汚染
- **リスク**: 対応自体は低リスクだが、`git checkout` を誤ると実行中アプリのユーザーデータ喪失
- **改善案**: Q1/Q2の回答に従い分離コミット+追跡方針の恒久化
- **検証**: `git status --short` がクリーンになり、`dist/snippets.ini` に業務文面が残っていない(ローカル退避は別途確認)
- **実装可否**: Q1/Q2回答後に実装可

### D2. 重要挙動のプローブ不足【安全網】
- **根拠**: 自動検証があるのは捕捉フィルタ(`verify-clip-filter.ps1`)と数字キーHotIf(`verify-numkey-hotif.ahk`)のみ。検疫コミット/取消・Cliborインポートの冪等性/一意化・`SnipMgrWriteLine` のfail-closed・`PushClipImage` の間引きは手動確認のみ
- **なぜ負債か**: これらは製品の安全設計の核であり、今後の変更のたびに手動実機確認に依存している
- **影響**: 全域(回帰の検出手段がない)
- **リスク**: プローブ追加自体は本体無変更(既存の「一時ディレクトリへコピー+正規表現注入」方式を踏襲)なので低
- **改善案**: `scripts/verify-clibor-import.ps1`(合成CSV: CP932ヘッダ4列/UTF-8変種/重複ラベル/同一本文再取込)、`scripts/verify-archive-quarantine.ps1`(autoclear短縮設定で書込/取消の両パス)、`scripts/verify-all.ps1`(既存+新規を直列実行)
- **検証**: 新プローブが現行コードでPASSすること(現行挙動の固定が目的。FAILしたら§4-4でSTOP)
- **実装可否**: **実装してよい**(本体に触らないこと。テストデータは必ず合成)

### D3. バージョン文字列の二重管理
- **根拠**: `dist/soushin-suggest.ahk` 855行(ランチャー表示"v1.11.0")と1701行(トレイ"v1.11.0")、さらに `build.ps1 -Version` 引数が手動同期
- **なぜ負債か**: 毎リリースで2箇所書き換え。git履歴上も毎回両行が差分になっており、ズレたら表示不整合
- **影響**: 表示のみ(機能影響なし)
- **リスク**: 低
- **改善案**: 冒頭に `global AppVersion := "1.11.0"` を置き2箇所から参照。トレイの `A_TrayMenu.Disable("v" . AppVersion)` も同名で連動させる
- **検証**: validate + ビルド + ランチャー/トレイの目視(またはスクショ)で表示一致
- **実装可否**: **実装してよい**

### D4. snippets.ini書き込み処理の重複
- **根拠**: 「末尾改行チェック+FileAppend」がほぼ同文で3箇所(`ImportSnippets` 532-537行 / `SnipMgrAdd` 790-791行 / `PromoteHistoryAt` 1656-1658行)。ラベル無害化 `RegExReplace(...,"[=\[\];]")` が `SnipMgrFormValues` 776行と `PromoteHistoryAt` 1651行に重複。行パーサも `LoadSnippets`(285行)と `SnipMgrReadItems`(717行、lineNo保持のみ差)でほぼ重複
- **なぜ負債か**: エスケープ規則やnl規則を将来変えるとき、1箇所直し忘れでファイル破壊(1定型文=1行の不変条件違反)に直結
- **影響**: snippets.ini書き込み全経路
- **リスク**: 中(書き込み経路のため)。ただし純粋な抽出であればdiffは機械的
- **改善案**: `AppendSnippetLine(label, body)`(nl判定+エスケープ+FileAppend+ArchiveSnippetsCsv呼び出し)と `SanitizeSnippetLabel(s)` を抽出し3箇所を置換。**パーサ2本の統合はしない**(コメントに「LoadSnippets本体は改造しない」という明示判断あり。717行)
- **検証**: D2のプローブ+実機で「新規追加/昇格/取込→snippets.iniのバイト差分が置換前後で同一」を確認
- **実装可否**: **実装してよい**(ただしD2のプローブを先に作ってから)

### D5. BOM挙動とコメントの食い違い
- **根拠**: `SaveIniKey` 1175-1176行のコメントとHANDOFF教訓2は「FileDelete+FileAppend(UTF-8)=BOMなし」と主張。実測では `dist/snippets.ini` 先頭にEF BB BFが存在(クリア取込による新規作成の産物)。【2026-07-17 司令塔が使い捨てAHKスクリプトで2回実測(4象限+SaveIniKey同一パターン)、いずれもBOM付きで再現・dist/snippets.iniの実測とも一致】`FileAppend(UTF-8)`と`FileOpen(w,UTF-8)`はどちらも新規作成時BOM付き、`FileOpen(w,UTF-8-RAW)`のみBOMなし。既存ファイルへの追記はBOMを増やさない
- **なぜ負債か**: 誤った知識がコメントとして固定されており、次の実装者が信じて事故る。BOM有無がファイル操作の経路によってトグルする(SnipMgrWriteLineの全読み+全書きはBOMを落とす)
- **影響**: sites.ini/snippets.ini/CSV系の全書き込み
- **リスク**: 中(ユーザーデータの形式に触る)
- **改善案**: 実測完了(Q4参照)。**採用: (a)コメント修正のみ**。新規作成経路の`UTF-8-RAW`統一(b)は見送り(既存ファイルへの追記が主経路のため実害は限定的)
- **検証**: 実測スクリプトの出力記録(本ファイルQ4に記載)+D2プローブ+`cat -A`(またはGet-Contentの先頭バイト確認)
- **実装可否**: **実装可**(a)。Phase 2でコメント修正を実施

### D6. dist/がソース・配布物・ユーザーデータ・実行時状態の4役を兼ねる
- **根拠**: `dist/` に .ahk(ソース・追跡)、.exe/.zip(成果物・ignore)、snippets.ini(ユーザーデータ・追跡)、startup-prompted.flag/clip-archive(実行時状態・ignore)が同居。実際にユーザーがここでexeを常用している
- **なぜ負債か**: 所有範囲が曖昧で、D1の機密混入事故の温床。「ソースを編集→その場で実行中のアプリのデータと衝突」が構造的に起きる
- **影響**: リポジトリ運用全体
- **リスク**: 高(移動はbuild.ps1・ユーザーの実行環境・README導線すべてに波及)
- **改善案**: 例: `src/soushin-suggest.ahk` へソース移動+build.ps1修正、snippets.iniはテンプレ化(`snippets.default.ini` を梱包時にrename)。ただし**提案のみ**
- **検証**: (実施する場合)ビルド産物のzip内容が現行と同一構成であること
- **実装可否**: **提案に留める**(Q2の回答と合わせてユーザー判断)

### D7. オプトイン保存の書き込み失敗が完全に無音
- **根拠**: `ArchiveSnippetsCsv` 487-492行・`CommitPendingArchive` 1293-1297行の `try` はcatchなしで握りつぶす
- **なぜ負債か**: fail-closed(保存しない側に倒す)自体は設計意図どおりだが、「ONにしたのに保存されていない」ことにユーザーが気づく手段がない
- **影響**: フォルダ保存機能のみ
- **リスク**: 通知追加は挙動変更(新しいToolTipが出る)にあたる
- **改善案**: 初回失敗時のみFlash等。**提案に留める**(UX判断)
- **実装可否**: 提案のみ

### D8. GUIシングルトンごとのグローバル群(約40個)
- **根拠**: 18-37行+578-581行+1099行+1310行のglobal宣言群。`SnipMgr*` 12個、`Launcher*` 8個など
- **なぜ負債か**: 状態の所有者が追いにくい。ただしAHK v2の単一ファイル常駐スクリプトとしては慣用的で、各GUIの生成/破棄規律(シングルトン+Hide、ランチャーのみDestroy)は一貫している
- **影響**: 可読性のみ。実バグの証拠はない
- **リスク**: クラス化・分割は高リスク(タイマー/ホットキー/コールバックの束縛が多い)
- **改善案**: しない。せいぜい目次コメントの追加。#Include分割も配布・ビルドに波及するため**提案のみ**
- **実装可否**: 提案のみ(目次コメント程度は可)

### D9. HANDOFF-next-session.mdの陳腐化
- **根拠**: 「Cliborインポート未実装・最優先」と記載だが `d47f721` で実装済み
- **改善案**: Q6回答後に更新か削除。gitignore済みなのでコミット対象外
- **実装可否**: Q6回答後に可

### D10. stripe-webhook.tsのDOWNLOAD_URL陳腐化(疑い)
- **根拠**: 13行目 `releases/download/v1.1.2/soushin-suggest-v1.1.2.zip`。製品はv1.11.0
- **なぜ負債か**: 購入者への納品物が9マイナーバージョン古い可能性。ただし「安定版のみ配布」の運用意図かもしれず、コードからは判断不能
- **実装可否**: **触らない**。Q3としてユーザーに確認(課金・通知系のためStop-and-ask対象)

---

## 8. Implementation Phases(この順で。各フェーズ=独立コミット)

### Phase 0: 現状確認と未コミット変更の分離【Q1/Q2回答が前提】
1. §5のbaselineを実行・記録
2. Q1承認後: `dist/soushin-suggest.ahk` + `index.html` を「v1.11.0 fixes」としてコミット(**snippets.iniは絶対に含めない**)
3. Q2の回答に従い `dist/snippets.ini` を処置(退避→追跡方針変更 or skip-worktree)。ローカルのユーザーデータを消さないこと
4. `git status` がクリーンであることを確認してからPhase 1へ

### Phase 1: 安全網の追加(D2)— 本体無変更
1. `scripts/verify-clibor-import.ps1` を新設(合成CSVのみ使用)
2. `scripts/verify-archive-quarantine.ps1` を新設(ステージング環境でautoclearを数秒に短縮し、コミット/取消の両パスを検証)
3. `scripts/verify-all.ps1` で既存2本+新規を直列化
4. 全プローブが現行コードでPASSすることを確認(FAILならSTOP→質問)

### Phase 2: 明らかに安全な整理
1. D3: `AppVersion` 定数化(2箇所置換)
2. D5(a): BOM挙動の実測スクリプト実行→結果を記録→誤ったコメント(SaveIniKey付近)を実態に合わせて修正(コード挙動は変えない)
3. D9: Q6回答があればHANDOFF更新

### Phase 3: 小さな責務分離(D4)
1. `SanitizeSnippetLabel` 抽出(2箇所置換)
2. `AppendSnippetLine` 抽出(3箇所置換)
3. 各置換ごとにPhase 1のプローブ+validate+ビルドを回す。snippets.iniの出力バイト列が置換前後で同一であることを確認する

### Phase 4: BOM正規化(D5(b))【Q4で(b)が選ばれた場合のみ】
1. 新規作成経路のみ `UTF-8-RAW` へ。既存ファイルへの追記経路は変更しない
2. BOMあり既存ファイルの読み取り互換をプローブで固定してから実施

### Phase 5: 提案書の作成(実装しない)
- D6(dist再編)・D7(保存失敗通知)・D8(#Include分割)・Q3(配布URL)・Q5(LP文言)について、それぞれ利害と移行手順を短くまとめ、`_docs/REFACTOR-PROPOSALS.md` として提出。承認なしに実装しない

---

## 9. Verification Requirements

各フェーズの終わりに必ず:

1. `& "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /ErrorStdOut /validate "dist\soushin-suggest.ahk"` → exit 0
2. `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-all.ps1`(Phase 1以降) → 全PASS
3. `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build.ps1 -Version <現行バージョン>` → `OK: ...zip`
4. `.ahk` 以外(functions/)に触れた場合のみ `npx tsc --noEmit`
5. `git status --short` に意図しないファイル(snippets.ini・clip-archive・*.csv・*.flag)が現れていないこと
6. snippets.ini書き込み経路に触れたフェーズでは、代表操作(新規追加・昇格・取込)前後のファイル差分が期待どおりであることをステージング環境で確認

実機のみで確認可能な項目(ランチャー表示・トレイ・ホバー等)は「未検証(要実機)」と明示して報告する。緑を偽装しない。

---

## 10. Reporting Format

作業完了時(または中断時)に以下を報告:

```
## 実施フェーズ: Phase N — <名前>
## コミット: <hash> <message>(フェーズごと)
## Baseline記録: <着手前の各コマンドと結果>
## 実行した検証コマンドと結果(最後に実行したものを含む全て):
   - <コマンド> → <exit/出力要点>
## 変更ファイルと行数: <git diff --stat>
## 未検証項目(要実機): <あれば>
## STOPした質問: <あれば、§4/§6のどれに該当したか>
## 次フェーズへの引き継ぎ: <あれば>
```

---

## 11. Out-of-scope Items(今回はやらない)

- 新機能追加・機能削除(判定基準は `_docs/CLIBOR-PARITY-JUDGMENT.md` G節だが、判断自体をしない)
- `index.html`(LP)のリファクタ・文言変更(Q5の案提示のみ)
- `functions/api/stripe-webhook.ts` の変更(Q3の確認のみ)
- `NM_CUSTOMDRAW` によるサムネイル行レイアウト改善(見送り済みの過去要望)
- GUIのクラス化・#Include分割・dist/再編の**実装**(提案のみ)
- CI/GitHub Actionsの導入(ローカルビルド運用が前提。提案したければPhase 5に含める)
- パフォーマンス最適化(履歴30件規模で問題の証拠なし。コメントにも「デバウンス等は不要」と明記)
- `node_modules`・zip成果物・アセット類の整理
