# 設計書: 左手完結ランチャー起動体験の研磨（Ctrl単押しの磨き上げ）

- 設計 = Fable(claude-fable-5) / 素材集め = 会議ハーネス(4体成功) / 裏取り・統合 = 司令塔Claude
- 日付: 2026-07-23
- 3段構え(council-fableスキル)の産物

## お題(なぜこの変更が必要か)

サイドボタン無しマウス(Logicool M240等)ユーザーから、「右手はマウス操作(コピー・送信・ミドルクリックでGit Bash)、左手は完全にキーボードだけでランチャーを呼び出したい」という要望があった。現状の`Ctrl`キー単押しは既にこれを実現しているが、ユーザーはさらに良い体験を求めていた。

## 決定的な事実(会議のどのメンバーも知らなかった、司令塔がExplore調査で確認済み)

このプロジェクトは既に一度、「もっと良いランチャー起動キー」を模索して失敗している。

1. `_docs/LAUNCHER-HOTKEY-ICON-DESIGN.md`(2026-07-15)で会議が候補を検討: 「Ctrl2回押し等の連打検出」→却下(キーリピート・Ctrl+C/V干渉・誤作動頻発)、`Ctrl+Win+E`→却下(意味付けが弱い)、`Ctrl+Win+S`→却下(Save連想がペーストと合わない)。最終採用は`Ctrl+Win+V`
2. しかし`Ctrl+Win+V`は実機でWindows標準のクリップボード履歴/絵文字パネルと衝突し両方同時に開く現象が発覚(2026-07-18)、撤回。現行の`Ctrl`単押しに置き換えられた

この経緯を踏まえ、今回は**新しいキーを追加せず、既存のCtrl単押しの内側を狭める(誤爆を減らす)方向**で結論を出した。

## 結論

新しいキーは探さない。現状の`~LCtrl up`/`~RCtrl up`(Ctrl単押し)実装を、以下2点だけ磨く。

1. **タップ判定ゲート**: 押下時間が350msを超えたら起動しない(長押し・迷い押しを無視)
2. **同一キーでのトグル閉じ**: ランチャーが開いている状態でもう一度Ctrlをタップしたら閉じる(Escに指を伸ばさなくていい)

## 実装内容

`dist/soushin-suggest.ahk`の`~LCtrl up`/`~RCtrl up`ブロック(841-846行付近)を以下に置き換える。

```ahk
global CtrlTapMs := 350        ; Ctrl単押し起動と見なす最大押下時間(ms)。長押しは「迷い押し」として無視
global CtrlDownTick := 0

~LCtrl::RecordCtrlDownForLauncher()
~RCtrl::RecordCtrlDownForLauncher()
~LCtrl up::HandleCtrlUpForLauncher()
~RCtrl up::HandleCtrlUpForLauncher()

RecordCtrlDownForLauncher() {
    global CtrlDownTick
    if (CtrlDownTick = 0)          ; キーリピートの2発目以降では上書きしない(地雷1参照)
        CtrlDownTick := A_TickCount
}

HandleCtrlUpForLauncher() {
    global CtrlDownTick, CtrlTapMs, LauncherGui
    held := (CtrlDownTick != 0) ? (A_TickCount - CtrlDownTick) : 0
    CtrlDownTick := 0
    if (A_PriorKey != "LControl" && A_PriorKey != "RControl")
        return                     ; Ctrl+○の組み合わせ操作だった(従来どおりの判定・変更なし)
    if (held > CtrlTapMs)
        return                     ; 長押しは起動しない
    if IsLauncherOpen() {          ; 開いている時のもう1タップは「閉じる」
        CloseLauncher()
        return
    }
    ShowLauncher()
}

IsLauncherOpen() {
    global LauncherGui
    if !IsObject(LauncherGui)
        return false
    try return WinExist("ahk_id " . LauncherGui.Hwnd) ? true : false
    return false
}
```

押下時間が測れなかった場合(`CtrlDownTick=0`、他修飾キー併用時等)は`held=0`となり従来どおり開く方向に倒す。「なぜか開かない」という最悪の体感を避けるため。

### なぜ350ms(会議提案の200msではなく)

200msは素早いタップの典型上限で、非エンジニアユーザーの意識的だがゆっくりめのタップ(200-350ms)を弾いてしまう恐れがある。閾値が厳しすぎる失敗(時々開かない=壊れて見える)は、緩すぎる失敗(ためらい押しで時々開く=Escで閉じれば済む)より体感被害が大きいため、緩い側の350msから始める。

## 過去の失敗との違い(なぜ今回は安全か)

1. **`Ctrl+Win+V`撤回との違い**: 新しいキーもキー組み合わせも一切登録しない。既存の`~LCtrl up`の内側を狭めるだけで、衝突面の増分はゼロ。`Ctrl+Win+V`の失敗は「押したら2つ開く」(悪化方向)だったが、今回の失敗しうる方向は「長押しと誤判定されて開かない」(現状より静かな方向)で、安全側にしか倒れない
2. **連打検出却下との違い**: 前回却下されたのは「Ctrl2回押し」という新しいジェスチャの検出で、キーリピートを連打と誤認する・Ctrl+C/V連打と衝突する、という理由だった。今回はジェスチャを増やさない。キーリピート問題は`CtrlDownTick`を初回downのみ記録することで対処済み(地雷1)。Ctrl+C/V干渉の可否判定(`A_PriorKey`)は一切変更しない

## 過剰設計にならないための線引き

- 新キー・代替キーの選択式提供はしない(CapsLock/無変換キー等は日本語IME環境で衝突リスクが高く却下、E節参照)
- `CtrlTapMs`はsettings.ini・設定ウィンドウに載せない。コード内の名前付き定数1つに留める(`LongPressSec`と同じ扱い)
- タップ時間の実測ログ・キャリブレーション機能は作らない
- `ShowLauncher`のGUI再構築の高速化(キャッシュ化)はやらない。過去にWS_EX_COMPOSITEDで描画対策が白化を招いた領域に隣接するため、別議題として温存する

## 捨てた案と理由

| 案 | 理由 |
|---|---|
| CapsLock単押し | 日本語キーボードでは「英数」キーの位置でIMEの英数/かな切替に直結。トグルキーを奪うとOS側インジケータとの不整合懸念もある |
| 無変換/変換キー | IME変換中の頻用キー(無変換=カタカナ化等)。「無変換=IMEオフ」流儀も普及済みで、日本語ユーザー主体の本アプリでは誤爆リスク最大級 |
| Ctrl2回連打 | 前回会議の却下(キーリピート・Ctrl+C/V干渉)に対する新しい反証がないため再提案しない |
| キーの選択式提供 | 非エンジニアに「衝突するかもしれないキーの選択」を委ねるのは責任転嫁、サポートコストだけ増える |
| 押した瞬間(key down)起動 | Ctrl+C/V/クリック/ホイールが全て巻き添えになるため原理的に不可能 |
| 閾値200ms(会議原案) | 厳しすぎる閾値は「壊れて見える」失敗に倒れるため、350msに緩めて採用 |

## 実装時の地雷

1. **【最重要】修飾キーのキーリピート**: Ctrlを押し続けるとOSは`~LCtrl::`を繰り返し発火させる。毎回`A_TickCount`を上書きすると押下時間が常に数十msと測定され、長押しゲートが骨抜きになる。必ず`if (CtrlDownTick = 0)`の初回のみ記録＋up側で0リセット、をセットで実装する
2. **`~`プレフィックスを絶対に落とさない**: `LCtrl::`(~無し)にするとCtrlが修飾キーとして機能しなくなり、全アプリのCtrl系ショートカットが死ぬ
3. **`IsLauncherOpen()`の判定は`CloseLauncher`の実際の後始末に合わせる**: 破棄済みGuiオブジェクトの`.Hwnd`参照は例外を投げる(feedback_ahk_drag_race_conditionと同族)。`IsObject`チェック＋`try`で包み、判定に失敗したら「開いていない」扱いにする
4. **他修飾キー併用中は`~LCtrl::`/`~LCtrl up::`が発火しない**(ワイルドカード無しのAHK仕様、現行と同じ)。`*`ワイルドカードは付けない(現行に無い発火経路が増え回帰の面が広がるため)
5. **実機回帰項目**: (a)Ctrl短タップで開く(対応アプリ・非対応アプリ・デスクトップ) (b)Ctrl 1秒長押し→離しで開かない (c)開いた状態でCtrl再タップ→閉じてフォーカスが元アプリに戻る (d)Ctrl+C・Ctrl+V・Ctrl+クリック・Ctrl+ホイールズーム後の離しで開かない (e)RCtrl側も(a)-(c) (f)XButton1・Ctrl+Win+C・Ctrl+Win+T・右クリック長押し送信の無回帰
6. **RDP・仮想マシン・G HUB環境では修飾キーの論理状態がスタックすることがある**(既知事象)。`CtrlDownTick`が古い値のまま残ると次のタップの押下時間が巨大値になり「開かない」誤判定になるため、up側で必ず0リセットする
7. **ビルドは必ず`scripts/build.ps1`経由**(Ahk2Exe直叩き厳禁)
