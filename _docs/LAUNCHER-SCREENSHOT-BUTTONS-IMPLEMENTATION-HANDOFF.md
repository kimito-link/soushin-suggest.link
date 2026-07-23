# 実装ハンドオフ: ランチャーへのスクショボタン追加

正本設計書: [LAUNCHER-SCREENSHOT-BUTTONS-DESIGN.md](LAUNCHER-SCREENSHOT-BUTTONS-DESIGN.md)(必ず先に読むこと)

## この1枚で着手できる手順

### 読む順
1. [LAUNCHER-SCREENSHOT-BUTTONS-DESIGN.md](LAUNCHER-SCREENSHOT-BUTTONS-DESIGN.md) — 全体設計・地雷
2. `dist/soushin-suggest.ahk` の855-867行(XButton2ハンドラ、抽出元) — 実装セッション開始時点でこの行番号のはず。行番号がずれていたら`XButton2::`で検索
3. `dist/soushin-suggest.ahk` の1784-1795行付近(ランチャーフッター、ロゴ配置) — `ブランドフッター`のコメントで検索
4. `_docs/LAUNCHER-UX-REDESIGN-DESIGN.md` — フッターのアンカー設計思想(Tab3下端の1点のみ)の背景

### スコープ(MVPのみ、これ以上広げない)

1. `DoFullScreenShot()`/`DoRegionSnip()`関数を新設し、XButton2ハンドラの中身をそのまま移す
2. ランチャーのフッターにButton2つ("画面を撮る"/"範囲を撮る")を追加。クリック時は`CloseLauncher()`→`Sleep(150)`→上記関数呼び出し
3. `index.html`のFAQ(3156行)とmouse mapセクション(2458行付近)を設計書C節の文言に差し替え
4. `dist/README.txt`とスクリプト冒頭コメントに1行追記
5. `AppVersion`を上げてビルド、配布zip再生成、LPのダウンロードリンク更新

### 着手手順

```bash
git checkout -b feat/launcher-screenshot-buttons
```

1. `dist/soushin-suggest.ahk`のXButton2ハンドラ(855-867行付近)を関数抽出
2. ランチャーのフッター(1784-1795行付近)にボタン2つ追加、`LauncherTab.UseTab()`後に追加すること
3. ビルド(`scripts/build.ps1 -Version <番号>`)して実機起動、以下を確認:
   - サイドボタン(進む)短押し/長押しが従来通り動く(回帰確認)
   - ランチャーの「画面を撮る」ボタンでカーソルのあるモニタが全画面キャプチャされ、クリップボード履歴に載る
   - ランチャーの「範囲を撮る」ボタンでWin+Shift+S相当の範囲選択UIが起動する
   - ランチャーが写り込んでいないか、Z-order白化が起きていないか目視確認
4. `index.html`の文言修正、ローカルで表示確認
5. `dist/README.txt`とスクリプト冒頭コメントに1行追記
6. バージョンを上げて再ビルド、配布zip作成、LPのダウンロードリンク更新

### 機械的な完了判定

- [ ] `DoFullScreenShot()`/`DoRegionSnip()`が新設され、XButton2ハンドラとランチャーボタンの両方から呼ばれている(重複実装がない)
- [ ] ランチャーのボタンから撮影して、クリップボード履歴に画像が追加される(既存のスクショ機能と同じ品質)
- [ ] サイドボタン(進む)の短押し/長押しが従来と同じ動作をする(回帰なし)
- [ ] `index.html`のFAQ・mouse mapセクションが設計書C節の文言に更新されている
- [ ] `dist/README.txt`とスクリプト冒頭コメントが更新されている
- [ ] コード差分が概ね50行以内に収まっている(超えていたら過剰設計を疑う)

### 地雷(必ず設計書F節を読むこと、ここでは要点のみ)

- 撮影前に必ず`CloseLauncher()`→`Sleep(150)`を挟む(順序厳守)
- `LastUserCopyTick`の記録を含めて関数を丸ごと移す(片方だけ更新すると検疫フィルタでバグる)
- フッターのアンカーはTab3下端の1点のみ(過去に2回同じ失敗を繰り返した箇所)
- 新規ホットキーは追加しない(この設計の核心はキー追加ゼロであること)

## 転記元の実在パス一覧(裏取り済み)

- `dist/soushin-suggest.ahk:855-867` — XButton2ハンドラ(抽出元、司令塔が実機コードで確認済み)
- `dist/soushin-suggest.ahk:2280` — `CaptureMonitorAtCursorToClipboard()`本体
- `dist/soushin-suggest.ahk:1784-1791` — ランチャーフッターのロゴ配置(司令塔が実機コードで確認済み。設計書は1782-1795と表記しているが実際は1784-1791、ノートPC側コミット821b3f5でのカーソル追従配置追加により若干行がずれている可能性。実装時は`ブランドフッター`のコメントで検索し直すこと)
- `index.html:3156` — FAQ「特定メーカーのマウスが必要ですか？」(司令塔が全文確認済み)
- `index.html:1552,2431,2432,3140` — LP核心コピー(司令塔が全文確認済み)
- `index.html:2458`付近 — mouse mapセクションlede(Fable引用、要再確認)

## 次にやること

このセッションでは実装しない。次チャットでこのファイルを読ませ、ブランチを切って別モデルでMVP実装すること。
