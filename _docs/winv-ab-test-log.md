# Win+V A/Bテスト記録簿

設計書: [`WINV-CLIPBOARD-FREEZE-DESIGN.md`](WINV-CLIPBOARD-FREEZE-DESIGN.md) Phase 1

## 記録ルール(再掲)
- 1日数回(朝・昼・夕・作業の節目)にWin+Vを押して開くか確認し、1行記録する
- 「AHK OFF」はトレイの監視OFFトグルでは不十分。**soushin-suggestプロセスをタスクマネージャーで完全終了**したことを確認してからテストする
- 「Chrome拡張OFF」は`chrome://extensions`でトグルOFF(Chromeを閉じるだけでは不可)
- 固まったら、復旧より先に`clip-incident.ps1`を実行し、出力ファイル名をメモ欄に書く
- 条件は今のところ**A(現状)から開始**。ベースラインの再現間隔が分かるまでAを続ける

## 記録表

| 日時 | 条件(A/B/C/D) | Win+V結果(○開いた/×開かなかった) | 直った方法(cbdhsvc再起動/explorer再起動/PC再起動/該当なし) | clip-incident出力ファイル | メモ |
|---|---|---|---|---|---|
| | | | | | |

<!-- 記入例:
| 2026-07-18 09:00 | A | ○ | - | - | 通常確認、問題なし |
| 2026-07-18 15:30 | A | × | explorer再起動 | clip-incident-20260718-153000.txt | 直前にChrome拡張で画像コピーを連続していた |
-->
