# soushin-suggest.link 表示速度最大化 実装ハンドオフ

設計書: [LP-SPEED-MAX-DESIGN.md](LP-SPEED-MAX-DESIGN.md)（Fable設計・司令塔裏取り済み）。この1枚だけで着手できる。

## 読む順

1. このファイル
2. [LP-SPEED-MAX-DESIGN.md](LP-SPEED-MAX-DESIGN.md) の「司令塔による裏取りメモ」（設計との差分・訂正点）
3. 必要ならD節（MVP）とC-1/C-2（具体機構）

## スコープ（MVPだけ）

今回実装するのはMVPの3点のみ。第2段（残り39枚の外部化・WebP化）はやらない。

1. **6コマ漫画6枚のbase64を`assets/comic/panel-N-web.jpg`参照に置換**
2. **`_headers`ファイルを新規作成**（`/assets/*`長期キャッシュ、HTML短期キャッシュ）
3. **`functions/api/diag/report.ts`と`functions/api/stripe-webhook.ts`にCache-Control: no-store追加**（`latest.ts`は設定済みなので触らない）

## 着手手順

```bash
git checkout -b feat/lp-speed-mvp
```

### タスク1: 漫画パネルのsrc置換

`index.html`内、見出し `<h2>6コマで見る、送信サジェストの流れ。</h2>` の直後、`.comic-grid > .comic-panel > img` が6個連続している箇所（`grep -n "6コマで見る" index.html`で見出し行を特定し、その後をエディタで開く）。

各`<img>`の`src="data:image/jpeg;base64,..."`を、1枚目から順に`src="/assets/comic/panel-1-web.jpg"`〜`src="/assets/comic/panel-6-web.jpg"`に置換する（パネルの並び順とファイル名の対応はDOM出現順＝panel-1〜6の順で一致するはず。**置換前に該当base64をブラウザやツールでデコードし、`assets/comic/panel-N-web.jpg`と目視比較して対応が合っているか確認すること**。会議・Fableの前提では同一内容だが未検証）。

`loading="lazy"`は既に付与済みなので変更不要。`width`/`height`属性が無ければCSS上の表示サイズ（`.comic-panel img`のスタイル定義を確認）に合わせて追加する。

### タスク2: `_headers`新規作成

リポジトリ直下に作成:

```
/assets/*
  Cache-Control: public, max-age=31536000, immutable

/
  Cache-Control: public, max-age=0, must-revalidate
/index.html
  Cache-Control: public, max-age=0, must-revalidate
```

### タスク3: APIエンドポイントのno-store追加

`functions/api/diag/report.ts`と`functions/api/stripe-webhook.ts`のレスポンスヘッダーに`"Cache-Control": "no-store"`を追加する。既存の`functions/api/diag/latest.ts`の実装（L47, L54付近）を参考にする。

## 完了判定（機械的に確認できるもの）

- `git diff --stat index.html` で減量幅が概ね500KB前後（漫画6枚のbase64除去分）であること
- `_headers`ファイルが存在し、上記3ブロックが記載されていること
- `functions/api/diag/report.ts`と`stripe-webhook.ts`のレスポンスに`no-store`が含まれること（`grep -c "no-store" functions/api/diag/report.ts functions/api/stripe-webhook.ts`が各1以上）
- Cloudflare Pagesプレビューデプロイで6コマ漫画セクションが今まで通り表示されること（画像が壊れていない・順序が正しい）
- Lighthouse等でCLSが施策前後で悪化していないこと（`width`/`height`が効いているか）

## 地雷（設計書F節から抜粋、実装時に効くもの）

- **漫画パネルの対応順が本当にpanel-1〜6の順か未検証**（前提であり実測していない）。置換前に必ず目視比較すること。
- `_headers`は`/api/*`のFunctions応答には効かない。APIのキャッシュ制御は必ずTSコード側で行う（タスク3）。
- Windows/OneDrive環境。ファイル置換をPowerShellの日本語混在コマンドで行わない（Shift-JIS誤読の既知地雷）。
- `immutable`を`_headers`に設定した後、`assets/comic/panel-N-web.jpg`の中身を将来変更する場合は必ずファイル名も変える運用にすること（そうしないとキャッシュされたユーザーに古い画像が最長1年残る）。

## この先（今回はやらない）

第2段（below-the-fold 34枚 + ヘッダー/ヒーロー5枚の外部化、`scripts/externalize-inline-images.mjs`の作成）は設計書C-1に詳細がある。MVPの効果測定（PageSpeed Insights）をしてから着手判断する。
