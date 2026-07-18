# 実装ハンドオフ: ランチャーListViewゼブラストライプ（MVP）

設計は完了済み。このファイル1枚で着手できる。設計の全文は [`LAUNCHER-ZEBRA-STRIPE-DESIGN.md`](LAUNCHER-ZEBRA-STRIPE-DESIGN.md) 参照（読む場合はC節・E節・G節だけで足りる）。

## 背景

`+Grid`（LVS_EX_GRIDLINES）だけでは罫線がシステム固定の淡いグレーで背景色`F0F6FF`とのコントラストがほぼゼロで実質見えないことが実機検証で判明した。NM_CUSTOMDRAWによるゼブラストライプ（行の背景色を交互に変える）に切り替える。

## スコープ（MVPのみ）

`dist/soushin-suggest.ahk`の以下の変更のみ。設計書C節のコードをそのまま転記する。

1. 起動部（auto-execute区間）に、`LauncherZebraOn`・`LauncherLvHHwnd`・`LauncherLvSHwnd`のグローバル宣言と`OnMessage(0x004E, LauncherLVCustomDraw)`の登録を追加
2. 新規関数`LauncherLVCustomDraw(wParam, lParam, msg, hwnd)`を追加（設計書C-1、構造体オフセットは裏取り済みなのでそのまま使ってよい）
3. `ShowLauncher()`内、`LauncherLvH`/`LauncherLvS`生成直後にhwndキャッシュ代入を追加（設計書C-2）
4. `CloseLauncher()`内、`LauncherGui := 0`と並べてhwndキャッシュを0クリア（設計書C-2）
5. L1552・L1566のListViewオプション文字列から`+Grid`を削除（設計書C-3）
6. `DiagProbeLauncherPaint`内、L340付近の背景色判定にゼブラ色`DCE7F8`の分岐を追加（設計書C-4、**これを忘れると診断カウンタが誤報するので必ず同一コミットに含める**）

**SnipMgr側（L1029/L1059）の`+Grid`は触らない**（あちらは白背景で罫線が正常に見えている）。

## 着手手順

1. `git status`で作業ツリーがクリーンか確認
2. ブランチを切る（例: `feat/launcher-zebra-stripe`）
3. 上記6箇所を実装
4. `AppVersion`をパッチバージョン+1に更新
5. `scripts/build.ps1`でビルドし、exeが正常に起動することを確認（常駐アプリがあれば先に終了させる）
6. 検証（下記）

## 検証（機械的な完了判定）

1. ランチャーを開き、履歴タブ・定型文タブの両方で行の縞模様が目視できる（奇数行F0F6FF、偶数行DCE7F8）
2. タブ切替で縞の配色が同一であること
3. 検索絞り込み後も縞が表示行基準で交互のままであること（絞り込みで行が減っても縞が崩れない）
4. 「診断情報をコピー」で`paint.state`が`full`であること、`counters.uiBlank`/`counters.uiGridOnly`が増えないこと
5. `scripts/monkey-test.ps1`を50回試行で再実行し、クラッシュなし・描画異常なしを確認
6. コード内で`LauncherZebraOn := false`に一時的に変更して再ビルドし、縞なしの従来表示に戻ることを確認してから`true`に戻す（killスイッチの実効性確認）

reality-checkerへの委任を推奨。

## 地雷（設計書G節から転記、特に重要なもの）

- **フック内でオブジェクトプロパティ（`.Hwnd`等）に触らない**（G-1）。ランチャー破棄後に例外を起こす。hwndは必ず整数キャッシュ経由で比較する。
- **OnMessageハンドラは対象外メッセージに対して必ず「値なしreturn」**（G-2）。0以外の値を返すと他のコントロール（SnipMgrのListView・Tab3等）の通知処理を壊す。
- **構造体オフセットのx64/x86分岐（`A_PtrSize`判定）を削らない**（G-4）。誤ったオフセットはクラッシュに直結する最重要ポイント。
- **RedrawWindowにRDW_UPDATENOWを追加しない**（G-3）。追加するとCritical区間中に同期描画が走り、安全な性質が崩れる。

## 対象外（今回やらないこと・設計書F節参照）

- 行下端の1px自前線（`+Grid`と同じ失敗クラスの再演と判断し不採用）
- 背景色の微調整（統一したばかりの色を再度動かすリスクのみでリターンなし）
- Class_LV_Colors.ahk導入
- ゼブラON/OFFのini設定露出（グローバル定数のkillスイッチで十分）
- 選択行との干渉対策（報告が出てから対応、先回り不要）

## 次にやるとしたら

MVPが完了したら`HANDOFF-next-session.md`の該当節を更新すること。
