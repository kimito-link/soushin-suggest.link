#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"
; コンパイル後もWindows 10/11のトースト通知はAutoHotkey本体のAUMID("AutoHotkey.AutoHotkey")に
; 紐づく既定アイコン(緑のH)を出す。自前のAUMIDを明示登録することで通知側にも自分のアイデンティティを持たせる。
DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "wstr", "KimitoLink.SoushinSuggest")
; .ahk直接実行(開発時・検証プローブ)ではexeのアイコンリソースが存在せずTraySetIconのリソース指定が失敗し、
; それ以降の自動実行(OnClipboardChange登録等)まで巻き込んで壊れることを実測で確認したためコンパイル時のみ実行。
if A_IsCompiled
    TraySetIcon(A_ScriptFullPath, 1)   ; トレイアイコンの明示指定(リソース1番=Ahk2Exeのメインアイコン)
; ============================================================
;  送信サジェスト / soushin-suggest.link
;  なぞってコピー・右クリック長押しで送信・サイドボタンでスクショ&クイックペースト
;  Windows 10/11 対応・買い切り・追加課金なし
; ============================================================
;  左クリック（ドラッグ）  -> 選択範囲を自動コピー（全アプリ）
;  右クリック長押し(0.35s) -> サイトに合った送信キーを送る（短押しは通常の右クリック）
;  サイドボタン(戻る)      -> クイックペースト（全アプリ）
;  サイドボタン(進む)      -> 短押し=全画面スクショ / 長押し=範囲指定スクショ
;  ミドルクリック           -> Git Bash を前面へ（無ければ起動）
;  Ctrl+Win+C              -> なぞってコピーのON/OFF切り替え
;  Ctrl+Win+V              -> クイックペーストを開く（マウスなしでも呼び出せる）
;  対応アプリ・送信ルールは sites.ini、定型文は snippets.ini で編集できます（同梱）。
;  トレイのアイコンを右クリック -> Suspend Hotkeys / Exit

global AppVersion := "1.23.3"
global CopyOnSelect := true, dragX := 0, dragY := 0, dragT := 0
global SitesConfig := Map()
global SiteRules := []
; Cliborと同様に「ずっと遡れる」体験にするため上限は実質無制限(v1.16.0〜。旧既定30)。
; 破棄ロジック(PushClipHistory/PushClipImageのwhile ClipHistory.Length > ClipHistoryMax)は
; そのまま残し、事実上発火しない大きさにしているだけ(sites.ini [clipboard] max= で今も上書き可能)。
global ClipHistory := [], ClipHistoryMax := 999999   ; {text,time}の配列・メモリのみ
; v1.18.0〜Cliborと同じ「常時記録・永続保存」に既定を合わせ、archive.text/archive.image/
; history.persistは既定ONに変更(ユーザー明示指示)。パスワード自動クリア連動の検疫は無変更で
; 効き続けるが、検疫は「パスワードマネージャーでコピー→自動クリア」という手順を踏んだ場合しか
; 守れず、手入力パスワードの確認コピー等までは守れない残余リスクが常時有効になる前提で採用。
; 経緯は_docs/CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md、_docs/CLIPBOARD-HISTORY-PERSISTENT-STORE-DESIGN.md参照
global LongPressSec := 0.35     ; sites.ini [general] longpress= で上書き可
global LauncherGui := 0, LauncherTarget := 0, LauncherTab := 0, Snippets := [], LauncherDragBar := 0, LauncherLvH := 0, LauncherLvS := 0, LauncherHoverLast := ""
; ランチャーListViewのゼブラストライプ(NM_CUSTOMDRAW)。+Gridは罫線色がシステム固定の淡い
; グレーで背景F0F6FFとのコントラストがほぼ無く実質見えなかったため撤去し、行の背景色を
; 交互に塗る方式へ切替(_docs/LAUNCHER-ZEBRA-STRIPE-DESIGN.md)。killスイッチはfalseで
; 完全に既定描画へ素通し。hwndキャッシュはShowLauncher/CloseLauncherで設定・0クリアする。
global LauncherZebraOn := true
global LauncherLvHHwnd := 0, LauncherLvSHwnd := 0
OnMessage(0x004E, LauncherLVCustomDraw)   ; WM_NOTIFY。登録は起動時1回のみ・着脱しない
global LauncherSearchEdit := 0                ; 検索ボックス(履歴/定型文タブ共通、内容で絞り込み)
global LauncherHistFilterMap := []            ; 表示行(1始まり) → ClipHistoryの実インデックス。フィルタ無しなら1:1
global LauncherSnipFilterMap := []            ; 表示行(1始まり) → Snippetsの実インデックス。フィルタ無しなら1:1
global ClipWatchOn := true                ; トレイから一時停止可
global LastUserCopyTick := 0              ; ^c/^x/^Ins・なぞってコピー送信の時刻
global LastLButtonUpTick := 0             ; 右クリックメニュー「コピー」等のクリック由来を救う
global SelfClipTick := 0                  ; 自分がA_Clipboardへ書いた時刻(監視除外)
global LastCaptureText := "", LastCaptureTick := 0   ; 自動クリア検知用
global ClipUserWindowMs := 1000           ; ユーザー操作限定フィルタの窓(iniに出さない・固定)
global ClipAutoClearSec := 45, ClipMaxLen := 100000
global ClipExcludeExes := Map("keepass.exe",1, "keepassxc.exe",1, "1password.exe",1, "bitwarden.exe",1)
global ClipImageMax := 5, ClipImageMaxBytes := 36 * 1024 * 1024   ; 画像専用の件数上限・4Kスクショ程度まで許容(正式設計は_docs/CLIPBOARD-IMAGE-HISTORY-DESIGN.md参照。無制限化はFable設計待ち)
global ClipImageMinPx := 32                ; 幅/高さがこれ未満の極小画像(ノイズ)は履歴に記録しない
; v1.18.0〜: Cliborと同じ「常時記録・永続保存」に既定を合わせる(ユーザー明示指示)。
; 検疫(パスワード自動クリア連動)は既定ON化後も無変更で効き続けるが、検疫が守れるのは
; 「パスワードマネージャーでコピー→自動クリア」という手順を踏んだ場合に限られ、手入力した
; パスワードの確認コピー等までは守れない残余リスクが常時有効になる、という前提を明示指示の上で採用。
global ClipArchiveImage := true, ClipArchiveText := true, ClipArchiveDir := ""
global PendingArchive := []                ; テキストの検疫待ち配列 {text, tick}(45秒+2秒で確定保存)
; 履歴の再起動を跨いだ永続化。検疫は完全維持(ディスク書き込み地点はCommitPendingArchive内の
; 1箇所のまま)。経緯は_docs/CLIPBOARD-HISTORY-PERSISTENT-STORE-DESIGN.md参照
global ClipHistoryPersist := true, ClipHistLoadMax := 10000
global HistStoreLoadState := 0             ; 分割パースの進行状態オブジェクト(0=停止)
global HistStoreRewritePending := false    ; 項目削除後のストア書き直し予約フラグ
global HistStoreDeletedTexts := []         ; 「この履歴を削除」された本文。書き直し確定でクリア
global HistStorePromotedTexts := []        ; 「ペーストして使った」本文と新時刻。書き直し確定でクリア

; --- 診断計器: メモリのみ・プロセス終了で消える(非永続原則と同居)。書込入口はDiagBumpだけ。
; 経緯・設計判断は_docs/SELF-DIAGNOSTIC-INSTRUMENTATION-DESIGN.md参照 ---
global ClipDiag := Map()
global ClipDiagStartTick := A_TickCount

DiagBump(key) {
    global ClipDiag
    if ClipDiag.Has(key)
        ClipDiag[key].n += 1, ClipDiag[key].last := A_TickCount
    else
        ClipDiag[key] := {n: 1, last: A_TickCount}
}

Flash(msg, ms := 1500) {
    ToolTip(msg)
    SetTimer () => ToolTip(), -ms
}

; メモリ上の計器をJSON文字列化してクリップボードへ。ディスクには一切書かない。
; 履歴本文・クリップボード内容は絶対に含めない(カウンターと設定値のみ)。
CopyDiagnostics(*) {
    global SelfClipTick
    txt := BuildDiagText()               ; ★書き込みの前にスナップショット(診断コピー自身のselfSuppressを混入させない)
    SelfClipTick := A_TickCount          ; PasteTextと同じ流儀で自己書込としてマーク
    A_Clipboard := txt
    Flash("診断情報をコピーしました。AIチャットに貼り付けてください", 1800)
}

; --- 診断ページ自動送信(2026-07-18・_docs/SHINDAN-AUTO-SEND-DESIGN.md MVP第1歩) ---
; 「アプリ→サーバー自動送信」は過去に一度「オフライン完結・非永続の看板に反する」として
; 明確に却下されていたが(_docs/SHINDAN-VIEWER-DESIGN.md F節)、ユーザーの明示同意により覆した。
; 譲れない一線: 実デバイスIDは一切送らない(起動ごとに使い捨ての匿名トークンを生成しメモリのみ保持)、
; サーバー保持は6時間TTLで自動削除、送信は毎回ユーザー操作起点(MVPでは自動送信タイマーを持たない)。
global DiagToken := ""
global DiagEndpoint := "https://soushin-suggest.link/api/diag/report"

; 描画実測プローブのキャッシュ(_docs/SHINDAN-PAINT-PROBE-DESIGN.md)。「データはあるのに画面に
; 描かれていない」白化バグを座標/件数だけでは検知できないため、ListView表示面をGetPixelで
; 実測した結果をキャッシュする。ピクセル値そのものは送らず、点数と判定語のみ送信する。
global DiagPaintBody := ""
global DiagPaintTick := 0

; UI構造スナップショット(開発ビルド専用、_docs/SHINDAN-UI-STRUCT-DESIGN.md)。書き込みコードは
; Ahk2Exe-Ignoreブロック内にのみ存在するため、本番exeでは恒久的に空("")のまま = uiフィールドは
; 絶対に送信されない。'"win":"launcher","w":460,...' 形式(外側の{}なし)。
global DiagUiSnapBody := ""
global DiagUiSnapTick := 0

; プロセス起動ごとに再生成する使い捨てトークン。ファイル/レジストリに書かない
; (書けば擬似デバイスIDになるため禁止。設計書C-1)。BCryptGenRandomでCSPRNGから生成する
; (AHKのRandom()は暗号強度が無いため使わない)。
EnsureDiagToken() {
    global DiagToken
    if (DiagToken != "")
        return DiagToken
    buf := Buffer(16, 0)
    if DllCall("bcrypt\BCryptGenRandom", "Ptr", 0, "Ptr", buf, "UInt", 16, "UInt", 0x00000002) != 0 {
        ; BCRYPT_USE_SYSTEM_PREFERRED_RNG=0x2。失敗時はトークン発行自体を諦める(fail-closed)。
        DiagToken := ""
        return ""
    }
    hex := ""
    Loop 16
        hex .= Format("{:02x}", NumGet(buf, A_Index - 1, "UChar"))
    DiagToken := hex
    return DiagToken
}

; 「未同意」に倒れることだけを保証する許可リスト方式(fail-closed)。設定ファイルが壊れて
; 値が欠落・文字化けしても、成立する条件は "yes" との完全一致のみなので必ずOFF側に落ちる。
DiagConsented() {
    global SettingsMap
    return SettingsMap.Has("diag.consented") && SettingsMap["diag.consented"] = "yes"
}

; トレイメニュー「診断ページで見る」。初回(未同意)は確認ダイアログを出し、同意後のみ送信する。
; 起動時に自動でダイアログを出すことはしない(確認疲れによる反射的同意を避ける、設計書C-4)。
; 同意すると以後は起動のたびに自動でバックグラウンド送信が始まる(StartDiagAutoSendIfConsented)。
ShowDiagnosticPage(*) {
    firstTime := !DiagConsented()
    if firstTime {
        msg := "診断カウンター(動作回数と設定値のみ。クリップボードの中身・履歴・個人情報は含みません)を`n"
            . "soushin-suggest.link に送信し、ブラウザで表示します。`n"
            . "同意すると、以後はアプリ起動中5分おきに自動で送信されます(いつでも設定でOFFにできます)。`n"
            . "サーバー上のデータは6時間で自動削除されます。送信してよいですか？"
        if (MsgBox(msg, "診断ページで見る", "YesNo Icon!") != "Yes")
            return
        SetSetting("diag.consented", "yes")
    }
    if !DiagPushAndOpen()
        Flash("診断情報の送信に失敗しました。ネットワーク接続を確認してください", 2000)
    if firstTime
        StartDiagAutoSendIfConsented()
}

; 送信に成功したらブラウザで開く。失敗時はfalseを返すだけで、呼び出し元が通知する(fail-closed、
; 本体の他の処理には一切影響させない)。
DiagPushAndOpen() {
    token := EnsureDiagToken()
    if (token = "")
        return false
    if !DiagPush(token)
        return false
    try Run(DiagShindanBaseUrl() . "#t=" . token)
    return true
}

DiagShindanBaseUrl() {
    return "https://soushin-suggest.link/shindan/"
}

; WinHttpRequestで同期POST。タイムアウトは合計最大9秒(SetTimeouts引数)。
; 重大バグ修正(2026-07-18): この関数は同期(Open第3引数=false)で呼ばれており、送信中は
; メインスレッドが最大9秒ブロックされる。常時自動送信の追加でアプリ起動のたびに呼ばれる
; ようになったため、ちょうどこのブロック中にランチャーGUIの構築が割り込むと、リストが
; 描画途中のまま止まった状態(白化)になる不具合が実機で確認された。手動の「診断ページで見る」
; 経由(DiagPushAndOpen)はユーザー操作の直接応答なので同期のままでよいが、バックグラウンド
; 自動送信(DiagAutoSendTick)はUIスレッドと重ならない専用の非同期関数を使う(下記DiagPushAsync)。
DiagPush(token) {
    global DiagEndpoint
    payload := '{"token":"' . token . '","diag":' . BuildDiagText() . '}'
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(2000, 2000, 2000, 3000)
        req.Open("POST", DiagEndpoint, false)
        req.SetRequestHeader("Content-Type", "application/json")
        req.Send(payload)
        ok := (req.Status = 204)
        DiagBump(ok ? "diagPushOk" : "diagPushRejected")
        return ok
    } catch {
        DiagBump("diagPushFail")
        return false
    }
}

; DiagPushの非同期版。WinHttpRequestを非同期モードで開始し、完了をポーリングで待つことで
; メインスレッドをブロックしない(ランチャーGUI構築等と衝突させないための専用経路)。
; onComplete(ok)は完了時に1回だけ呼ばれる。
DiagPushAsync(token, onComplete) {
    global DiagEndpoint
    payload := '{"token":"' . token . '","diag":' . BuildDiagText() . '}'
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(2000, 2000, 2000, 3000)
        req.Open("POST", DiagEndpoint, true)   ; true=非同期
        req.SetRequestHeader("Content-Type", "application/json")
        req.Send(payload)
    } catch {
        DiagBump("diagPushFail")
        onComplete(false)
        return
    }
    DiagPushAsyncPoll(req, onComplete, 0)
}

; 200msごとに完了をポーリング。最大45回(9秒)で諦める(SetTimeoutsの合計上限と揃える)。
DiagPushAsyncPoll(req, onComplete, tries) {
    ready := 0
    try ready := req.ReadyState
    if (ready = 4) {   ; READYSTATE_COMPLETE
        ok := false
        try ok := (req.Status = 204)
        DiagBump(ok ? "diagPushOk" : "diagPushRejected")
        onComplete(ok)
        return
    }
    if (tries >= 45) {
        DiagBump("diagPushFail")
        onComplete(false)
        return
    }
    SetTimer(() => DiagPushAsyncPoll(req, onComplete, tries + 1), -200)
}

; --- 常時自動送信(2026-07-18・ユーザー要望「ドメインを開くだけで見えるように」) ---
; MVP第1歩の「送信は毎回ユーザー操作起点」から踏み込み、同意後は5分おきにバックグラウンド
; 送信する。連続失敗2回で自動停止する(設計書G-3のリトライ無し方針を維持。無限に再試行しない)。
global DiagAutoSendFailCount := 0

; アプリ起動時に1回だけ呼ぶ。初回(未同意)のみ確認ダイアログを出し、以後は無言で自動送信する
; (毎回確認するとダイアログ疲れで反射的同意を招くため、確認は初回だけ・設計書C-4の思想を踏襲)。
StartDiagAutoSendIfConsented() {
    if !DiagConsented()
        return
    token := EnsureDiagToken()
    if (token = "")
        return
    SetTimer(DiagAutoSendTick, -1)          ; 起動直後に1回即送信
    SetTimer(DiagAutoSendTick, 300000)      ; 以後5分間隔
}

; メインスレッドをブロックしないDiagPushAsync経由で送信する(地雷: 同期DiagPushを
; ここで使うとランチャーGUI構築等と衝突し白化を誘発する。上記DiagPush冒頭コメント参照)。
DiagAutoSendTick() {
    token := EnsureDiagToken()
    if (token = "") {
        SetTimer(DiagAutoSendTick, 0)
        return
    }
    DiagPushAsync(token, DiagAutoSendOnComplete)
}

DiagAutoSendOnComplete(ok) {
    global DiagAutoSendFailCount
    if ok {
        DiagAutoSendFailCount := 0
    } else {
        DiagAutoSendFailCount++
        if (DiagAutoSendFailCount >= 2) {
            SetTimer(DiagAutoSendTick, 0)   ; 連続失敗で自動停止(リトライループを作らない)
            TrayTip("送信サジェスト", "診断の自動送信を一時停止しました(通信エラー)", "Mute")
        }
    }
}

BuildDiagText() {
    global ClipDiag, ClipDiagStartTick, AppVersion, ClipWatchOn
    global ClipUserWindowMs, ClipImageMaxBytes, ClipImageMinPx, ClipHistory
    now := A_TickCount
    s := '{"app":"soushin-suggest","ver":"' . AppVersion . '"'
       . ',"uptimeMs":' . (now - ClipDiagStartTick)
       . ',"watchOn":' . (ClipWatchOn ? 1 : 0)
       . ',"histLen":' . ClipHistory.Length
       . ',"cfg":{"userWindowMs":' . ClipUserWindowMs
       . ',"selfSuppressMs":500,"debounceMs":120'
       . ',"imgMaxMB":' . Round(ClipImageMaxBytes / 1048576)
       . ',"imgMinPx":' . ClipImageMinPx . '}'
       . ',"counters":{'
    first := true
    for key, v in ClipDiag {
        s .= (first ? "" : ",") . '"' . key . '":{"n":' . v.n . ',"agoMs":' . (now - v.last) . "}"
        first := false
    }
    s .= "}"                                  ; countersを閉じる
    if (DiagPaintBody != "")
        s .= ',"paint":{"agoMs":' . (now - DiagPaintTick) . ',' . DiagPaintBody . '}'
    if (DiagUiSnapBody != "")                 ; 本番では恒久的に空(グローバル書き込みはIgnoreブロック内のみ)
        s .= ',"ui":{"agoMs":' . (now - DiagUiSnapTick) . ',' . DiagUiSnapBody . '}'
    return s . "}"
}

;@Ahk2Exe-IgnoreBegin
; UI構造ダンプ(開発ビルド専用、_docs/SHINDAN-UI-STRUCT-DESIGN.md)。
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

; 描画実測プローブ。読み取り専用(GetDC/GetPixel/ReleaseDC/GetCount/LVM_GETITEMRECT)のみで、
; 【不変条件】SETREDRAW/InvalidateRect/RedrawWindow/Move等、描画状態を書き換えるAPIは絶対に呼ばない。
; よって白化バグのクラス(描画状態の破損)をプローブ自身が起こすことは構造的にない。
; 詳細: _docs/SHINDAN-PAINT-PROBE-DESIGN.md
DiagSchedulePaintProbe() {
    SetTimer(DiagProbeLauncherPaint, -150)   ; WM_PAINT処理後に読む。多重呼びは一発タイマーが自然に合流
}

DiagProbeLauncherPaint() {
    global LauncherGui, LauncherTab, LauncherLvH, LauncherLvS, DiagPaintBody, DiagPaintTick
    ; IsObject()はGui破棄後もtrueを返し続ける(オブジェクト自体は生存するため)。プロパティ/メソッド
    ; アクセス時に初めて"The control is destroyed"エラーになる。一発タイマー(-150ms)がランチャー
    ; を閉じた直後に発火し、ここで未捕捉例外落ちする致命的クラッシュが実機で確認された。
    ; 計測全体を1つのtryで包み、破棄後の例外は「もう対象が無い」の合図として静かに抜ける。
    try {
        if !(IsObject(LauncherGui) && IsObject(LauncherTab))
            return
        tabValue := LauncherTab.Value
        lv := (tabValue = 1) ? LauncherLvH : LauncherLvS
        rows := lv.GetCount()
        ink := 0, other := 0, bg := 0
        if (rows > 0) {
            hdc := DllCall("GetDC", "Ptr", lv.Hwnd, "Ptr")
            rect := Buffer(16, 0)
            Loop Min(rows, 3) {                       ; 先頭3行×8点=最大24点
                NumPut("Int", 2, rect, 0)             ; LVIR_LABEL
                if !SendMessage(0x100E, A_Index - 1, rect.Ptr, lv)   ; LVM_GETITEMRECT
                    continue
                l := NumGet(rect, 0, "Int"), t := NumGet(rect, 4, "Int")
                r := NumGet(rect, 8, "Int"), b := NumGet(rect, 12, "Int")
                y := (t + b) // 2
                Loop 8 {
                    x := l + 6 + (r - l - 12) * (A_Index - 1) // 7
                    px := DllCall("GetPixel", "Ptr", hdc, "Int", x, "Int", y, "UInt")
                    if (px = 0xFFFFFFFF)
                        continue
                    rr := px & 0xFF, gg := (px >> 8) & 0xFF, bb := (px >> 16) & 0xFF
                    lum := (rr * 3 + gg * 6 + bb) // 10
                    if (lum < 0x60)
                        ink++                          ; 文字(濃色)が実際に描かれている
                    else if (Abs(rr-0xF0) <= 8 && Abs(gg-0xF6) <= 8 && Abs(bb-0xFF) <= 8)
                        bg++                           ; 背景F0F6FFそのまま
                    else if (Abs(rr-0xDC) <= 8 && Abs(gg-0xE7) <= 8 && Abs(bb-0xF8) <= 8)
                        bg++                           ; ゼブラ偶数行DCE7F8(縞も正常な背景として扱う)
                    else
                        other++                        ; 罫線・選択ハイライト等
                }
            }
            DllCall("ReleaseDC", "Ptr", lv.Hwnd, "Ptr", hdc)
        }
    } catch {
        return   ; 計測中にウィンドウ/コントロールが破棄された。結果は破棄し前回のキャッシュを維持する
    }
    state := (rows = 0) ? "na" : (ink > 0) ? "full" : (other > 0) ? "gridOnly" : "blank"
    DiagPaintBody := '"tab":' . tabValue . ',"rows":' . rows
        . ',"ink":' . ink . ',"other":' . other . ',"bg":' . bg . ',"state":"' . state . '"'
    DiagPaintTick := A_TickCount
    if (state = "blank")
        DiagBump("uiBlank")
    else if (state = "gridOnly")
        DiagBump("uiGridOnly")
    if (state != "full" && rows > 0 && !A_IsCompiled)
        ToolTip("⚠描画異常検知 state=" . state . " rows=" . rows), SetTimer(() => ToolTip(), -2500)
}

; ランチャーListViewのゼブラストライプ(NM_CUSTOMDRAW)。
; 【不変条件】描画状態を書き換えるAPI(SETREDRAW/RedrawWindow等)は絶対に呼ばない。
; comctl32の問い合わせにclrTextBkと戻り値で答えるだけ。例外時はfail-open(縞なし既定描画)。
; 詳細: _docs/LAUNCHER-ZEBRA-STRIPE-DESIGN.md
LauncherLVCustomDraw(wParam, lParam, msg, hwnd) {
    global LauncherZebraOn, LauncherLvHHwnd, LauncherLvSHwnd
    static NM_CUSTOMDRAW := -12
        , CDDS_PREPAINT := 0x1, CDDS_ITEMPREPAINT := 0x10001
        , CDRF_DODEFAULT := 0x0, CDRF_NOTIFYITEMDRAW := 0x20
        , ZEBRA_A := 0xFFF6F0    ; COLORREF(BGR) = RGB F0F6FF 既存背景そのまま
        , ZEBRA_B := 0xF8E7DC    ; COLORREF(BGR) = RGB DCE7F8 同系色をひと目盛り濃く
        , OFF_CODE      := A_PtrSize * 2            ; NMHDR.code
        , OFF_STAGE     := A_PtrSize * 3            ; NMCUSTOMDRAW.dwDrawStage
        , OFF_ITEMSPEC  := A_PtrSize * 5 + 16       ; NMCUSTOMDRAW.dwItemSpec(rc RECT16バイトの後)
        , OFF_CLRTEXTBK := (A_PtrSize = 8) ? 84 : 52  ; NMLVCUSTOMDRAW.clrTextBk
    if !LauncherZebraOn
        return                                       ; 未処理return=既定処理へ
    try {
        from := NumGet(lParam, 0, "Ptr")             ; NMHDR.hwndFrom
        if (from != LauncherLvHHwnd && from != LauncherLvSHwnd) || !from
            return
        if (NumGet(lParam, OFF_CODE, "Int") != NM_CUSTOMDRAW)
            return
        stage := NumGet(lParam, OFF_STAGE, "UInt")
        if (stage = CDDS_PREPAINT)
            return CDRF_NOTIFYITEMDRAW               ; 行ごとの通知を要求
        if (stage = CDDS_ITEMPREPAINT) {
            row := NumGet(lParam, OFF_ITEMSPEC, "UPtr")   ; 0始まりの表示行番号
            NumPut("UInt", Mod(row, 2) ? ZEBRA_B : ZEBRA_A, lParam, OFF_CLRTEXTBK)
            return CDRF_DODEFAULT                    ; 塗りは既定処理に任せる(自前GDI描画なし)
        }
    } catch {
        ; fail-open: 解析に失敗したら既定描画に落とす(縞が消えるだけ)
    }
    return
}

; --- load sites.ini (per-app rules + [sites] title-keyword rules) ---
; IniReadは使わない: 非ASCIIキーをUTF-16 LE以外で誤読する既知の問題があり、[sites]は日本語キーワードを扱うため
LoadSitesConfig() {
    global SitesConfig, SiteRules, LongPressSec, ClipWatchOn, ClipHistoryMax, ClipAutoClearSec, ClipExcludeExes, ClipImageMax, ClipImageMaxBytes, ClipArchiveImage, ClipArchiveText, ClipArchiveDir
    SitesConfig := Map()
    SiteRules := []
    iniPath := A_ScriptDir . "\sites.ini"
    if !FileExist(iniPath) {
        ; fallback defaults if sites.ini is missing/deleted
        for exe in ["chrome.exe", "msedge.exe", "firefox.exe", "brave.exe",
                    "ChatGPT.exe", "claude.exe", "Chatwork.exe"]
            SitesConfig[exe] := "enter"
        SiteRules.Push({keyword: "ココナラ", mode: "manual"},
                       {keyword: "coconala", mode: "manual"})
        return
    }
    section := ""
    for line in StrSplit(FileRead(iniPath, "UTF-8"), "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        if RegExMatch(line, "^\[(.+)\]$", &m) {
            section := Trim(m[1])
            continue
        }
        eq := InStr(line, "=")
        if !eq
            continue
        key := Trim(SubStr(line, 1, eq - 1))
        val := Trim(SubStr(line, eq + 1))
        if (p := InStr(val, ";"))          ; strip inline comment
            val := Trim(SubStr(val, 1, p - 1))
        if (section = "sites")
            SiteRules.Push({keyword: key, mode: StrLower(val)})
        else if (section = "general" && StrLower(key) = "longpress" && IsNumber(val))
            LongPressSec := val + 0
        else if (section = "clipboard") {
            k := StrLower(key)
            if (k = "watch")
                ClipWatchOn := (StrLower(val) != "off")
            else if (k = "max" && IsNumber(val))
                ClipHistoryMax := Integer(val)
            else if (k = "autoclear" && IsNumber(val))
                ClipAutoClearSec := val + 0
            else if (k = "imagemax" && IsNumber(val))
                ClipImageMax := Integer(val)
            else if (k = "imagemaxmb" && IsNumber(val))
                ClipImageMaxBytes := Integer(val) * 1024 * 1024
            else if (k = "archiveimage")
                ClipArchiveImage := (StrLower(val) = "on")
            else if (k = "archivetext")
                ClipArchiveText := (StrLower(val) = "on")
            else if (k = "archivedir")
                ClipArchiveDir := val
            else if (k = "exclude")
                for e in StrSplit(val, ",")
                    if (Trim(e) != "")
                        ClipExcludeExes[StrLower(Trim(e))] := 1
        } else if (section != "" && StrLower(key) = "send")
            SitesConfig[section] := StrLower(val)
    }
}

; --- resolve send rule: title keyword ([sites]) > per-app default > '' ---
; Title-keyword match is layered on top of the process-name default so a
; misdetection can only ever fall back to "show the manual-send tooltip" —
; never trigger an unwanted auto-send.
CurrentSendMode() {
    global SitesConfig, SiteRules
    exe := ""
    try exe := WinGetProcessName("A")
    if (exe = "" || !SitesConfig.Has(exe))
        return ""
    title := ""
    try title := WinGetTitle("A")
    for rule in SiteRules {
        if (rule.keyword != "" && InStr(title, rule.keyword))  ; InStr is case-insensitive by default
            return rule.mode
    }
    return SitesConfig[exe]
}

CopyOnSelectApp() => CurrentSendMode() != ""

; --- スタートアップ登録 (shell:startup にショートカットを作成/削除) ---
StartupShortcutPath() => A_Startup . "\soushin-suggest.lnk"
IsStartupRegistered() => FileExist(StartupShortcutPath()) ? true : false

; --- スタートメニューへのAUMID付きショートカット登録 ---
; Windows 10/11のトースト通知(TrayTip)は、コンパイル済みexeがAutoHotkey本体のAUMID
; ("AutoHotkey.AutoHotkey")にフォールバックすると既定のAutoHotkeyアイコンを出す。
; SetCurrentProcessExplicitAppUserModelID単体では通知アイコンは解決されず、
; 「スタートメニューに、そのAUMIDを持つショートカットが存在する」ことが必要
; (Microsoft Learn: How to enable desktop toast notifications through an AppUserModelID)。
; 実装はAutoHotkey v2公式インストーラーのUX\inc\CreateAppShortcut.ahkを踏襲。
global AppAumid := "KimitoLink.SoushinSuggest"
StartMenuShortcutPath() => A_AppData . "\Microsoft\Windows\Start Menu\Programs\送信サジェスト.lnk"

; 既存ショートカットのIconLocationが想定と違えば再作成する(過去の試行錯誤で不完全なショートカットが
; 残っている環境の自己修復も兼ねる。FileExistだけの判定だと一度不完全な状態で作られると直らない)。
EnsureStartMenuShortcut() {
    global AppAumid
    if !A_IsCompiled   ; .ahk直接実行(開発時・検証プローブ)ではexeにアイコンが埋め込まれていないためスキップ
        return
    path := StartMenuShortcutPath()
    wantIcon := A_ScriptFullPath . ",0"
    if FileExist(path) {
        try {
            sh := ComObject("WScript.Shell")
            lnk := sh.CreateShortcut(path)
            if (lnk.IconLocation = wantIcon)
                return
        } catch {
            ; 読み取り失敗時は下のtryで再作成を試みる
        }
    }
    try CreateAppShortcut(path, {target: A_ScriptFullPath, desc: "送信サジェスト", aumid: AppAumid, icon: A_ScriptFullPath, iconIndex: 0})
}

; AutoHotkey v2公式インストーラー(AutoHotkeyUX/inc/CreateAppShortcut.ahk)からの移植。
; IShellLinkでショートカット本体を組み立て、IPropertyStore経由でSystem.AppUserModel.IDを埋め込む。
CreateAppShortcut(linkFile, p) {
    lnk := ComObject("{00021401-0000-0000-C000-000000000046}", "{000214F9-0000-0000-C000-000000000046}")   ; CLSID/IID_IShellLink
    ComCall(20, lnk, "wstr", p.target)                                          ; SetPath
    ComCall(11, lnk, "wstr", p.HasProp("args") ? p.args : "")                   ; SetArguments
    ComCall(7, lnk, "wstr", p.desc)                                             ; SetDescription
    if p.HasProp("icon")
        ComCall(17, lnk, "wstr", p.icon, "int", p.HasProp("iconIndex") ? p.iconIndex : 0)   ; SetIconLocation

    props := ComObjQuery(lnk, "{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")         ; IPropertyStore
    pkeyAumid := AhkPropKey("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}", 5)        ; PKEY_AppUserModel_ID
    AhkPropSet(props, pkeyAumid, p.aumid)

    pf := ComObjQuery(lnk, "{0000010B-0000-0000-C000-000000000046}")           ; IPersistFile
    ComCall(6, pf, "wstr", linkFile, "int", true)                              ; Save
}

AhkPropSet(props, key, value) {
    propvar := Buffer(24, 0)
    propref := ComValue(0x400C, propvar.Ptr)   ; VT_BYREF|VT_VARIANT。この後 propref[] への代入でBSTRとして値が書き込まれる
    propref[] := String(value)
    ComCall(6, props, "ptr", key, "ptr", propvar)   ; IPropertyStore::SetValue
    propref[] := 0
}

AhkPropKey(sguid, propID) {
    pk := Buffer(20)
    DllCall("ole32\IIDFromString", "wstr", sguid, "ptr", pk, "hresult")
    NumPut("int", propID, pk, 16)
    return pk
}

EnableStartup() {
    try FileCreateShortcut(A_ScriptFullPath, StartupShortcutPath(), A_ScriptDir), Flash("次回のWindows起動時から自動で立ち上がります", 1800)
    catch as e
        Flash("スタートアップ登録に失敗しました: " . e.Message, 2000)
}

DisableStartup() {
    try FileDelete(StartupShortcutPath()), Flash("自動起動を解除しました", 1800)
}

ActivateGitBash() {
    if WinExist("ahk_exe mintty.exe") {
        WinActivate
        return
    }
    for p in ["C:\Program Files\Git\git-bash.exe",
              "C:\Program Files (x86)\Git\git-bash.exe",
              A_AppData . "\..\Local\Programs\Git\git-bash.exe"] {
        if FileExist(p) {
            Run '"' p '"'
            return
        }
    }
    Flash("Git Bash が見つかりませんでした", 1500)
}

; ユーザー発のコピー操作を時刻だけ記録する(~でキー自体は素通し)
~^c::
~^x::
~^Ins:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}

; --- なぞってコピー: ドラッグ解放でCtrl+Cを送る（履歴追加はClipChangedに一本化） ---
~LButton:: {
    global dragX, dragY, dragT
    MouseGetPos &dragX, &dragY
    dragT := A_TickCount
}

~LButton up:: {
    global CopyOnSelect, dragX, dragY, dragT, LastLButtonUpTick, LastUserCopyTick
    LastLButtonUpTick := A_TickCount          ; コンテキストメニュー由来のコピーを救う(全アプリ対象)
    if !CopyOnSelect
        return
    MouseGetPos &x, &y
    dt := A_TickCount - dragT
    if (Abs(x - dragX) < 30 && Abs(y - dragY) < 30) || dt < 150 || dt > 15000
        return
    prev := A_Clipboard
    LastUserCopyTick := A_TickCount           ; フィルタを確実に通す
    Send("^c")
    Sleep 150
    if (A_Clipboard != "" && A_Clipboard != prev)
        Flash("コピーしました", 800)          ; 履歴追加はClipChangedに一本化
}

PushClipHistory(text) {
    global ClipHistory, ClipHistoryMax, ClipArchiveText, ClipHistoryPersist
    DiagBump("pushText")
    for i, v in ClipHistory
        if (v.type = "text" && v.text = text) {   ; 画像のプレースホルダー文字列と偶然一致しても誤爆しない
            ClipHistory.RemoveAt(i)   ; 重複は先頭へ昇格（時刻も更新される）
            break
        }
    now := NowWithWeekday()
    ClipHistory.InsertAt(1, {type: "text", text: text, time: now})
    while (ClipHistory.Length > ClipHistoryMax)
        ClipHistory.Pop()
    ; テキストは検疫キューへ。自動クリアで消えれば一度もディスクに書かれない(D節の核心)。
    ; archive.text(日次ログ)/history.persist(再起動を跨ぐストア)のどちらかがONなら検疫キューへ積む。
    ; 検疫そのもの(QueueTextArchive/CommitPendingArchive)には一切手を入れない。
    if (ClipArchiveText || ClipHistoryPersist)
        QueueTextArchive(text, now)
    RefreshLauncherHistory()   ; ランチャーが開いたままの間もタブ数字・リストをライブ反映
}

; FormatTimeの ddd はロケール依存で日本語曜日が出ないことがあるため自前マッピング
NowWithWeekday() {
    static wd := ["日", "月", "火", "水", "木", "金", "土"]
    return FormatTime(, "yyyy/MM/dd") . "(" . wd[FormatTime(, "WDay")] . ") " . FormatTime(, "HH:mm:ss")
}

; --- ワンショット整形/変換(Clibor同等化・第2ラウンド)。純関数のみ・履歴/ini/クリップボードに触らない ---
; LCMapStringW: AHKに全角半角・かな変換の組み込みが無いための正規ルート。LCID 0x0411(ja-JP)明示。
; カナの半全変換はロケール依存のため既定LCIDに任せない。変換で文字数は増減する
; (半角ｶﾞ=2単位→全角ガ=1単位、逆は1→2)ため、必要長の問い合わせ→バッファ確保の2段呼び出しが必須。
LCMapJa(text, flags) {
    if (text = "")
        return text
    n := DllCall("kernel32\LCMapStringW", "UInt", 0x0411, "UInt", flags
        , "Str", text, "Int", StrLen(text), "Ptr", 0, "Int", 0)
    if (n <= 0)
        return text                            ; 失敗時は原文のまま(fail-closed)
    buf := Buffer(n * 2, 0)
    n2 := DllCall("kernel32\LCMapStringW", "UInt", 0x0411, "UInt", flags
        , "Str", text, "Int", StrLen(text), "Ptr", buf, "Int", n)
    return n2 ? StrGet(buf, n2, "UTF-16") : text
}

; メニュー項目定義。fnは必ず「文字列→文字列」の純関数。
ClipTransformDefs() {
    static defs := 0
    if !defs
        defs := {format: [
            {name: "改行を除去して1行に",            fn: (t) => RegExReplace(t, "\R+", "")},
            {name: "改行を半角スペースに",          fn: (t) => RegExReplace(t, "\R+", " ")},
            {name: "前後の空白を削除",              fn: (t) => Trim(t, " `t`r`n　")},
            {name: "各行の行頭・行末の空白を削除",  fn: (t) => RegExReplace(t, "m)^[ `t　]+|[ `t　]+$", "")},
            {name: "連続する空白を1つに",           fn: (t) => RegExReplace(t, "[ `t　]{2,}", " ")},
            {name: "引用記号(>)を除去",             fn: (t) => RegExReplace(t, "m)^(>[ `t]?)+", "")}
        ], convert: [
            {name: "大文字に (ABC)",       fn: (t) => StrUpper(t)},
            {name: "小文字に (abc)",       fn: (t) => StrLower(t)},
            {name: "全角→半角 (英数カナ)", fn: (t) => LCMapJa(t, 0x00400000)},   ; LCMAP_HALFWIDTH
            {name: "半角→全角 (英数カナ)", fn: (t) => LCMapJa(t, 0x00800000)},   ; LCMAP_FULLWIDTH
            {name: "ひらがな→カタカナ",    fn: (t) => LCMapJa(t, 0x00200000)},   ; LCMAP_KATAKANA
            {name: "カタカナ→ひらがな",    fn: (t) => LCMapJa(t, 0x00100000)}    ; LCMAP_HIRAGANA
        ]}
    return defs
}

; AHK v2のforループ変数はクロージャに参照捕捉されるため、直接 (*) => PasteTransformed(v, d.fn) と
; 書くと全メニュー項目が最後のfnになる(実装後に整形1番目と6番目が異なる結果か必ず確認すること)。
; このファクトリ経由で束縛を固定する。
MakeTransformHandler(v, fn) {
    return (*) => PasteTransformed(v, fn)
}

; 通常選択=変換して貼り付け / Shiftを押しながら選択=変換結果をコピーのみ。
; 貼り付け経路はPasteText(SelfClipTick付き)なので変換結果は履歴に入らない(原文が履歴の正)。
; コピーのみ経路は素のA_Clipboard代入=監視が拾って先頭昇格(CopyHistoryItemと同じ意図された挙動)。
PasteTransformed(v, fn) {
    out := ""
    try out := fn(v.text)
    if (out = "") {
        Flash("結果が空になったため中止しました", 1500)
        return
    }
    copyOnly := GetKeyState("Shift", "P")
    CloseLauncher()
    if copyOnly {
        A_Clipboard := out
        Flash("変換結果をコピーしました（貼り付けはしていません）", 1400)
    } else
        PasteText(out)
}

^#c:: {
    global CopyOnSelect
    CopyOnSelect := !CopyOnSelect
    Flash(CopyOnSelect ? "なぞってコピー: ON" : "なぞってコピー: OFF", 1200)
}

; --- 右クリック長押し = 送信サジェスト ---
; 対応アプリ・Git Bash のみで有効。短押しは通常の右クリックのまま。
#HotIf CopyOnSelectApp() || WinActive("ahk_exe mintty.exe")
$RButton:: {
    global LongPressSec
    if KeyWait("RButton", "T" . LongPressSec) {
        Send("{Click Right}")
        return
    }
    KeyWait("RButton")
    if WinActive("ahk_exe mintty.exe") {
        Send("{Enter}")
        return
    }
    mode := CurrentSendMode()
    if (mode = "manual")
        Flash("このサイトは送信ボタンを押してください（自動送信非対応）", 1800)
    else
        Send("{Enter}")
}
#HotIf

; --- ミドルクリックで Git Bash を前面へ ---
#HotIf !WinActive("ahk_exe mintty.exe")
MButton::ActivateGitBash()
#HotIf
^#t::ActivateGitBash()
; Ctrl+Win+VはWindows標準のクリップボード履歴/絵文字パネルと衝突し、両方が同時に開いてしまう
; 現象が実機で確認された(2026-07-18)。ユーザー希望によりコントロールキー単押しに変更。
; ~LCtrl/~RCtrl up::は他のホットキーを妨げない(~)ため、Ctrl+C等の通常ショートカットは
; 従来通り動く。A_PriorKeyがCtrl自身でなければ「Ctrl+他のキー」の組み合わせ操作だったと
; 判定し、単押し(Ctrlだけを押して離した)のときだけランチャーを開く。
~LCtrl up::HandleCtrlUpForLauncher()
~RCtrl up::HandleCtrlUpForLauncher()
HandleCtrlUpForLauncher() {
    if (A_PriorKey = "LControl" || A_PriorKey = "RControl")
        ShowLauncher()
}

; --- サイドボタン(戻る): 押すとすぐクイックペースト（全アプリ・長押し判定なし） ---
XButton1::ShowLauncher()

; --- サイドボタン(進む): 短押し=カーソルのモニタを全画面スクショ / 長押し=範囲指定スクショ ---
XButton2:: {
    global LongPressSec, LastUserCopyTick
    if KeyWait("XButton2", "T" . LongPressSec) {
        LastUserCopyTick := A_TickCount        ; 自スクリプト発のSendはフックに乗らないため明示記録
        if !CaptureMonitorAtCursorToClipboard()
            Send("#{PrintScreen}")             ; 自前キャプチャ失敗時は従来のWin+PrintScreenへフォールバック
        return
    }
    KeyWait("XButton2")
    LastUserCopyTick := A_TickCount            ; Win+Shift+Sのクリップボードコピーもユーザー操作として認める
    Send("#+s")                                ; Windows標準の切り取り&スケッチ(範囲指定)
}

; PrintScreen(全画面/Alt+PrintScreenでアクティブウィンドウ)によるコピーもユーザー操作として認める
~PrintScreen::
~!PrintScreen:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}

; --- snippets.ini: ラベル=本文（\n で改行、run:パス で起動）---
; sites.iniパーサと違い、インラインコメント(;)は剥がさない — 本文に ; が入りうるため。
; IniRead は使わない（非ASCIIキー誤読の既知の罠。ラベルは日本語になる）。
LoadSnippets(path := "") {
    items := []
    if (path = "")
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

EditSnippetsFile(*) {
    path := A_ScriptDir . "\snippets.ini"
    if !FileExist(path)
        try FileAppend("; ラベル=本文（\n で改行、run:パス で起動）`n", path, "UTF-8")
    Run('notepad.exe "' . path . '"')
}

; RFC4180準拠の1行CSVパース（ダブルクォート囲み・""エスケープ・カンマ/改行含む値に対応）
; 呼び出し側はセル境界をまたぐ複数行フィールドがある場合を考慮し、行単位ではなく全文を渡すこと
ParseCsv(text) {
    rows := [], row := [], field := "", inQuotes := false
    i := 1, len := StrLen(text)
    while (i <= len) {
        c := SubStr(text, i, 1)
        if inQuotes {
            if (c = '"') {
                if (SubStr(text, i + 1, 1) = '"')
                    field .= '"', i++
                else
                    inQuotes := false
            } else
                field .= c
        } else {
            if (c = '"')
                inQuotes := true
            else if (c = ",") {
                row.Push(field), field := ""
            } else if (c = "`r") {
                ; 無視（`n側で改行確定）
            } else if (c = "`n") {
                row.Push(field), field := ""
                rows.Push(row), row := []
            } else
                field .= c
        }
        i++
    }
    if (field != "" || row.Length)
        row.Push(field), rows.Push(row)
    return rows
}

; CSV(label,body の2列)を読み、LoadSnippetsと同じ {label,value} 配列形式で返す
LoadSnippetsCsv(path) {
    items := []
    text := FileRead(path, "UTF-8")
    text := RegExReplace(text, "^\x{FEFF}")   ; BOM除去
    rows := ParseCsv(text)
    for idx, row in rows {
        if (idx = 1 && row.Length >= 2 && Trim(row[1]) = "label" && Trim(row[2]) = "body")
            continue   ; ヘッダー行はスキップ
        if (row.Length < 2)
            continue
        label := Trim(row[1]), val := row[2]
        if (label != "" && val != "")
            items.Push({label: label, value: val})
    }
    return items
}

; CliborエクスポートCSV(4列, CP932, BOMなし)の判定＋変換。非該当ならfalseを返しLoadSnippetsCsvへフォールバック。
; existing: 既存ラベル→本文 のMap（clearFirst時は空Mapを渡す）。冪等性(同一本文の再取込スキップ)判定に使う。
; 詳細は_docs/CLIBOR-CSV-IMPORT-DESIGN.md参照
TryLoadCliborCsv(path, existing) {
    text := FileRead(path, "CP932")
    rows := ParseCsv(text)
    if !CliborHeaderOk(rows) {
        ; UTF-8で書き出された変種の救済（BOM除去してもう一度だけ）
        text := RegExReplace(FileRead(path, "UTF-8"), "^\x{FEFF}")
        rows := ParseCsv(text)
        if !CliborHeaderOk(rows)
            return false
    }

    ; Cliborのグループ機能は使いづらいとの判断で不採用。ラベルにグループ名プレフィックスは付けない
    items := [], seen := Map()            ; seen: この取込内で確定したラベル→本文
    for idx, row in rows {
        if (idx = 1 || row.Length < 2)
            continue
        body := StrReplace(row[2], "`r`n", "`n")   ; クォート内CRLF正規化
        if (body = "")
            continue
        memo := row.Length >= 3 ? row[3] : ""
        base := CliborLabelBase(memo, body)
        label := base, n := 1
        while (existing.Has(label) || seen.Has(label)) {
            ; 同一本文なら真の重複 → スキップ（再取込の冪等性）
            if ((existing.Has(label) && existing[label] = body)
             || (seen.Has(label) && seen[label] = body)) {
                label := ""
                break
            }
            n++, label := base . " (" . n . ")"
        }
        if (label = "")
            continue
        seen[label] := body
        items.Push({label: label, value: body})
    }
    return items
}

; Clibor形式CSVのヘッダ行判定(4列: 定型文グループ,定型文,メモ,ホットキー)。誤コードページ読みは日本語が化けて必ず不一致になる。
CliborHeaderOk(rows) {
    return rows.Length >= 2 && rows[1].Length >= 4
        && Trim(rows[1][1]) = "定型文グループ" && Trim(rows[1][2]) = "定型文"
        && Trim(rows[1][3]) = "メモ" && Trim(rows[1][4]) = "ホットキー"
}

; Cliborの1件分からラベル素材を生成(メモ優先、空なら本文先頭20文字)し、ini形式を壊す文字をサニタイズする
CliborLabelBase(memo, body) {
    s := Trim(memo)
    if (s = "") {
        s := Trim(StrSplit(body, "`n", "`r")[1])   ; 本文の1行目
        s := SubStr(s, 1, 20)
    }
    s := StrReplace(s, "=", " ")          ; ini区切りの破壊防止
    s := RegExReplace(s, "^[;\[]+")       ; 行頭;/[ はコメント/セクション誤認
    s := Trim(RegExReplace(s, "\s+", " "))
    return (s != "") ? s : "取込"
}

; CSVフィールドとして安全な形にエスケープ（カンマ・改行・ダブルクォートを含む場合のみ囲む）
CsvField(s) {
    if InStr(s, '"') || InStr(s, ",") || InStr(s, "`n") || InStr(s, "`r")
        return '"' . StrReplace(s, '"', '""') . '"'
    return s
}

; 定型文をCSV(label,body)でエクスポート。他ツール(Excel等)との往復を想定した汎用形式。
; dlg=trueなら結果をCSVダイアログのステータス行に出す。falseならToolTip(Flash)。
; snippets(items配列)をCSVテキスト(ヘッダlabel,body)へ整形する共通ロジック。
; BOMはFileAppend(…,"UTF-8")がファイル新規作成時に自動付与するためここでは足さない
; (Chr(0xFEFF)を足すと二重BOMになりCSV読込側のヘッダ判定が壊れる。実機で発覚した既知の地雷)
SnippetsToCsvText(items) {
    out := "label,body`r`n"
    for s in items
        out .= CsvField(s.label) . "," . CsvField(s.value) . "`r`n"
    return out
}

ExportSnippetsCsv(dlg := false) {
    items := LoadSnippets()
    if (items.Length = 0) {
        dlg ? SetCsvStatus("エクスポートする定型文がありません") : Flash("エクスポートする定型文がありません", 1800)
        return
    }
    f := FileSelect("S16", A_ScriptDir . "\snippets.csv", "エクスポート先を選択", "CSVファイル (*.csv)")
    if (f = "")
        return
    if !RegExMatch(f, "i)\.csv$")
        f .= ".csv"
    try {
        if FileExist(f)
            FileDelete(f)
        FileAppend(SnippetsToCsvText(items), f, "UTF-8")
        msg := items.Length . " 件をCSVに書き出しました"
        dlg ? SetCsvStatus(msg) : Flash(msg, 1800)
    } catch as e {
        msg := "エクスポートに失敗しました: " . e.Message
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
    }
}

; 定型文フォルダ保存(既定OFF・オプトイン)。snippets.iniが変更されるたびに呼ばれ、
; template/snippets.csv を丸ごと上書きする(定型文は元々ファイル永続化済みなので検疫は不要)。
ArchiveSnippetsCsv() {
    global ClipArchiveText
    if !ClipArchiveText
        return
    dir := ArchiveSubDir("template")
    if (dir = "")
        return
    items := LoadSnippets()
    path := dir . "\snippets.csv"
    try {
        if FileExist(path)
            FileDelete(path)
        FileAppend(SnippetsToCsvText(items), path, "UTF-8")
    }
}

; 別ファイルから定型文を取り込む。既定は追記マージ（重複ラベルはスキップ）。
; clearFirst=true のときは snippets.ini を空にしてから取り込む（Clibor同様の「全クリアして取込」）。
; 拡張子で自動判別: .csv はCSVパーサ、それ以外(.ini/.txt)は既存のLoadSnippetsを流用。
; 書き込みはPromoteHistoryAtと同じ流儀（IniWrite不使用・UTF-8明示のFileAppend）
ImportSnippets(clearFirst := false, dlg := false) {
    f := FileSelect(1, , "取り込む定型文ファイルを選択", "定型文ファイル (*.ini; *.txt; *.csv)")
    if (f = "")
        return
    try if (FileGetSize(f) > 1024 * 1024) {
        msg := "ファイルが大きすぎます（1MB超）"
        dlg ? SetCsvStatus(msg) : Flash(msg, 1800)
        return
    }
    path := A_ScriptDir . "\snippets.ini"
    isClibor := false
    if RegExMatch(f, "i)\.csv$") {
        existing := Map()
        if !clearFirst
            for s in LoadSnippets()
                existing[s.label] := s.value
        incoming := TryLoadCliborCsv(f, existing)
        if incoming
            isClibor := true
        else
            incoming := LoadSnippetsCsv(f)   ; 従来のlabel,body形式
    } else
        incoming := LoadSnippets(f)
    if (incoming.Length = 0) {
        msg := "取り込める定型文が見つかりませんでした（ラベル=本文 の形式）"
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
        return
    }
    try {
        if clearFirst
            FileDelete(path)   ; 既存を全クリアしてから取り込む(確認はGUI側で取得済み)
        have := Map()
        for s in LoadSnippets()
            have[s.label] := 1
        nl := (FileExist(path) && !RegExMatch(FileRead(path, "UTF-8"), "\R$")) ? "`n" : ""
        added := 0
        for s in incoming {
            if have.Has(s.label)
                continue
            FileAppend(nl . s.label . "=" . StrReplace(s.value, "`n", "\n") . "`n", path, "UTF-8")
            nl := "", added++
        }
        ArchiveSnippetsCsv()                  ; 定型文フォルダ保存(ONの場合のみ)
        skipped := incoming.Length - added
        msg := (isClibor ? "Clibor形式として" : "") . added . " 件を取り込みました（重複 " . skipped . " 件はスキップ）"
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
    } catch as e {
        msg := "インポートに失敗しました: " . e.Message
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
    }
}

; SetCsvStatus: 定型文管理ウィンドウのステータス行に書く（CSV出力/取込の結果表示先）
SetCsvStatus(msg) {
    global SnipMgrStatus
    if SnipMgrStatus
        SnipMgrStatus.Text := msg
}

; ランチャー右上の歯車から開く設定メニュー。トレイメニューと同じ項目を抜粋して束ねる。
; 「設定...」「定型文の管理...」はそれぞれ自分の中でタイマーを止めたままウィンドウを開いたままにするため、
; m.Show()から戻った直後にここで無条件に150へ戻すと、その停止を踏みつけて即座にランチャーが
; 閉じてしまう(相手ウィンドウにフォーカスが移った瞬間タイマーが「非アクティブ」と誤検知する)。
; どちらかが可視(=そちらのウィンドウ経由でメニューを抜けた)ならタイマーは止めたままにする。
ShowLauncherSettingsMenu(*) {
    global LauncherGui, ClipWatchOn, SettingsGui, SnipMgrGui
    SetTimer(CheckLauncherFocus, 0)   ; メニュー表示中の誤クローズ防止(既存の履歴右クリックメニューと同じ流儀)
    m := Menu()
    m.Add("クリップボード監視を一時停止", ToggleClipWatch)
    m.Add("クリップボード履歴を全削除...", ConfirmDeleteHistoryAll)
    m.Add("定型文の管理...", ShowSnippetManager)
    m.Add("定型文ファイルを編集 (snippets.ini)", EditSnippetsFile)   ; 上級者向け(生のiniを直接編集)。通常は上のGUIで足りる
    m.Add("設定...", ShowSettingsWindow)
    m.Add("設定フォルダを開く", (*) => Run('explorer.exe "' . A_ScriptDir . '"'))
    if !ClipWatchOn
        m.Check("クリップボード監視を一時停止")
    m.Show()
    settingsOpen := IsObject(SettingsGui) && DllCall("IsWindowVisible", "Ptr", SettingsGui.Hwnd)
    snipMgrOpen := IsObject(SnipMgrGui) && DllCall("IsWindowVisible", "Ptr", SnipMgrGui.Hwnd)
    if (IsObject(LauncherGui) && !settingsOpen && !snipMgrOpen)
        SetTimer(CheckLauncherFocus, 150)
}

; --- 定型文の管理ウィンドウ（一覧＋編集フォーム＋CSV出力/取込を1画面に統合） ---
; snippets.iniは「1定型文=1行」の不変条件を持つため、保存/削除は行番号ベースの
; 行単位書き換えで行う（全文書き直しはコメント行消失・重複ラベル誤爆のリスクがあり不採用）。
global SnipMgrGui := 0, SnipMgrLV := 0, SnipMgrLabelEd := 0, SnipMgrBodyEd := 0
global SnipMgrStatus := 0, SnipMgrItems := [], SnipMgrClearChk := 0
global SnipMgrAllItems := []                  ; ini全項目(lineNo付き)。重複チェック・グループ抽出の母集団
global SnipMgrGroupDD := 0, SnipMgrSearchEd := 0   ; グループ絞り込みDropDownと検索Edit
global SnipMgrDragBar := 0                    ; -Caption化に伴う自前ドラッグバー(ランチャーと統一、v1.16.0〜)
global SnipMgrTab := 0, SnipMgrHistLV := 0, SnipMgrHistEd := 0, SnipMgrHistPrev := 0
global SnipMgrHistCount := 0, SnipMgrHistRows := [], SnipMgrHistNote := 0

; ランチャーが開いていればその右隣(画面からはみ出るなら左隣)に、無ければ画面上の固定位置に開く。
; ランチャーの真上に重なって隠すのを避けるため(SettingsGuiと同じフォーカス監視停止も併せて必要)。
SnipMgrPositionArgs(w, h) {
    global LauncherGui
    if !IsObject(LauncherGui)
        return "w" . w . " h" . h . " xCenter yCenter"
    LauncherGui.GetPos(&lx, &ly, &lw, &lh)
    mr := MonitorRectAtCursor()
    gap := 12
    x := lx + lw + gap
    if (mr && x + w > mr.r)
        x := lx - w - gap                 ; 右にはみ出るなら左隣にフォールバック
    y := ly
    return "w" . w . " h" . h . " x" . x . " y" . y
}

ShowSnippetManager(*) {
    global SnipMgrGui, SnipMgrLV, SnipMgrLabelEd, SnipMgrBodyEd, SnipMgrStatus, SnipMgrClearChk
    global SnipMgrTab, SnipMgrHistLV, SnipMgrHistEd, SnipMgrHistPrev, SnipMgrHistCount, LauncherGui, SnipMgrDragBar
    global SnipMgrHistNote, SnipMgrGroupDD, SnipMgrSearchEd
    ; ランチャーのフォーカス監視を止める(設定ウィンドウと同じ地雷: フォーカスが移った瞬間に誤クローズする)
    SetTimer(CheckLauncherFocus, 0)
    if SnipMgrGui {
        SnipMgrRefresh()               ; 外部編集(メモ帳/取込)を拾うため再表示時は必ず再読込
        SnipMgrHistRefresh()
        SnipMgrGui.Show(SnipMgrPositionArgs(600, 609))
        SetTimer(SnipMgrWatchDrag, 5)
        return
    }
    ; ランチャーと同じ「-Caption + 独自ドラッグバー」に統一(v1.16.0〜)。OS標準タイトルバーの
    ; 代わりに色付きバーでタイトルを出し、ドラッグ移動はSnipMgrWatchDragで自前実装する
    ; (LauncherWatchDragと同じ「Destroy後アクセス防止」パターンを踏襲。実クラッシュ既知の地雷)。
    SnipMgrGui := Gui("-Caption +ToolWindow")
    SnipMgrGui.SetFont("s9", "Meiryo UI")
    SnipMgrDragBar := SnipMgrGui.Add("Text", "x0 y0 w580 h18 BackgroundD4DCE8 c1A3E7A +0x100", "  定型文の管理")
    SnipMgrDragBar.SetFont("s9")
    ; 閉じるボタン(2026-07-18〜、ユーザー指摘: 閉じる手段が見た目に無い)。-Captionウィンドウ
    ; なのでOS標準の×は無く、ランチャーの歯車ボタン(1259行付近)と同じ「ドラッグバー右端のText+Click」
    ; パターンで自前実装する。Escapeキーでも閉じられる(827行のOnEvent)ことは変更しない。
    snipMgrCloseBtn := SnipMgrGui.Add("Text", "x580 y0 w20 h18 BackgroundD4DCE8 cGray Center +0x100", "×")
    snipMgrCloseBtn.SetFont("s11")
    snipMgrCloseBtn.OnEvent("Click", (*) => HideSnipMgr())
    SnipMgrTab := SnipMgrGui.Add("Tab3", "x0 y18 w600 h496 -Wrap", ["定型文", "履歴"])
    SnipMgrTab.OnEvent("Change", SnipMgrTabChanged)

    SnipMgrTab.UseTab(1)
    ; グループ絞り込み・検索(v1.17.0〜)。ラベルの「グループ/名前」規約(Clibor CSV取込が既に生成)で
    ; グループを自動抽出する。ini側にグループ専用のセクション等は一切追加しない(1定型文=1行の不変条件を守る)。
    SnipMgrGui.Add("Text", "x10 y58 w50 h20", "グループ")
    SnipMgrGroupDD := SnipMgrGui.Add("DropDownList", "x64 y54 w150", ["すべて"])
    SnipMgrGroupDD.OnEvent("Change", (*) => SnipMgrRefresh(true))
    SnipMgrGui.Add("Text", "x226 y58 w36 h20", "検索")
    SnipMgrSearchEd := SnipMgrGui.Add("Edit", "x264 y54 w326 h24")
    SnipMgrSearchEd.OnEvent("Change", (*) => SnipMgrRefresh(true))
    ; NoSort NoSortHdr が必須: ソートを許すと行番号↔SnipMgrItemsの対応が壊れ、
    ; 別の定型文を上書き・削除する事故につながる（この設定を外さないこと。アイコンだけ隠す等の
    ; 妥協案も不可 — 会議で出たが司令塔が却下済み。_docs/SNIPPET-MANAGER-CLIBOR-PARITY-DESIGN.md F-1参照）
    SnipMgrLV := SnipMgrGui.Add("ListView", "x10 y84 w580 h220 -Multi NoSort NoSortHdr +Grid",
        ["キー", "グループ", "ラベル", "本文"])
    SnipMgrLV.ModifyCol(1, 34), SnipMgrLV.ModifyCol(2, 96)
    SnipMgrLV.ModifyCol(3, 150), SnipMgrLV.ModifyCol(4, 280)
    SnipMgrLV.OnEvent("ItemSelect", SnipMgrOnSelect)
    SnipMgrGui.OnEvent("ContextMenu", SnipMgrContextMenu)

    SnipMgrGui.Add("Text", "x10 y318 w50 h20", "ラベル")
    SnipMgrLabelEd := SnipMgrGui.Add("Edit", "x64 y314 w300 h24")
    SnipMgrGui.Add("Text", "x10 y348 w50 h20", "本文")
    ; +WantReturn: 既定ボタンにEnterを食われず本文中に改行を打てるようにする
    SnipMgrBodyEd := SnipMgrGui.Add("Edit", "x64 y344 w526 h96 +Multi +WantReturn +VScroll")

    SnipMgrGui.Add("Button", "x64 y450 w100 h28", "新規追加").OnEvent("Click", SnipMgrAdd)
    SnipMgrGui.Add("Button", "x172 y450 w100 h28", "上書き保存").OnEvent("Click", SnipMgrSave)
    SnipMgrGui.Add("Button", "x280 y450 w80 h28", "削除").OnEvent("Click", SnipMgrDelete)
    SnipMgrGui.Add("Button", "x430 y450 w76 h28", "CSV出力").OnEvent("Click", (*) => ExportSnippetsCsv(true))
    SnipMgrGui.Add("Button", "x510 y450 w80 h28", "CSV取込").OnEvent("Click", SnipMgrImport)
    SnipMgrClearChk := SnipMgrGui.Add("CheckBox", "x430 y482 w160 h20", "全クリアして取込")

    ; --- 履歴タブ: 非永続のClipHistoryを検索・参照するだけのビュー(ペースト機能は持たせない) ---
    SnipMgrTab.UseTab(2)
    SnipMgrGui.Add("Text", "x10 y58 w40 h20", "検索")
    SnipMgrHistEd := SnipMgrGui.Add("Edit", "x54 y54 w280 h24")
    SnipMgrHistEd.OnEvent("Change", (*) => SnipMgrHistRefresh())
    SnipMgrHistCount := SnipMgrGui.Add("Text", "x344 y58 w246 h20 cGray", "")
    ; 履歴LVにもNoSort NoSortHdrを付ける: ソートされると行↔SnipMgrHistRows対応が崩れ、
    ; 選んだのと違う行がコピーされる事故になる（定型文タブと同じ理由）
    ; +0x40=LVS_SHAREIMAGELISTS: ランチャーとImageListを共有するため、このLVが破棄されても
    ; 共有ImageList(HistThumbIL)が道連れ破壊されないようにする(付け忘れると相互に壊れる)。
    SnipMgrHistLV := SnipMgrGui.Add("ListView", "x10 y84 w580 h240 -Multi NoSort NoSortHdr +Grid +0x40",
        ["コピー日時", "本文"])
    SnipMgrHistLV.ModifyCol(1, 150), SnipMgrHistLV.ModifyCol(2, 400)
    EnsureHistThumbIL()                       ; 画像履歴の実サムネイル表示用ImageList
    SnipMgrHistLV.SetImageList(HistThumbIL, 1)
    SnipMgrHistLV.OnEvent("ItemSelect", SnipMgrHistOnSelect)
    SnipMgrHistLV.OnEvent("DoubleClick", (lv, row) => SnipMgrHistCopy())
    SnipMgrGui.Add("Text", "x10 y334 w50 h20", "全文")
    SnipMgrHistPrev := SnipMgrGui.Add("Edit", "x64 y330 w526 h108 +ReadOnly +Multi +VScroll")
    SnipMgrGui.Add("Button", "x64 y446 w170 h28", "クリップボードへコピー").OnEvent("Click", SnipMgrHistCopy)
    SnipMgrHistNote := SnipMgrGui.Add("Text", "x244 y452 w340 h34 cGray", "")

    SnipMgrTab.UseTab()   ; 必須: 以降のステータス行を両タブ共通にする
    SnipMgrStatus := SnipMgrGui.Add("Text", "x10 y518 w400 h20 cGray", "")
    ; ブランドロゴ: ランチャーと同じ73x55を下部中央1箇所に統一(v1.16.0〜。以前は右上マーク+右下ロゴの2箇所に分散していた)。
    ; ステータス行(y518 h20→下端538)の直下・8px空けてy546に置いていたが、ロゴ高55pxを
    ; ウィンドウ高590に足すと601となり11pxはみ出て灰色背景から尻尾が出ていた(実機で発覚)。
    ; ウィンドウ高を601+下マージン8=609に伸ばして収める(座標側は変えない)。
    ; 読み込み失敗(ファイル欠落等)は機能に影響しないよう握りつぶす
    try SnipMgrGui.Add("Picture", "x264 y546 w73 h-1", A_ScriptDir . "\kimitolink-full-logo-73.png")

    SnipMgrGui.OnEvent("Close", (*) => HideSnipMgr())
    SnipMgrGui.OnEvent("Escape", (*) => HideSnipMgr())
    SnipMgrRefresh()
    SnipMgrHistRefresh()
    SnipMgrGui.Show(SnipMgrPositionArgs(600, 609))
    SetTimer(SnipMgrWatchDrag, 5)
}

; -Caption化に伴うドラッグバー移動監視。LauncherWatchDragと同じ実装パターン
; (Destroy後アクセス防止のtry/catch含む。既知の地雷 feedback_ahk_drag_race_condition と同型)。
SnipMgrWatchDrag() {
    global SnipMgrGui, SnipMgrDragBar
    if !(IsObject(SnipMgrGui) && IsObject(SnipMgrDragBar) && GetKeyState("LButton", "P")) {
        if !IsObject(SnipMgrGui)
            SetTimer(SnipMgrWatchDrag, 0)   ; ウィンドウ自体が無くなったらタイマーも止める
        return
    }
    MouseGetPos &mx, &my
    SnipMgrDragBar.GetPos(&bx, &by, &bw, &bh)
    SnipMgrGui.GetPos(&gx, &gy)
    if !(mx >= gx + bx && mx <= gx + bx + bw && my >= gy + by && my <= gy + by + bh)
        return
    winX := gx, winY := gy, startMx := mx, startMy := my
    while GetKeyState("LButton", "P") {
        if !IsObject(SnipMgrGui)
            return
        MouseGetPos &mx2, &my2
        try SnipMgrGui.Move(winX + (mx2 - startMx), winY + (my2 - startMy))
        catch
            return
        Sleep 5
    }
}

; 定型文の管理ウィンドウを閉じ、止めていたランチャーのフォーカス監視を再開する(HideSettingsWindowと同じ流儀)。
HideSnipMgr() {
    global SnipMgrGui, LauncherGui
    SetTimer(SnipMgrWatchDrag, 0)
    SnipMgrGui.Hide()
    if IsObject(LauncherGui)
        SetTimer(CheckLauncherFocus, 150)
}

SnipMgrTabChanged(tab, *) {
    if (tab.Value = 2)
        SnipMgrHistRefresh()
}

; ClipHistoryを検索語でフィルタし総入れ替え。履歴の永続化(v1.17.0〜)でメモリ保持件数が
; 最大10000件になりうるため、表示は2000件で打ち切る(検索自体は全件を対象に走査する)。
SnipMgrHistRefresh() {
    global ClipHistory, ClipHistoryMax, SnipMgrHistLV, SnipMgrHistEd, SnipMgrHistRows, SnipMgrHistCount, SnipMgrHistPrev
    global SnipMgrHistNote, ClipHistoryPersist
    static DisplayMax := 2000
    RebuildHistThumbILIfBloated()
    q := Trim(SnipMgrHistEd.Value)
    SnipMgrHistRows := []
    SnipMgrHistLV.Delete()
    for v in ClipHistory {                       ; 配列は常に新しい順（PushClipHistoryが先頭挿入）
        if (q != "" && !InStr(v.text, q, false) && !InStr(v.time, q, false))
            continue
        if (SnipMgrHistRows.Length >= DisplayMax)
            break
        SnipMgrHistRows.Push(v)                  ; インデックスでなく要素の参照を保持
        disp := StrReplace(StrReplace(v.text, "`r", ""), "`n", " ⏎ ")
        opt := (v.type = "image") ? "Icon" . (HistThumbIndex(v) + 1) : "Icon0"  ; Icon0省略不可(全行に1番目が出る既知の仕様)
        SnipMgrHistLV.Add(opt, v.time, SubStr(disp, 1, 100))
    }
    SnipMgrHistCount.Text := "表示" . SnipMgrHistRows.Length . "件 / 全" . ClipHistory.Length . "件"
        . (q != "" ? "（検索は全件対象）" : "")
    SnipMgrHistPrev.Value := ""
    ; 注記はhistory.persistの現在値に応じて動的化(「保存されません」は既定OFFのユーザーにとって
    ; 常に真であり続ける必要がある。看板同期の考え方は_docs/CLIPBOARD-HISTORY-PERSISTENT-STORE-DESIGN.md H節参照)
    SnipMgrHistNote.Text := ClipHistoryPersist
        ? "履歴は最大" . ClipHistory.Length . "件・再起動後もclip-archiveに保存中(設定で変更可)"
        : "履歴は最大" . ClipHistoryMax . "件・このPC内のみ・保存されません"
}

; ItemSelectは選択解除時もselected=falseで発火する。ここを無視すると
; 選択解除のたびに直前の行の内容がプレビューに残り続ける不具合になる。
SnipMgrHistOnSelect(lv, row, selected) {
    global SnipMgrHistRows, SnipMgrHistPrev
    if (!selected || row < 1 || row > SnipMgrHistRows.Length)
        return
    v := SnipMgrHistRows[row]
    SnipMgrHistPrev.Value := (v.type = "image")
        ? "画像 " . v.w . "×" . v.h . " — ダブルクリックまたはボタンで再コピーできます"
        : StrReplace(v.text, "`n", "`r`n")   ; Editの改行はCRLF
}

; コピー操作はクリップボード監視経由でPushClipHistoryを発火させ、その要素が
; 配列先頭へ移動しうる。SnipMgrHistRowsは要素の参照を保持しているためズレない。
SnipMgrHistCopy(*) {
    global SnipMgrHistLV, SnipMgrHistRows
    row := SnipMgrHistLV.GetNext(0)
    if (!row || row > SnipMgrHistRows.Length) {
        SetCsvStatus("コピーする履歴を選択してください")
        return
    }
    v := SnipMgrHistRows[row]
    if (v.type = "image") {
        if (dib := GetImageDib(v)) && SetClipboardImage(dib)
            SetCsvStatus("クリップボードへコピーしました")
        else
            SetCsvStatus("画像を再設定できませんでした")
        return
    }
    A_Clipboard := v.text
    SetCsvStatus("クリップボードへコピーしました")
}

; LoadSnippetsと同じ判定規則だが ini上の行番号を保持する(編集・削除の宛先に使う)
; LoadSnippets本体は改造しない(ランチャー側の呼び出し複数箇所への波及を避けるため)
SnipMgrReadItems() {
    items := [], path := A_ScriptDir . "\snippets.ini"
    if !FileExist(path)
        return items
    for n, raw in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
        line := Trim(raw)
        if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "[")
            continue
        eq := InStr(line, "=")
        if !eq
            continue
        label := Trim(SubStr(line, 1, eq - 1)), val := Trim(SubStr(line, eq + 1))
        if (label != "" && val != "")
            items.Push({label: label, value: StrReplace(val, "\n", "`n"), lineNo: n})
    }
    return items
}

; ラベルの「グループ/名前」規約(最初の/のみで分割・1階層限定)。Clibor CSV取込が既に生成している
; 事実上の標準に相乗りする。ini側にグループ専用の構造は一切追加しない。
SnipGroupOf(label) {
    p := InStr(label, "/")
    return p ? SubStr(label, 1, p - 1) : "（未分類）"
}
SnipNameOf(label) {
    p := InStr(label, "/")
    return p ? SubStr(label, p + 1) : label
}
; グループ絞り込み中 or 検索語ありなら true。並び替え禁止判定にも使う(表示上の隣=ini上の隣ではないため)。
SnipMgrFilterActive() {
    global SnipMgrGroupDD, SnipMgrSearchEd
    return (SnipMgrGroupDD.Text != "すべて") || (Trim(SnipMgrSearchEd.Value) != "")
}

; keepFilter=false(既定): iniを読み直しグループDDの選択肢も作り直す(外部編集・CSV取込後に使う)。
; keepFilter=true: グループDD/検索Editの操作時に使う。読み直しは行うが選択状態の維持を試みる。
SnipMgrRefresh(keepFilter := false) {
    global SnipMgrLV, SnipMgrItems, SnipMgrAllItems, SnipMgrGroupDD, SnipMgrSearchEd
    global SnipMgrLabelEd, SnipMgrBodyEd
    SnipMgrAllItems := SnipMgrReadItems()

    ; グループDD再構築。消えたグループを選んでいたら「すべて」へ戻す
    cur := SnipMgrGroupDD.Text
    groups := Map()
    for s in SnipMgrAllItems
        groups[SnipGroupOf(s.label)] := 1
    opts := ["すべて"]
    for g, _ in groups
        opts.Push(g)
    SnipMgrGroupDD.Delete()
    SnipMgrGroupDD.Add(opts)
    if !keepFilter || !groups.Has(cur)
        cur := "すべて"
    SnipMgrGroupDD.Choose(cur)

    q := Trim(SnipMgrSearchEd.Value)
    SnipMgrItems := []
    SnipMgrLV.Delete()
    for s in SnipMgrAllItems {
        g := SnipGroupOf(s.label)
        if (cur != "すべて" && g != cur)
            continue
        if (q != "" && !InStr(s.label, q) && !InStr(s.value, q))
            continue
        SnipMgrItems.Push(s)
        n := SnipMgrItems.Length
        prev := RegExReplace(s.value, "\s+", " ")
        ; キー列の番号は表示行基準(絞り込み後の1〜10)。数字キー選択と常に一致する
        SnipMgrLV.Add(, (n <= 10 ? Mod(n, 10) : ""), g, SnipNameOf(s.label),
            (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . SubStr(prev, 1, 80))
    }
    SnipMgrLabelEd.Value := "", SnipMgrBodyEd.Value := ""
}

; ItemSelectは選択解除時もselected=falseで発火する。ここを無視すると
; 選択解除のたびに直前の行の内容がフォームに残り続ける不具合になる。
SnipMgrOnSelect(lv, row, selected) {
    global SnipMgrItems, SnipMgrLabelEd, SnipMgrBodyEd
    if (!selected || row < 1 || row > SnipMgrItems.Length)
        return
    SnipMgrLabelEd.Value := SnipMgrItems[row].label
    SnipMgrBodyEd.Value := StrReplace(SnipMgrItems[row].value, "`n", "`r`n")   ; Editの改行はCRLF
}

; 数字キーホットキーのHotIf条件で使う。フォーカス無し等でthrowしうるのでtryで包み、
; 失敗時はfalse(=キー無効。fail-closed)。ラベル/本文/検索Editにフォーカスがある間は
; 数字キーを奪わないための唯一のガード(WinActiveだけでは入力欄の数字まで選択に化ける)。
SnipMgrLVFocused() {
    global SnipMgrGui, SnipMgrLV
    try return ControlGetFocus("ahk_id " . SnipMgrGui.Hwnd) = SnipMgrLV.Hwnd
    return false
}

; 一覧にフォーカスがある間だけ有効な数字キー1-9,0=「表示中のn行目を選択」。ペーストはしない。
SnipMgrPickKey(hk, *) {
    global SnipMgrLV, SnipMgrItems, SnipMgrTab
    if (SnipMgrTab.Value != 1)                 ; 履歴タブでは何もしない(定型文タブ専用)
        return
    n := (hk = "0") ? 10 : Integer(hk)
    if (n > SnipMgrItems.Length)
        return
    SnipMgrLV.Modify(n, "+Select +Focus Vis")
}

; Ctrl+Shift+F(第2ラウンド)。今アクティブなタブに応じて定型文/履歴どちらの検索欄へフォーカスするか切替。
; タブ未生成時のフォーカス失敗をtryでfail-closedに握る。
SnipMgrFocusSearch(*) {
    global SnipMgrTab, SnipMgrSearchEd, SnipMgrHistEd
    try (SnipMgrTab.Value = 1) ? SnipMgrSearchEd.Focus() : SnipMgrHistEd.Focus()
}

; 行単位の書換え/削除。書換え前に宛先行のラベルを検証し、外部編集でズレていたら中止(fail-closed)。
; これがメモ帳等での同時編集と競合して「別の定型文を壊す」事故を防ぐ唯一の防御。
SnipMgrWriteLine(lineNo, expectLabel, newLine) {
    path := A_ScriptDir . "\snippets.ini"
    lines := StrSplit(FileRead(path, "UTF-8"), "`n", "`r")
    if (lineNo > lines.Length || !RegExMatch(Trim(lines[lineNo]), "^\Q" . expectLabel . "\E\s*="))
        return false
    (newLine = "") ? lines.RemoveAt(lineNo) : lines[lineNo] := newLine
    out := ""
    for l in lines
        out .= l . "`n"
    FileDelete(path)
    FileAppend(RTrim(out, "`n") . "`n", path, "UTF-8")
    ArchiveSnippetsCsv()                      ; 定型文フォルダ保存(ONの場合のみ)
    return true
}

; 表示行aとbの定型文の「行内容」をini上で入れ替える(行を移動するのではなくスワップする)。
; これにより(a)他の全行の行番号が動かない、(b)間のコメント行・空行は元の位置に残る、
; (c)両行のラベルを検証し、片方でも外部編集でズレていたら何も書かない(fail-closed)。
SnipMgrSwapLines(a, b) {
    global SnipMgrItems
    ia := SnipMgrItems[a], ib := SnipMgrItems[b]
    path := A_ScriptDir . "\snippets.ini"
    lines := StrSplit(FileRead(path, "UTF-8"), "`n", "`r")
    if (ia.lineNo > lines.Length || ib.lineNo > lines.Length
        || !RegExMatch(Trim(lines[ia.lineNo]), "^\Q" . ia.label . "\E\s*=")
        || !RegExMatch(Trim(lines[ib.lineNo]), "^\Q" . ib.label . "\E\s*="))
        return false
    tmp := lines[ia.lineNo]
    lines[ia.lineNo] := lines[ib.lineNo], lines[ib.lineNo] := tmp
    out := ""
    for l in lines
        out .= l . "`n"
    FileDelete(path)
    FileAppend(RTrim(out, "`n") . "`n", path, "UTF-8")
    ArchiveSnippetsCsv()
    return true
}

; 右クリック「↑へ移動」「↓へ移動」の入口。境界・絞り込みチェック→スワップ→再選択。
; 絞り込み中の並び替えは禁止(表示上の隣=ini上の隣ではないため。メニュー側Disableとの二重防御)。
SnipMgrMove(row, delta) {
    global SnipMgrItems, SnipMgrLV
    dest := row + delta
    if (SnipMgrFilterActive() || dest < 1 || dest > SnipMgrItems.Length)
        return
    if SnipMgrSwapLines(row, dest) {
        SnipMgrRefresh()
        SnipMgrLV.Modify(dest, "+Select +Focus Vis")   ; 移動先を選択し直し、連続移動を可能にする
        SetCsvStatus("移動しました: " . SnipMgrItems[dest].label)
    } else {
        SnipMgrRefresh()
        SetCsvStatus("ファイルが外部で変更されていたため再読込しました。もう一度お試しください")
    }
}

; 定型文タブの一覧右クリックメニュー。編集/削除/↑↓移動/新規登録。
; マネージャー表示中はCheckLauncherFocusを既に止めている(ShowSnippetManager冒頭)ため、
; ランチャーのLauncherContextMenu流のタイマー停止/再開はしない(ここで再開すると
; ランチャー誤クローズ・表示中の挙動不整合を誘発するため何もしないのが正解)。
SnipMgrContextMenu(g, ctrl, item, isRC, x, y) {
    global SnipMgrLV, SnipMgrItems
    if (ctrl != SnipMgrLV)
        return
    m := Menu()
    if (item >= 1 && item <= SnipMgrItems.Length) {
        row := item
        SnipMgrLV.Modify(row, "+Select +Focus")
        m.Add("編集", (*) => SnipMgrEditRow(row))
        m.Add("削除", (*) => SnipMgrDelete())
        m.Add()
        m.Add("↑へ移動", (*) => SnipMgrMove(row, -1))
        m.Add("↓へ移動", (*) => SnipMgrMove(row, +1))
        if SnipMgrFilterActive() {
            m.Disable("↑へ移動"), m.Disable("↓へ移動")
        } else {
            (row = 1) && m.Disable("↑へ移動")
            (row = SnipMgrItems.Length) && m.Disable("↓へ移動")
        }
        m.Add()
    }
    m.Add("新規登録", (*) => SnipMgrNewForm())
    m.Show()
}

SnipMgrEditRow(row) {
    global SnipMgrLV, SnipMgrLabelEd
    SnipMgrOnSelect(SnipMgrLV, row, true)
    SnipMgrLabelEd.Focus()
}
SnipMgrNewForm(*) {
    global SnipMgrLabelEd, SnipMgrBodyEd
    SnipMgrLabelEd.Value := "", SnipMgrBodyEd.Value := ""
    SnipMgrLabelEd.Focus()
}

; フォーム値の取り出し共通部: CRLF→LF正規化＋ラベル無害化(PromoteHistoryAtと同一規則)
SnipMgrFormValues(&label, &body) {
    global SnipMgrLabelEd, SnipMgrBodyEd
    label := RegExReplace(Trim(SnipMgrLabelEd.Value), "[=\[\];]")
    body := StrReplace(SnipMgrBodyEd.Value, "`r`n", "`n")
    return (label != "" && body != "")
}

SnipMgrAdd(*) {
    global SnipMgrAllItems
    if !SnipMgrFormValues(&label, &body)
        return SetCsvStatus("ラベルと本文を入力してください")
    ; 重複チェックは必ず全件(SnipMgrAllItems)を見る。表示中のSnipMgrItemsは絞り込みで
    ; 部分集合になりうるため、それを見ると絞り込み中に重複ラベルの追加を通してしまう。
    for s in SnipMgrAllItems
        if (s.label = label)
            return SetCsvStatus("同じラベルが既に存在します: " . label)
    path := A_ScriptDir . "\snippets.ini"
    try {
        nl := (FileExist(path) && !RegExMatch(FileRead(path, "UTF-8"), "\R$")) ? "`n" : ""
        FileAppend(nl . label . "=" . StrReplace(body, "`n", "\n") . "`n", path, "UTF-8")
        ArchiveSnippetsCsv()                  ; 定型文フォルダ保存(ONの場合のみ)
        SnipMgrRefresh()
        SetCsvStatus("追加しました: " . label)
    } catch as e {
        SetCsvStatus("追加に失敗しました: " . e.Message)
    }
}

SnipMgrSave(*) {
    global SnipMgrLV, SnipMgrItems
    row := SnipMgrLV.GetNext(0)
    if (!row || row > SnipMgrItems.Length)
        return SetCsvStatus("一覧から編集する行を選んでください")
    if !SnipMgrFormValues(&label, &body)
        return SetCsvStatus("ラベルと本文を入力してください")
    item := SnipMgrItems[row]
    newLine := label . "=" . StrReplace(body, "`n", "\n")
    if SnipMgrWriteLine(item.lineNo, item.label, newLine) {
        SnipMgrRefresh()
        SetCsvStatus("保存しました: " . label)
    } else {
        SnipMgrRefresh()
        SetCsvStatus("ファイルが外部で変更されていたため再読込しました。もう一度お試しください")
    }
}

SnipMgrDelete(*) {
    global SnipMgrLV, SnipMgrItems
    row := SnipMgrLV.GetNext(0)
    if (!row || row > SnipMgrItems.Length)
        return SetCsvStatus("一覧から削除する行を選んでください")
    item := SnipMgrItems[row]
    if SnipMgrWriteLine(item.lineNo, item.label, "") {
        SnipMgrRefresh()
        SetCsvStatus("削除しました: " . item.label)
    } else {
        SnipMgrRefresh()
        SetCsvStatus("ファイルが外部で変更されていたため再読込しました。もう一度お試しください")
    }
}

SnipMgrImport(*) {
    global SnipMgrClearChk
    ImportSnippets(SnipMgrClearChk.Value, true)
    SnipMgrRefresh()
}

; 検索ボックスの入力変更で発火。現在のタブの一覧だけを絞り込み直す(もう一方は次回タブ切替時に絞り込む)。
; 絞り込み後は選択行が動くため数字キー対応の見た目上の番号もFillLauncher*で振り直される。
LauncherFilterChanged(edit, *) {
    global LauncherTab, LauncherLvH, LauncherLvS
    q := Trim(edit.Value)
    if (LauncherTab.Value = 1)
        FillLauncherHistoryLV(LauncherLvH, q)
    else
        FillLauncherSnippetsLV(LauncherLvS, q)
}

; 検索Editのプレースホルダー(未入力時のみ表示されるグレー文字)をWin32のEM_SETCUEBANNERで設定する。
; AutoHotkey v2にプレースホルダーの組み込みプロパティは無いため直接メッセージ送信する。
SetLauncherSearchPlaceholder(tabValue) {
    global LauncherSearchEdit
    if !IsObject(LauncherSearchEdit)
        return
    text := (tabValue = 1) ? "りんくがコピペ履歴を検索" : "りんくが定型文を検索"
    buf := Buffer(StrPut(text, "UTF-16"))
    StrPut(text, buf, "UTF-16")
    SendMessage(0x1501, 0, buf.Ptr, LauncherSearchEdit)   ; EM_SETCUEBANNER
}

; タブ切替時、検索語が入っていれば切替先のタブにも同じ絞り込みを適用する
; (検索ボックスは共通1つなので、片方のタブだけ絞り込んだままにしない)。
LauncherTabChanged(tab, *) {
    global LauncherSearchEdit, LauncherLvH, LauncherLvS
    SetLauncherSearchPlaceholder(tab.Value)
    q := IsObject(LauncherSearchEdit) ? Trim(LauncherSearchEdit.Value) : ""
    if (q = "")
        return
    (tab.Value = 1) ? FillLauncherHistoryLV(LauncherLvH, q) : FillLauncherSnippetsLV(LauncherLvS, q)
}

ShowLauncher() {
    global ClipHistory, LauncherGui, LauncherTarget, Snippets, LauncherTab, LauncherDragBar, LauncherLvH, LauncherLvS, LauncherHoverLast, ClipWatchOn, AppVersion, LauncherSearchEdit, LauncherHistFilterMap, LauncherSnipFilterMap, LauncherLvHHwnd, LauncherLvSHwnd
    Snippets := LoadSnippets()                ; 開くたびに読む: iniを編集→次の長押しで即反映
    if (ClipHistory.Length = 0 && Snippets.Length = 0) {
        Flash("履歴がありません（コピーすると貯まります）", 1800)
        return
    }
    LauncherHistFilterMap := [], LauncherSnipFilterMap := []   ; 前回開いたときの絞り込み状態を持ち越さない
    LauncherTarget := WinExist("A")
    CloseLauncher()
    ; +Borderの細い外枠が窮屈に見えるとの指摘(2026-07-18)により撤去。ウィンドウ境界はOS標準の
    ; 影・DWM縁取りに任せ、中身(F0F6FF背景)がそのまま画面いっぱいに見える構成にする。
    LauncherGui := Gui("-Caption +AlwaysOnTop +ToolWindow")
    ; WS_EX_COMPOSITED撤回(2026-07-18): スクショ撮影時のZ-order競合による白化を構造的に解決する
    ; 狙いで一度導入したが、実機で「スクショ操作と無関係に、ランチャーを開くたび常に真っ白」という
    ; 別の重大な副作用を引き起こすことが判明した(この環境のComctl32/DWM構成との相性問題と推測)。
    ; 撤去した状態で常時白化は解消(実機確認済み)。スクショ時の白化対策は、個別コントロールへの
    ; 明示的な再描画呼び出し(下記RedrawLauncherHeader等)で引き続き対応する。
    ; 詳細: _docs/LAUNCHER-REDRAW-ROOT-CAUSE-FIX.md(このファイルにも撤回の経緯を追記する)
    ; 履歴/定型文どちらのタブでも同じ水色に統一(タブ切替で背景色が変わる違和感があるとの
    ; ユーザー指摘: 2026-07-18)。リスト(ListView/ListBox)側の個別背景色も同じF0F6FFに揃えてある。
    LauncherGui.BackColor := "F0F6FF"
    ; 全体UX再設計(2026-07-18・_docs/LAUNCHER-UX-REDESIGN-DESIGN.md 第2歩)。旧構成は
    ; 「タイトル帯→検索行→タブ行→リスト」の4層縦積みで、出現直後の視線がリストに届くまで
    ; 3つの境界を越える必要があった。検索行を独立させず、タブ行(Tab3ヘッダーの右余白、元々
    ; 何も描かれない領域)に検索アイコン+Editを重ね配置し、「モード選択(タブ)」と「絞り込み
    ; (検索)」を1本の操作ヘッダーとして同列に扱う。会議で「検索を最優先で最上部に」という
    ; 案も出たが、実使用ではタブ切替(定型文か履歴か)が先行するため却下(設計書F節参照)。
    LauncherGui.SetFont("s12", "Meiryo UI")
    LauncherDragBar := LauncherGui.Add("Text", "x0 y0 w376 h16 BackgroundD4DCE8 c1A3E7A +0x100", "  君斗りんくの送信サジェスト")  ; SS_NOTIFY相当をv2既定に加え、押下を明示検知
    LauncherDragBar.SetFont("s8")
    LauncherGui.Add("Text", "x376 y2 w58 h12 BackgroundD4DCE8 cGray Right", "v" . AppVersion).SetFont("s8")   ; バージョンもシステム帯に統一(旧: 帯の外に浮いていた)
    gearBtn := LauncherGui.Add("Text", "x434 y0 w26 h16 BackgroundD4DCE8 cGray Center +0x100", "⚙")
    gearBtn.SetFont("s10")
    gearBtn.OnEvent("Click", ShowLauncherSettingsMenu)
    LauncherGui.SetFont("s12")
    LauncherTab := LauncherGui.Add("Tab3", "x0 y16 w460 -Wrap",
        ["履歴 " . ClipHistory.Length, "定型文 " . Snippets.Length])
    LauncherTab.OnEvent("Change", LauncherTabChanged)
    LauncherTab.UseTab()   ; ページ非所属に戻す: ここに足すコントロールはタブ切替に関わらず常時表示される
    LauncherGui.SetFont("s10")
    ; タブ2枚(「履歴 999」+「定型文 999」)の実描画幅は概ね165px。x188以降を検索域にすれば
    ; 3桁件数でも衝突しない。プレースホルダーは従来どおりSetLauncherSearchPlaceholderがタブ切替時に差し替える。
    try LauncherGui.Add("Picture", "x188 y20 w22 h22", A_ScriptDir . "\rinku-search-icon-22.png")
    LauncherSearchEdit := LauncherGui.Add("Edit", "x214 y19 w242 h24", "")
    LauncherSearchEdit.OnEvent("Change", LauncherFilterChanged)
    SetLauncherSearchPlaceholder(1)
    LauncherGui.SetFont("s12")
    rows := Min(Max(ClipHistory.Length, Snippets.Length, 3), 10)
    LauncherTab.UseTab(1)
    ; 履歴タブ: ListView化(1列・ヘッダなし)。+0x40=LVS_SHAREIMAGELISTS が生命線:
    ; これが無いとGui.Destroy()のたびに共有ImageList(HistThumbIL)が道連れ破壊される。
    RebuildHistThumbILIfBloated()             ; 充填前に肥大チェック(SnipMgrHistRefreshと同じ順序)
    ; リスト幅は460(ウィンドウ幅)いっぱいに広げる(2026-07-18、外枠の余白が邪魔とのユーザー指摘)。
    ; Tab3内のコンテンツ領域はx0起点でウィンドウ幅と一致するため、そのままw460で埋まる。
    LauncherLvH := LauncherGui.Add("ListView"
        , "w460 r" . rows . " -Hdr -Multi NoSort +0x40 BackgroundF0F6FF", ["履歴"])
    LauncherLvHHwnd := LauncherLvH.Hwnd       ; ゼブラストライプ用hwndキャッシュ(整数のみ・オブジェクト非保持)
    LauncherLvH.Opt("+LV0x10000")             ; LVS_EX_DOUBLEBUFFER: 再描画のチラつき防止
    EnsureHistThumbIL()
    LauncherLvH.SetImageList(HistThumbIL, 1)  ; 1=Small(レポート表示で使われる側)
    LauncherLvH.ModifyCol(1, 436)             ; 460 - スクロールバー/枠ぶん
    FillLauncherHistoryLV(LauncherLvH)
    LauncherLvH.OnEvent("ItemSelect", LauncherHistSelect)
    LauncherTab.UseTab(2)
    ; 定型文タブ: ListView化(1列・ヘッダなし、2026-07-18)。ListBox時代は事後Move()でスクロール
    ; バー計算が壊れる実機不具合(スタイルフラグの取り違え0x200→0x100修正後も再現)があり、
    ; 高さをr指定固定にしていた。ListViewはMove()後もスクロールバーが正常に動く(履歴タブで
    ; 実証済み)ため、定型文タブ自体をListView化して解消する。定型文にサムネイルは元々無いため
    ; ImageList/+0x40(LVS_SHAREIMAGELISTS)は付けない。詳細: _docs/LAUNCHER-SNIPPETS-LISTVIEW-DESIGN.md
    LauncherLvS := LauncherGui.Add("ListView"
        , "w460 r" . rows . " -Hdr -Multi NoSort BackgroundF0F6FF", ["定型文"])
    LauncherLvSHwnd := LauncherLvS.Hwnd       ; ゼブラストライプ用hwndキャッシュ(整数のみ・オブジェクト非保持)
    LauncherLvS.Opt("+LV0x10000")             ; LVS_EX_DOUBLEBUFFER: 白化(Z-order競合の再描画欠落)対策の本丸
    LauncherLvS.ModifyCol(1, 436)             ; 460 - スクロールバー/枠ぶん(履歴タブと同値)
    FillLauncherSnippetsLV(LauncherLvS)
    LauncherLvS.OnEvent("ItemSelect", LauncherSnipSelect)
    LauncherTab.UseTab()
    if (ClipHistory.Length = 0)
        LauncherTab.Value := 2                        ; 履歴が空なら定型文タブで開く
    ; r行指定はアイコン行高(約36px)を知らずに文字高で計算されるため、実測して合わせる。
    if (ih := LauncherLVItemHeight(LauncherLvH)) {
        listH := ih * rows + 6
        LauncherLvH.GetPos(&lvX, &lvY, , &lvH0)
        LauncherLvH.Move(, , , listH)
        LauncherLvS.Move(, , , listH)   ; ListViewはListBoxと違いMove()後もスクロールバー計算が正常(履歴タブで実証済み)
        LauncherTab.GetPos(&tX, &tY, , &tH0)
        LauncherTab.Move(, , , tH0 + (listH - lvH0))
    }
    ; ブランドフッター(2026-07-18 全体UX再設計・_docs/LAUNCHER-UX-REDESIGN-DESIGN.md 第1歩)。
    ; 過去2回、「リスト(ListView/ListBox)の実測下端」を起点にロゴ位置を導出しては、間違った
    ; コントロールに固定してしまう再修正(コミット8e19aff "Fix the logo-gap fix")を繰り返した。
    ; 導出元をリストから完全に切り離し、アンカーを「高さ調整後のTab3下端」の1点だけにする。
    ; これによりリストが3行でも10行でもロゴの位置は常に同一になり、再発の温床(複数コントロール
    ; の実測値を突き合わせる設計)自体を無くす。
    LauncherTab.GetPos(&tabX, &tY, &tabW, &tH)
    footerY := tY + tH
    ; ロゴは実寸73x55のまま中央揃えで表示(2026-07-18、32px縮小がユーザーに小さすぎると指摘され復元)。
    ; アンカーは引き続きTab3下端の1点のみ(リストの実測値は見ない、G-1節の再発防止の骨子は維持)。
    logoW := 73, logoH := 55, footerH := logoH + 8
    try LauncherGui.Add("Picture", "x" . (tabX + (tabW - logoW) // 2) . " y" . (footerY + 4) . " w" . logoW . " h-1",
        A_ScriptDir . "\kimitolink-full-logo-73.png")
    LauncherGui.Add("Text", "x0 y" . footerY . " w1 h" . footerH)   ; フッター帯の高さをウィンドウ計算に含めるための透明スペーサ
    LauncherGui.OnEvent("Escape", (*) => CloseLauncher())
    LauncherGui.OnEvent("ContextMenu", LauncherContextMenu)
    ; 画面上の固定位置に開く。マウスカーソルが画面下部にあると追従表示では毎回隠れて
    ; しまうという実運用フィードバックを受け、位置固定に変更(v1.13.0〜)。
    ; マルチモニタ環境では「カーソルがあるモニタ」の中央に出す(Cliborと同じ挙動、v1.14.2〜)。
    ; MonitorRectAtCursor()は範囲指定スクショ機能と共用の既存ヘルパー。
    ; GetPosはShow()より前だと高さ0を返す(未作成ウィンドウのため)ため、まず素の座標で
    ; 一度Showしてから実測の高さでMoveし直す2段階方式にする(実機で確認済みの地雷)。
    launcherW := 460
    LauncherGui.Show("w" . launcherW . " xCenter yCenter")
    if (mr := MonitorRectAtCursor()) {
        LauncherGui.GetPos(, , , &launcherH0)
        launcherX := mr.l + (mr.w - launcherW) // 2
        launcherY := mr.t + (mr.h - launcherH0) // 2
        LauncherGui.Move(launcherX, launcherY)
    }
    WinActivate("ahk_id " . LauncherGui.Hwnd)
    LauncherSearchEdit.Focus()   ; 検索EditはTab3の後に追加され既定フォーカスにならないため明示要求(出現直後に即タイプで絞り込めるように)
    DiagSchedulePaintProbe()   ; 描画実測プローブ(_docs/SHINDAN-PAINT-PROBE-DESIGN.md)
    ;@Ahk2Exe-IgnoreBegin
    DiagCaptureUiSnapshot(LauncherGui, "launcher")   ; レイアウト確定後・表示直後の1回だけ(開発ビルド専用)
    ;@Ahk2Exe-IgnoreEnd
    SetTimer(CheckLauncherFocus, 150)
    SetTimer(LauncherWatchDrag, 5)
    LauncherHoverLast := "", SetTimer(LauncherWatchHover, 120)
}

; 表示行(ListView/数字キー由来の1始まり行番号) → ClipHistoryの実インデックス。
; LauncherHistFilterMapが空(検索未使用)なら1:1のまま素通しする。
ResolveHistRow(displayRow) {
    global LauncherHistFilterMap
    if (LauncherHistFilterMap.Length = 0)
        return displayRow
    return (displayRow >= 1 && displayRow <= LauncherHistFilterMap.Length) ? LauncherHistFilterMap[displayRow] : 0
}

PasteHistoryAt(idx) {
    global ClipHistory
    if (idx < 1 || idx > ClipHistory.Length)
        return
    v := ClipHistory[idx]
    PromoteHistoryItemToTop(v)   ; 使うたびに先頭へ(定型文のPromoteSnippetToTopと同じ「直近使用順」思想)
    if (v.type = "image") {
        dib := GetImageDib(v)                 ; 降格画像はここでPNGからオンデマンド復元(失敗時はFlash済み)
        CloseLauncher()
        if dib
            PasteImage(dib)
        return
    }
    CloseLauncher()
    PasteText(v.text)
}

; 履歴を「使った」(貼り付けに選んだ)ときに先頭へ昇格し、時刻も現在時刻へ更新する。
; PushClipHistoryの重複昇格(662行)と同じ「常に新しい順・先頭積み」の不変条件に従う。
; 呼び出し元(PasteHistoryAt)は直後に必ずCloseLauncher()するため、ここでの再描画は不要
; (FillLauncherSnippetsLV系の全消去→再構築コストを、閉じる直前に無駄払いしない)。
PromoteHistoryItemToTop(v) {
    global ClipHistory
    for i, x in ClipHistory
        if (x = v) {                          ; オブジェクト同一性比較(AHK v2は参照比較)
            ClipHistory.RemoveAt(i)
            break
        }
    v.time := NowWithWeekday()                ; 「にコピー」ツールチップ表示も直近使用時刻に更新
    ClipHistory.InsertAt(1, v)
    if (v.type = "text")                      ; 画像はストア非対応(FinishHistoryStoreLoadがtype!=textを捨てる)
        HistStoreMarkPromoted(v.text, v.time)
}

; クリック(選択)→即ペースト。旧ListBox Changeイベントの後継(履歴タブのListView化に伴う)。
LauncherHistSelect(lv, row, selected) {
    if (!selected || GetKeyState("RButton", "P"))   ; 選択解除時と、右クリック由来の選択では発火させない
        return
    PasteHistoryAt(ResolveHistRow(row))
}

; クリック(選択)→即使用。旧ListBox Changeイベントの後継(定型文タブのListView化に伴う、2026-07-18)。
LauncherSnipSelect(lv, row, selected) {
    if (!selected || GetKeyState("RButton", "P"))   ; 選択解除時と、右クリック由来の選択では発火させない
        return
    UseSnippetAt(ResolveSnipRow(row))
}

; 表示行(ListBox/数字キー由来の1始まり行番号) → Snippetsの実インデックス。
; LauncherSnipFilterMapが空(検索未使用)なら1:1のまま素通しする。
ResolveSnipRow(displayRow) {
    global LauncherSnipFilterMap
    if (LauncherSnipFilterMap.Length = 0)
        return displayRow
    return (displayRow >= 1 && displayRow <= LauncherSnipFilterMap.Length) ? LauncherSnipFilterMap[displayRow] : 0
}

UseSnippetAt(idx) {
    global Snippets
    if (idx < 1 || idx > Snippets.Length)
        return
    s := Snippets[idx]
    CloseLauncher()
    PromoteSnippetToTop(s.label)   ; 使うたびに先頭へ(ココナラ/Chatworkの「直近が上」と同じ直近使用順)
    if (SubStr(s.value, 1, 4) = "run:") {
        target := Trim(SubStr(s.value, 5))
        try Run(target)
        catch
            Flash("起動できませんでした: " . target, 1800)
        return
    }
    PasteText(s.value)
}

; 定型文を使うたびにsnippets.iniの先頭行へ移動する(直近使用順)。ラベルで該当行を特定し、
; その行だけを削除して先頭に挿し直す(他の行の並びは相対的にそのまま・全文書き直しはしない)。
; 失敗は握りつぶす(fail-closed: 並び替えの失敗でペースト自体を止めない)。
PromoteSnippetToTop(label) {
    try {
        path := A_ScriptDir . "\snippets.ini"
        ; BOM付きで保存されたsnippets.ini(手編集・他ツール由来)にも対応するため明示除去(G-10相当)
        text := RegExReplace(FileRead(path, "UTF-8"), "^\x{FEFF}")
        lines := StrSplit(text, "`n", "`r")
        target := 0
        for n, raw in lines {
            line := Trim(raw)
            if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "[")
                continue
            eq := InStr(line, "=")
            if (eq && Trim(SubStr(line, 1, eq - 1)) = label) {
                target := n
                break
            }
        }
        if (target = 0 || target = 1)   ; 見つからない、または既に先頭なら何もしない
            return
        line := lines[target]
        lines.RemoveAt(target)
        lines.InsertAt(1, line)
        out := ""
        for l in lines
            out .= l . "`n"
        FileDelete(path)
        FileAppend(RTrim(out, "`n") . "`n", path, "UTF-8")
        ArchiveSnippetsCsv()
    }
}

PasteText(text) {
    global LauncherTarget, SelfClipTick
    SelfClipTick := A_TickCount
    A_Clipboard := text
    if (LauncherTarget && WinExist("ahk_id " . LauncherTarget))
        WinActivate("ahk_id " . LauncherTarget)
    Sleep 150
    Send("^v")
}

; --- グローバルクリップボード監視（ユーザー操作限定フィルタ付き） ---
; RDP/VM同期で載らないのは仕様（ローカルのキー・マウス操作を伴わないためフィルタで弾く）
ClipChanged(type) {
    global ClipWatchOn, SelfClipTick
    if (A_TickCount - SelfClipTick < 500) {   ; PasteText/SetClipboardImage等の自己書き込み
        DiagBump("selfSuppress")
        return
    }
    if (type = 0) {                           ; クリア → 自動クリア検知
        DiagBump("evtClear")
        MaybeDropAutoCleared()
        return
    }
    if (!ClipWatchOn) {
        DiagBump("watchOff")
        return
    }
    if ClipHasIgnoreFormat() {                ; パスワードマネージャの標準除外フォーマット(テキスト/画像共通)
        DiagBump("ignoreFormat")
        return
    }
    if (type = 1) {
        DiagBump("evtText")
        SetTimer(CaptureClip, -120)           ; 多重発火デバウンス(最後の発火から120ms後に1回)
    } else if (type = 2 && DllCall("IsClipboardFormatAvailable", "UInt", 8)) {  ; CF_DIB=8
        DiagBump("evtImage")
        SetTimer(CaptureClipImage, -120)
    }
}

CaptureClip() {
    global LastUserCopyTick, LastLButtonUpTick, ClipUserWindowMs, ClipMaxLen
    global LastCaptureText, LastCaptureTick
    DiagBump("capText")
    now := A_TickCount
    ; ★核心の安全策: 直近1秒以内のユーザー操作がなければ捨てる(fail-closed)
    if (now - LastUserCopyTick > ClipUserWindowMs) && (now - LastLButtonUpTick > ClipUserWindowMs) {
        DiagBump("rejUserText")
        return
    }
    if ClipSourceExcluded() {
        DiagBump("rejSource")
        return
    }
    text := ""
    try text := A_Clipboard                   ; 遅延レンダリング元が死んでいると失敗しうる
    if (text = "" || StrLen(text) > ClipMaxLen) {
        DiagBump("rejEmptyLong")
        return
    }
    LastCaptureText := text, LastCaptureTick := now
    PushClipHistory(text)
}

; --- クリップボード画像履歴 ---
; ハンドル(HBITMAP/HGLOBAL)は履歴に持ち越さない: GetClipboardDataの戻りはクリップボード側の
; 所有物で、他プロセスのEmptyClipboardで無効化されうる。開いている間にBufferへ即コピーする
; ことで、一時ファイルなしでもハンドル寿命問題を回避する(GDIハンドルを保持しないためDeleteObject
; の帳簿管理も不要になる)。

ClipOpen() {
    Loop 5 {                                  ; 他プロセスが握っていると失敗するためリトライ
        if DllCall("OpenClipboard", "Ptr", A_ScriptHwnd)
            return true
        Sleep 20
    }
    return false                              ; 諦め=捕捉しないだけ(fail-closed)
}

GetClipDib() {
    if !ClipOpen()
        return 0
    buf := 0
    try {
        hDib := DllCall("GetClipboardData", "UInt", 8, "Ptr")   ; CF_DIB
        if hDib {
            p := DllCall("GlobalLock", "Ptr", hDib, "Ptr")
            if p {
                sz := DllCall("GlobalSize", "Ptr", hDib, "UPtr")
                buf := Buffer(sz)
                DllCall("RtlMoveMemory", "Ptr", buf, "Ptr", p, "UPtr", sz)
                DllCall("GlobalUnlock", "Ptr", hDib)
            }
        }
    } finally DllCall("CloseClipboard")       ; 例外でも必ず閉じる(閉じ忘れはOS全体のコピペを止める)
    return buf
}

CaptureClipImage() {
    global LastUserCopyTick, LastLButtonUpTick, ClipUserWindowMs, ClipImageMaxBytes, ClipImageMinPx
    DiagBump("capImage")
    now := A_TickCount
    if (now - LastUserCopyTick > ClipUserWindowMs) && (now - LastLButtonUpTick > ClipUserWindowMs) {
        DiagBump("rejUserImage")
        return
    }
    if ClipSourceExcluded() {
        DiagBump("rejSource")
        return
    }
    dib := GetClipDib()
    if (!dib || dib.Size < 40) {                                  ; 40=BITMAPINFOHEADER最小
        DiagBump("rejDib")
        return
    }
    if (dib.Size > ClipImageMaxBytes) {
        DiagBump("rejSize")
        return
    }
    w := NumGet(dib, 4, "Int"), h := Abs(NumGet(dib, 8, "Int"))  ; biWidth/biHeight(トップダウンは負)
    if (w < ClipImageMinPx || h < ClipImageMinPx) {               ; 極小画像(意図しないノイズ)は弾く
        DiagBump("rejMinPx")
        return
    }
    PushClipImage(dib, w, h)
}

; 画像履歴「体感無制限」(2026-07-18・_docs/CLIPBOARD-IMAGE-UNLIMITED-DESIGN.md MVP)。
; ClipImageMax(既定5)は「メモリに生dibを持つホット窓の幅」に役割変更。数値は上げない
; ―― 上げてもリスト件数は増えない(超過分は削除ではなく「降格」されるだけなので、リストは
; 何百枚でも減らない)。降格 = v.DeleteProp("dib")してpngPath参照のみ残す(GetImageDib参照)。
PushClipImage(dib, w, h) {
    global ClipHistory, ClipHistoryMax, ClipImageMax, ClipArchiveImage
    DiagBump("pushImage")
    label := "📷 画像 " . w . "×" . h . " (" . Round(dib.Size / 1048576, 1) . "MB)"
    v := {type: "image", text: label, dib: dib, w: w, h: h, time: NowWithWeekday()}
    ClipHistory.InsertAt(1, v)
    ; 画像は検疫なし即保存(自動クリアはテキストのみ追跡するため対象外。D節参照)。降格の前提と
    ; なるpngPathはここで確定させる(失敗時はpngPath無し=このpushでは降格せず生dibのまま残す)。
    if (ClipArchiveImage && (dir := ArchiveSubDir("screenshot")) != "") {
        path := dir . "\img-" . FormatTime(, "yyyyMMdd-HHmmss") . ".png"
        if SaveDibAsPng(dib, w, h, path)
            v.pngPath := path
    }
    HistThumbIndex(v)                          ; dibがあるうちにサムネイルを焼く(降格後は生成不能)
    n := 0
    for i, elem in ClipHistory                 ; ホット窓超過: pngPath確定済みの画像だけ降格
        if (elem.type = "image" && ++n > ClipImageMax) {
            if elem.HasOwnProp("pngPath")
                elem.DeleteProp("dib")          ; 参照が切れ自動解放。リストからは消さない
            break                               ; 1回の追加で超過は最大1件
        }
    while (ClipHistory.Length > ClipHistoryMax) {
        i := ClipHistory.Length
        while (i >= 1 && ClipHistory[i].type = "image")   ; 末尾から見てテキストを優先的に間引く
            i--
        ClipHistory.RemoveAt(i > 0 ? i : ClipHistory.Length)
    }
    ; サムネイル生成(MakeHistThumb)のGDI/ImageList_Add操作の直後にListViewを即再描画すると、
    ; ランチャー表示中にリストが真っ白のまま残る不具合が実機で確認された(2026-07-18、サイド
    ; ボタンでのスクショ撮影時)。GDI操作の完了を待ってから再描画されるよう、次のメッセージ
    ; ループの空きに回す(-1msの0遅延タイマー)ことで解消を狙う。
    SetTimer(RefreshLauncherHistory, -1)
    ; 上記は履歴タブ(ListView)のみを再描画する。ランチャーが定型文タブ表示中にスクショを撮った
    ; 場合、履歴タブは裏で更新されるが表に見えている定型文タブは何の再描画トリガーも受けず、
    ; フラッシュ演出とのZ-order競合による白化がそのまま残ることが実機で確認された(2026-07-18)。
    ; アクティブなタブが定型文側なら、そちらも同様に強制再描画する。
    SetTimer(RedrawActiveLauncherSnippetsTab, -1)
    ; ヘッダー(Tab3・検索Edit)の再描画。過去の経緯(_docs/LAUNCHER-REDRAW-ROOT-CAUSE-FIX.md):
    ; ①ウィンドウ全体InvalidateRectはリスト側の-Redraw/+Redrawと競合し「リストだけ真っ白」を誘発
    ; ②ウィンドウ全体をWS_EX_COMPOSITED化する根本対策は、この環境で常時白化という別の重大な
    ;   副作用を起こしたため撤回(2026-07-18)。個別コントロールへのピンポイントな再描画に戻す。
    SetTimer(RedrawLauncherHeader, -1)
}

RedrawActiveLauncherSnippetsTab() {
    global LauncherGui, LauncherTab, LauncherLvS, LauncherSearchEdit
    if !(IsObject(LauncherGui) && IsObject(LauncherTab) && LauncherTab.Value = 2)
        return
    q := IsObject(LauncherSearchEdit) ? Trim(LauncherSearchEdit.Value) : ""
    FillLauncherSnippetsLV(LauncherLvS, q)
}

RedrawLauncherHeader() {
    global LauncherGui, LauncherTab, LauncherSearchEdit
    if !IsObject(LauncherGui)
        return
    if IsObject(LauncherTab)
        DllCall("InvalidateRect", "Ptr", LauncherTab.Hwnd, "Ptr", 0, "Int", true)
    if IsObject(LauncherSearchEdit)
        DllCall("RedrawWindow", "Ptr", LauncherSearchEdit.Hwnd, "Ptr", 0, "Ptr", 0
            , "UInt", 0x0001 | 0x0400)   ; RDW_INVALIDATE | RDW_FRAME(枠線ごと再描画)
}

; ホット窓に居ない(降格済み)画像はv.dibが無く、pngPathからオンデマンドで復元する。
; 復元したdibはvへ再キャッシュしない(ホット窓の計数=dib保有数が壊れるため)。
GetImageDib(v) {
    if v.HasOwnProp("dib")
        return v.dib
    if !v.HasOwnProp("pngPath")
        return 0
    dib := LoadPngAsDib(v.pngPath, v.w, v.h)
    if !dib
        Flash("画像ファイルが見つかりません", 1500)
    return dib
}

SetClipboardImage(dib) {
    global SelfClipTick
    hMem := DllCall("GlobalAlloc", "UInt", 0x2, "UPtr", dib.Size, "Ptr")  ; GMEM_MOVEABLE
    if !hMem
        return false
    p := DllCall("GlobalLock", "Ptr", hMem, "Ptr")
    DllCall("RtlMoveMemory", "Ptr", p, "Ptr", dib, "UPtr", dib.Size)
    DllCall("GlobalUnlock", "Ptr", hMem)
    if !ClipOpen() {
        DllCall("GlobalFree", "Ptr", hMem)    ; 開けなかったら自分で解放
        return false
    }
    ok := false
    try {
        SelfClipTick := A_TickCount           ; EmptyClipboardのtype=0通知より前に立てる(自己書込フィルタ)
        DllCall("EmptyClipboard")
        ok := DllCall("SetClipboardData", "UInt", 8, "Ptr", hMem, "Ptr") != 0
    } finally DllCall("CloseClipboard")
    if !ok
        DllCall("GlobalFree", "Ptr", hMem)    ; 成功時は所有権がOSに移るため触らない(触ると二重解放)
    return ok
}

PasteImage(dib) {
    global LauncherTarget
    if !SetClipboardImage(dib) {
        Flash("画像を再設定できませんでした", 1500)
        return
    }
    if (LauncherTarget && WinExist("ahk_id " . LauncherTarget))
        WinActivate("ahk_id " . LauncherTarget)
    Sleep 150
    Send("^v")
}

; --- カーソルがあるモニタだけの全画面スクショ（マルチモニタ対応） ---
; MonitorFromPointはPOINT構造体(x,yの8バイト)を1つの値として渡す必要がある。
; MONITOR_DEFAULTTONEAREST(=2)により、境界値でも必ずどこかのモニタを返す(fail-safe)。
MonitorRectAtCursor() {
    MouseGetPos(&mx, &my)
    pt := Buffer(8, 0)
    NumPut("Int", mx, pt, 0), NumPut("Int", my, pt, 4)
    hMon := DllCall("MonitorFromPoint", "Int64", NumGet(pt, 0, "Int64"), "UInt", 2, "Ptr")
    if !hMon
        return 0
    mi := Buffer(40, 0)                       ; MONITORINFO構造体
    NumPut("UInt", 40, mi, 0)                 ; cbSize(事前セット必須)
    if !DllCall("GetMonitorInfo", "Ptr", hMon, "Ptr", mi)
        return 0
    l := NumGet(mi, 4, "Int"), t := NumGet(mi, 8, "Int")   ; rcMonitor(offset 4-19)
    r := NumGet(mi, 12, "Int"), b := NumGet(mi, 16, "Int")
    return {l: l, t: t, r: r, b: b, w: r - l, h: b - t}
}

; 指定矩形(スクリーン座標)をBitBltでキャプチャしCF_DIB形式のBufferを返す。失敗時は0。
; SaveDibAsPngと同じGDIハンドル確保・解放パターン(GetDC/CreateCompatibleDC/SelectObject退避復帰)。
CaptureRectToDib(l, t, w, h) {
    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    if !hdcScreen
        return 0
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    bi := Buffer(40, 0)                       ; BITMAPINFOHEADER
    NumPut("UInt", 40, bi, 0), NumPut("Int", w, bi, 4), NumPut("Int", -h, bi, 8)   ; 負=トップダウン
    NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14), NumPut("UInt", 0, bi, 16)
    hBmp := DllCall("CreateDIBSection", "Ptr", hdcScreen, "Ptr", bi, "UInt", 0
        , "Ptr*", &pBits := 0, "Ptr", 0, "UInt", 0, "Ptr")
    ok := false
    if (hdcMem && hBmp && pBits) {
        hOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hBmp, "Ptr")
        ok := DllCall("BitBlt", "Ptr", hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Ptr", hdcScreen, "Int", l, "Int", t, "UInt", 0x00CC0020)   ; SRCCOPY
        DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOld, "Ptr")
    }
    dib := 0
    if ok {                                   ; SetClipboardImageが期待する「ヘッダ+ピクセル連続」形式に詰め直す
        rowBytes := w * 4
        dib := Buffer(40 + rowBytes * h)
        DllCall("RtlMoveMemory", "Ptr", dib, "Ptr", bi, "UPtr", 40)
        DllCall("RtlMoveMemory", "Ptr", dib.Ptr + 40, "Ptr", pBits, "UPtr", rowBytes * h)
        ; BitBltはアルファチャンネルを埋めないため0(透明)のまま残ることがある。
        ; CF_DIBに厳密なアルファ意味はなく、貼り付け先が透明=無描画と解釈する事故を防ぐため255で強制する。
        px := dib.Ptr + 40
        Loop w * h
            NumPut("UChar", 255, px, (A_Index - 1) * 4 + 3)
    }
    if hBmp
        DllCall("DeleteObject", "Ptr", hBmp)
    if hdcMem
        DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
    return dib
}

CaptureMonitorAtCursorToClipboard() {
    global ClipImageMaxBytes, ClipImageMinPx
    rect := MonitorRectAtCursor()
    if !IsObject(rect) {
        DiagBump("shotFail")
        return false
    }
    dib := CaptureRectToDib(rect.l, rect.t, rect.w, rect.h)
    if !dib {
        DiagBump("shotFail")
        return false
    }
    ok := SetClipboardImage(dib)
    if ok {
        ; 過去にランチャー(+AlwaysOnTop)表示中は同じ+AlwaysOnTopの暗転フラッシュとのZ-order競合で
        ; ランチャー内のListView(履歴/定型文)が白く残る不具合があり(2026-07-18)、一時的に
        ; 「ランチャー表示中はフラッシュをスキップ」で回避していた。しかし演出が無いと「撮れた
        ; か分からない」というユーザー体験の悪化が判明したため、根本対策(PushClipImage内で
        ; アクティブなランチャータブを強制再描画するRedrawActiveLauncherSnippetsTab等)に切替え、
        ; フラッシュ自体は常に出す形に戻した(2026-07-18)。
        FlashScreenRect(rect.l, rect.t, rect.w, rect.h)   ; Win+PrintScreenの暗転演出を模倣(撮影後なので画質に影響しない)
        ; SetClipboardImageが立てるSelfClipTickにより、ClipChanged→CaptureClipImage経路は
        ; 自己書込として遮断される(仕様通り・変更しない)。dibは手元にコピー済み所有なので、
        ; ここで直接履歴へ載せる。通常経路と同じサイズ/極小ガードを通す(fail-closed)。
        ; 詳細経緯: _docs/SELF-DIAGNOSTIC-INSTRUMENTATION-DESIGN.md C-4節
        if (dib.Size <= ClipImageMaxBytes && rect.w >= ClipImageMinPx && rect.h >= ClipImageMinPx) {
            PushClipImage(dib, rect.w, rect.h)
            DiagBump("shotDirect")
        } else
            DiagBump("shotDirectRej")
    } else
        DiagBump("shotFail")
    return ok
}

; 指定モニタ矩形を一瞬だけ黒くフラッシュさせる(Win+PrintScreen風の撮影フィードバック)
FlashScreenRect(l, t, w, h) {
    g := Gui("-Caption +ToolWindow +AlwaysOnTop +E0x20")   ; E0x20=WS_EX_TRANSPARENT(クリック等を素通し)
    g.BackColor := "000000"
    WinSetTransparent(120, g)
    g.Show("x" . l . " y" . t . " w" . w . " h" . h . " NoActivate")
    SetTimer(() => g.Destroy(), -120)
}

; --- 画像履歴の実サムネイル表示（「定型文の管理」の履歴タブのみ。ランチャーのListBoxは非対応） ---
; HBITMAPは生成関数のスコープ外に一切出さない: ImageList_Addは内部コピーなので、
; Add直後にDeleteObjectしてよい。要素にHBITMAPを持たせて使い回すことはしない
; （「ハンドルを持ち越さない」という画像履歴全体の設計思想を、表示層でも守るため）。
global HistThumbIL := 0

; ILの生成のみ。SetImageListでのビューへの紐付けは各呼び出し元の責務（ビューは複数あるため）。
EnsureHistThumbIL() {
    global HistThumbIL
    if HistThumbIL
        return
    HistThumbIL := DllCall("comctl32\ImageList_Create"
        , "Int", 48, "Int", 48, "UInt", 0x20, "Int", 4, "Int", 4, "Ptr")  ; ILC_COLOR32
    AddBlankHistThumb()   ; 0番目=生成失敗時のプレースホルダ。呼び出し側の"Icon".(idx+1)式で-1→0が誤画像を指す事故を防ぐ
}

; サムネイル生成失敗(MakeHistThumbが-1)時の受け皿として、ImageList 0番目に無地(白)画像を1枚登録する。
; MakeHistThumbと同じGDI確保・解放パターン(GetDC/CreateCompatibleDC/DeleteObject/DeleteDC/ReleaseDC)。
AddBlankHistThumb() {
    global HistThumbIL
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcM := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    hBmp := DllCall("CreateCompatibleBitmap", "Ptr", hdcS, "Int", 48, "Int", 48, "Ptr")
    if (hdcM && hBmp) {
        hOld := DllCall("SelectObject", "Ptr", hdcM, "Ptr", hBmp, "Ptr")
        rc := Buffer(16), NumPut("Int", 0, rc, 0), NumPut("Int", 0, rc, 4)
        NumPut("Int", 48, rc, 8), NumPut("Int", 48, rc, 12)
        DllCall("FillRect", "Ptr", hdcM, "Ptr", rc, "Ptr", DllCall("GetStockObject", "Int", 0, "Ptr"))  ; WHITE_BRUSH
        DllCall("SelectObject", "Ptr", hdcM, "Ptr", hOld, "Ptr")
        DllCall("comctl32\ImageList_Add", "Ptr", HistThumbIL, "Ptr", hBmp, "Ptr", 0, "Int")
    }
    if hBmp
        DllCall("DeleteObject", "Ptr", hBmp)
    if hdcM
        DllCall("DeleteDC", "Ptr", hdcM)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
}

; 孤児アイコン(履歴から間引かれても残り続けるImageList内の画像)によるメモリ肥大を防ぐ。
; 差し替え時はLVM_SETIMAGELISTが旧ILを破棄しないため明示的にImageList_Destroyする。
; HistThumbILは「定型文の管理」とランチャーで共有(LVS_SHAREIMAGELISTS)しているため、
; 再構築時は生存中の両ビューへ再アサイン→再充填してから、最後に旧ILを破棄する。
RebuildHistThumbILIfBloated() {
    global HistThumbIL, ClipHistory, SnipMgrHistLV, LauncherGui, LauncherLvH
    if (!HistThumbIL || DllCall("comctl32\ImageList_GetImageCount", "Ptr", HistThumbIL, "Int") <= 32)
        return
    old := HistThumbIL
    HistThumbIL := 0
    for v in ClipHistory
        if (v.type = "image")
            v.DeleteProp("thumbIdx")
    EnsureHistThumbIL()
    if IsObject(SnipMgrHistLV)                ; 未生成なら0
        try SnipMgrHistLV.SetImageList(HistThumbIL, 1)
    if IsObject(LauncherGui) {                 ; 理論上の競合窓(通常はフォーカス喪失で閉済み)も塞ぐ
        try {
            LauncherLvH.SetImageList(HistThumbIL, 1)
            FillLauncherHistoryLV(LauncherLvH)    ; 旧indexを持つ行を貼り替え
        }
    }
    DllCall("comctl32\ImageList_Destroy", "Ptr", old)   ; 再アサイン完了後に旧ILを破棄(この順序を守る)
}

; CF_DIB(BITMAPFILEHEADERなし)先頭からピクセルデータまでのオフセット。0=描画非対応(fail-closed)
; GDI+初期化をSaveDibAsPng/LoadPngAsDib間で共有する(プロセス生存中は1回だけ)。
EnsureGdiplus() {
    static gdipToken := 0
    if gdipToken
        return gdipToken
    DllCall("LoadLibrary", "Str", "gdiplus")
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0), NumPut("UInt", 1, si)
    if !DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken := 0, "Ptr", si, "Ptr", 0)
        return gdipToken
    return 0
}

DibBitsOffset(dib) {
    biSize  := NumGet(dib,  0, "UInt")    ; 40=INFOHEADER / 108=V4 / 124=V5
    bitCnt  := NumGet(dib, 14, "UShort")  ; biBitCount
    comp    := NumGet(dib, 16, "UInt")    ; biCompression
    clrUsed := NumGet(dib, 32, "UInt")    ; biClrUsed
    if (comp != 0 && comp != 3)           ; BI_RGB(0)/BI_BITFIELDS(3)以外(RLE/JPEG/PNG)は描かない
        return 0
    entries := (bitCnt <= 8) ? (clrUsed ? clrUsed : 1 << bitCnt) : clrUsed
    masks := (comp = 3 && biSize = 40) ? 12 : 0   ; V4/V5ヘッダはマスクをヘッダ内に内包する
    off := biSize + masks + entries * 4
    return (off < dib.Size) ? off : 0
}

; --- クリップボード履歴のフォルダ永続保存(v1.18.0〜既定ON。Cliborと同じ常時保存に合わせた) ---
; 非永続の原則を覆す経路。安全側の設計は2点:
; (1) テキストは検疫(45秒+2秒)を通過したものだけ書く＝自動クリア機構がそのままディスク書き込みの
;     拒否権として働く (2) 画像は検疫なし即保存(自動クリアはテキストのみ追跡するため対象外。
;     スクショは能動的な成果物で脅威モデルが違う)
; 既定ON化に伴いOFFへの切替はいつでも設定ウィンドウから可能(手動OFF時は保存済みファイルの
; 削除確認あり)。経緯・矛盾解消の論理は_docs/CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md参照

; --- SettingsStore: プログラム専有のsettings.iniを唯一の書き手として全文再生成する。 ---
; 所有権分離の核: sites.ini/snippets.iniは人間所有(既存のFileDelete+FileAppend(UTF-8)流儀を維持)、
; settings.iniはプログラム所有(read-modify-writeをせず毎回全文組み立て→原子リネーム)。
; 旧SaveIniKey(sites.ini内[clipboard]セクションへの挿入位置バグの温床)はこの機構で置き換え、削除した。
; 経緯・設計判断は_docs/SETTINGS-UNIFICATION-DESIGN.md参照
global SettingsMap := Map()
global SettingsDirty := false

; apply先の各関数。矢印関数(fat arrow)はグローバル変数への代入がスコープに反映されない
; (実機で確認済みの地雷: (v)=>(G:=v)は外側のGを更新せず握りつぶす)ため、必ず名前付き関数+global宣言にする。
ApplyClipWatchSetting(v) {
    global ClipWatchOn
    ClipWatchOn := (v != "off")
}
ApplyArchiveImageSetting(v) {
    global ClipArchiveImage
    ClipArchiveImage := (v = "on")
}
ApplyArchiveTextSetting(v) {
    global ClipArchiveText
    ClipArchiveText := (v = "on")
}
ApplyFirstRunPromptedSetting(v) {
}
; 診断ページ自動送信の同意フラグ(2026-07-18・_docs/SHINDAN-AUTO-SEND-DESIGN.md)。
; 値そのものはSettingsMap経由でSetSetting()が保存する。ここでは特に反映処理は不要(空関数)。
; キー欠落・値不一致は全てConsentDiagSend()側で「未同意」扱いにする許可リスト方式(fail-closed)。
ApplyDiagConsentedSetting(v) {
}
; 名前付き関数+global宣言で書く(fat arrow「(v)=>(ClipHistoryPersist:=v)」は握りつぶされる既知の地雷)。
ApplyHistoryPersistSetting(v) {
    global ClipHistoryPersist
    ClipHistoryPersist := (v = "on")
}
ApplyHistLoadMaxSetting(v) {
    global ClipHistLoadMax
    n := Integer(v)
    ClipHistLoadMax := (n > 0) ? Max(100, Min(n, 100000)) : 10000   ; 異常値はクランプ(fail-closed)
}

; キー → {section, default, apply(val)}。GUIとsettings.iniのグルーピングの単一の正本。
SettingDefsInit() {
    global SettingDefs
    SettingDefs := Map(
        "clipboard.watch", {section: "clipboard", default: "on", apply: ApplyClipWatchSetting},
        "archive.image", {section: "archive", default: "on", apply: ApplyArchiveImageSetting},
        "archive.text", {section: "archive", default: "on", apply: ApplyArchiveTextSetting},
        "state.firstrunprompted", {section: "state", default: "0", apply: ApplyFirstRunPromptedSetting},
        "history.persist", {section: "history", default: "on", apply: ApplyHistoryPersistSetting},
        "history.loadmax", {section: "history", default: "10000", apply: ApplyHistLoadMaxSetting},
        "diag.consented", {section: "diag", default: "no", apply: ApplyDiagConsentedSetting}
    )
}
global SettingDefs := Map()

SetSetting(key, val) {
    global SettingsMap, SettingsDirty, SettingDefs
    SettingsMap[key] := val
    ; プロパティ経由の暗黙呼び出し(obj.applyFn(v))は不安定なため.Call()を明示する(実機で確認済みの地雷)。
    if SettingDefs.Has(key)
        SettingDefs[key].apply.Call(val)
    SettingsDirty := true
    SetTimer(FlushSettings, -300)   ; 連打をデバウンスでまとめる。負値=1回きりのワンショット
}

; 引数名を"map"にしない: AutoHotkey v2はパラメータ名で組み込みMap()をシャドーイングし、
; 関数内のMap()呼び出しが「値をCallしようとしてMethod not found」エラーになる(実機で確認済みの地雷)。
BuildSettingsText(settingsMap) {
    global SettingDefs
    bySection := Map()
    for key, def in SettingDefs {
        sec := def.section
        if !bySection.Has(sec)
            bySection[sec] := Map()
        name := SubStr(key, InStr(key, ".") + 1)
        bySection[sec][name] := settingsMap.Has(key) ? settingsMap[key] : def.default
    }
    txt := "; このファイルは送信サジェストが自動管理します。手で編集しても次の設定変更で上書きされます。`n"
        . "; 設定はトレイ →「設定...」から。送信ルールは sites.ini、定型文は snippets.ini へ。`n"
        . "[app]`n" . "version=" . AppVersion . "`n`n"
    for sec, kv in bySection {
        txt .= "[" . sec . "]`n"
        for name, v in kv
            txt .= name . "=" . v . "`n"
        txt .= "`n"
    }
    return txt
}

; 全文再生成→tmp書き→原子リネーム。read-modify-writeをしないため挿入位置バグが構造的に起きない。
; settings.iniのみFileOpen(w,UTF-8-RAW)を使う(新規作成でもBOMが構造的に発生しない)。
; sites.ini/snippets.iniへの既存書き込み経路はrefactor-instructions.md §3の絶対制約どおり変更しない。
FlushSettings() {
    global SettingsMap, SettingsDirty
    if !SettingsDirty
        return
    txt := BuildSettingsText(SettingsMap)
    path := A_ScriptDir . "\settings.ini"
    tmp := path . ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        f.Write(txt)
        f.Close()
        if !DllCall("MoveFileExW", "WStr", tmp, "WStr", path, "UInt", 0x1 | 0x8)   ; REPLACE_EXISTING|WRITE_THROUGH
            throw OSError()
        SettingsDirty := false
    } catch as e {
        try FileDelete(tmp)
        Flash("設定の保存に失敗しました(次の変更時に再試行します)", 2000)
    }
}

; 先頭のBOM(EF BB BF)をスキップして読む。過去に別経路で生成された可能性のあるBOM付きファイルの後方互換。
ReadSettingsIniText(path) {
    txt := FileRead(path, "UTF-8")
    return RegExReplace(txt, "^\x{FEFF}")
}

LoadSettingsIni() {
    global SettingsMap, SettingDefs
    path := A_ScriptDir . "\settings.ini"
    section := ""
    for line in StrSplit(ReadSettingsIniText(path), "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        if RegExMatch(line, "^\[(.+)\]$", &m) {
            section := Trim(m[1])
            continue
        }
        eq := InStr(line, "=")
        if !eq
            continue
        name := Trim(SubStr(line, 1, eq - 1))
        val := Trim(SubStr(line, eq + 1))
        key := section . "." . name
        if SettingDefs.Has(key) {
            SettingsMap[key] := val
            SettingDefs[key].apply.Call(val)
        }
    }
}

; 起動時1回だけ実行。settings.iniが無ければsites.ini/startup-prompted.flagから現在有効値を吸い上げて生成。
; 失敗しても現行動作のまま継続する(fail-closed: 移行の失敗が機能停止にならない)。
MigrateSettingsIfNeeded() {
    global SettingsMap, SettingsDirty, SettingDefs, ClipWatchOn, ClipArchiveImage, ClipArchiveText
    path := A_ScriptDir . "\settings.ini"
    if FileExist(path)
        return
    try {
        sitesPath := A_ScriptDir . "\sites.ini"
        if FileExist(sitesPath) {
            bak := A_ScriptDir . "\sites.ini.bak-" . FormatTime(, "yyyyMMdd")
            if !FileExist(bak)
                FileCopy(sitesPath, bak)
        }
        ; LoadSitesConfig()はこの時点で既に実行済みなので、グローバル変数の現在値をそのまま引き継ぐ
        SettingsMap["clipboard.watch"] := ClipWatchOn ? "on" : "off"
        SettingsMap["archive.image"] := ClipArchiveImage ? "on" : "off"
        SettingsMap["archive.text"] := ClipArchiveText ? "on" : "off"
        flagPath := A_ScriptDir . "\startup-prompted.flag"
        if FileExist(flagPath) {
            SettingsMap["state.firstrunprompted"] := "1"
            FileDelete(flagPath)
        }
        SettingsDirty := true
        FlushSettings()
    } catch as e {
        Flash("設定ファイルの初期化に失敗しました(既定値のまま起動します)", 2000)
    }
}

; ベースフォルダ(サブフォルダ分けなし)。ArchiveSubDirはこの配下にscreenshot/history/templateを作る
ArchiveBaseDir() {
    global ClipArchiveDir
    return (ClipArchiveDir != "") ? ClipArchiveDir : A_ScriptDir . "\clip-archive"
}

; サブフォルダ("screenshot"|"history"|"template")を解決＋作成。
; 作れなければ空文字を返し呼び出し元で保存をスキップする(fail-closed)
ArchiveSubDir(sub) {
    dir := ArchiveBaseDir() . "\" . sub
    try DirCreate(dir)
    return DirExist(dir) ? dir : ""
}

; トレイ「保存フォルダを開く」用。まだ何も保存されていなければ新規作成せず案内する
OpenArchiveDir(*) {
    dir := ArchiveBaseDir()
    if DirExist(dir)
        Run('explorer.exe "' . dir . '"')
    else
        Flash("まだ何も保存されていません", 1800)
}

; PNGエンコーダをGdipGetImageEncodersで列挙して探す(CLSID直指定より環境差異に強い)
PngEncoderClsid() {
    DllCall("gdiplus\GdipGetImageEncodersSize", "UInt*", &count := 0, "UInt*", &size := 0)
    if !size
        return 0
    buf := Buffer(size)
    if DllCall("gdiplus\GdipGetImageEncoders", "UInt", count, "UInt", size, "Ptr", buf)
        return 0
    ; PNGのCLSIDはGDI+仕様上の既知の固定値(Microsoft公式ドキュメントで確認済み)
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    return clsid
}

; CF_DIB→BMPファイル(BITMAPFILEHEADER14B+DIB丸書き)。PNG保存の失敗時フォールバック。
SaveDibAsBmp(dib, path) {
    off := DibBitsOffset(dib)
    if !off
        return false
    hdr := Buffer(14, 0)
    NumPut("UShort", 0x4D42, hdr, 0)          ; "BM"
    NumPut("UInt", 14 + dib.Size, hdr, 2), NumPut("UInt", 14 + off, hdr, 10)
    try {
        f := FileOpen(path, "w")
        f.RawWrite(hdr, 14), f.RawWrite(dib, dib.Size), f.Close()
        return true
    } catch
        return false
}

; CF_DIB→PNGファイル。既存MakeHistThumbと同じStretchDIBits経由でHBITMAP化してからGDI+化する
; (CF_DIBから直接GdipCreateBitmapFromGdiDibを使わず、既存資産と手法を揃える)。失敗時はBMPへ。
SaveDibAsPng(dib, w, h, path) {
    off := DibBitsOffset(dib)
    if !off
        return SaveDibAsBmp(dib, StrReplace(path, ".png", ".bmp"))
    if !EnsureGdiplus()
        return SaveDibAsBmp(dib, StrReplace(path, ".png", ".bmp"))
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcM := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    hBmp := DllCall("CreateCompatibleBitmap", "Ptr", hdcS, "Int", w, "Int", h, "Ptr")
    ok := false
    if (hdcM && hBmp) {
        hOld := DllCall("SelectObject", "Ptr", hdcM, "Ptr", hBmp, "Ptr")
        DllCall("StretchDIBits", "Ptr", hdcM, "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Ptr", dib.Ptr + off, "Ptr", dib, "UInt", 0, "UInt", 0x00CC0020)
        DllCall("SelectObject", "Ptr", hdcM, "Ptr", hOld, "Ptr")
        pBmp := 0
        if !DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hBmp, "Ptr", 0, "Ptr*", &pBmp) && pBmp {
            clsid := PngEncoderClsid()
            if clsid
                ok := !DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBmp, "Str", path, "Ptr", clsid, "Ptr", 0)
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
        }
    }
    if hBmp
        DllCall("DeleteObject", "Ptr", hBmp)
    if hdcM
        DllCall("DeleteDC", "Ptr", hdcM)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
    return ok ? true : SaveDibAsBmp(dib, StrReplace(path, ".png", ".bmp"))
}

; PNGファイル→CF_DIB形式のBuffer(CaptureRectToDibと同じ「40byteヘッダ+ピクセル連続・トップダウン
; 32bit」形式)。SetClipboardImage/PasteImageがそのまま食える。降格画像の貼り付け時にのみ呼ぶ
; (ホット窓の5枚はdibを直接持っているためこの経路を通らない)。失敗時は0。
LoadPngAsDib(path, w, h) {
    if !EnsureGdiplus() || !FileExist(path)
        return 0
    pBmp := 0
    if DllCall("gdiplus\GdipCreateBitmapFromFile", "Str", path, "Ptr*", &pBmp) || !pBmp
        return 0
    hBmp := 0
    ok := !DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBmp, "Ptr*", &hBmp, "UInt", 0xFFFFFFFF)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
    if (!ok || !hBmp)
        return 0
    dib := 0
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcM := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    if hdcM {
        bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0), NumPut("Int", w, bi, 4), NumPut("Int", -h, bi, 8)
        NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14), NumPut("UInt", 0, bi, 16)
        rowBytes := w * 4
        pxBuf := Buffer(rowBytes * h)
        if DllCall("GetDIBits", "Ptr", hdcM, "Ptr", hBmp, "UInt", 0, "UInt", h
            , "Ptr", pxBuf, "Ptr", bi, "UInt", 0) {
            dib := Buffer(40 + rowBytes * h)
            DllCall("RtlMoveMemory", "Ptr", dib, "Ptr", bi, "UPtr", 40)
            DllCall("RtlMoveMemory", "Ptr", dib.Ptr + 40, "Ptr", pxBuf, "UPtr", rowBytes * h)
            px := dib.Ptr + 40                ; PNGは既にアルファ確定だが、CF_DIB側の透明誤解釈を防ぐため255固定(CaptureRectToDibと同一方針)
            Loop w * h
                NumPut("UChar", 255, px, (A_Index - 1) * 4 + 3)
        }
        DllCall("DeleteDC", "Ptr", hdcM)
    }
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
    DllCall("DeleteObject", "Ptr", hBmp)
    return dib
}

; テキストの検疫キュー投入。ClipAutoClearSec+2秒を過ぎたものだけCommitPendingArchiveが書く。
; この待ち時間こそが「パスワードマネージャの自動クリアがディスク書き込みを止める」仕組みの核心。
; timeStrはPushClipHistoryが履歴要素に入れたのと同じ捕捉時刻(曜日付き)。history-store.csvの
; 復元表示を捕捉時と完全一致させるために持ち回る(ClipArchiveTextのみの場合は使わない)。
QueueTextArchive(text, timeStr := "") {
    global PendingArchive
    PendingArchive.Push({text: text, tick: A_TickCount, time: timeStr})
    SetTimer(CommitPendingArchive, 5000)
}

CommitPendingArchive() {
    global PendingArchive, ClipAutoClearSec, ClipArchiveText, ClipHistoryPersist
    windowMs := ClipAutoClearSec * 1000 + 2000   ; +2秒: クリア通知との競合マージン
    i := 1
    while (i <= PendingArchive.Length) {
        p := PendingArchive[i]
        if (A_TickCount - p.tick >= windowMs) {
            if ClipArchiveText {
                dir := ArchiveSubDir("history")
                if (dir != "") {
                    path := dir . "\history-" . FormatTime(, "yyyy-MM-dd") . ".csv"
                    isNew := !FileExist(path)
                    try {
                        ; FileAppend(…,"UTF-8")はAHKが新規ファイルにBOMを自動付与するため、
                        ; ここでChr(0xFEFF)を足すと二重BOMになる(実機で発覚。history-store.csvと同じ地雷)
                        out := isNew ? "time,text`r`n" : ""
                        out .= CsvField(FormatTime(, "HH:mm:ss")) . "," . CsvField(p.text) . "`r`n"
                        FileAppend(out, path, "UTF-8")
                    }
                }
            }
            if ClipHistoryPersist
                AppendHistoryStore(p.HasOwnProp("time") && p.time != "" ? p.time : NowWithWeekday(), p.text)
            PendingArchive.RemoveAt(i)
        } else
            i++
    }
    if (PendingArchive.Length = 0)
        SetTimer(CommitPendingArchive, 0)
}

; --- 履歴の再起動を跨いだ永続化ストア(v1.17.0〜)。既存の日次ログ(clip-archive\history\*.csv、
; 人間がexplorerで読む記録)とは別ファイル。プログラム所有・追記式。検疫の下流にのみ存在する
; (書き込み地点はCommitPendingArchive内のこの1箇所だけ)。経緯は
; _docs/CLIPBOARD-HISTORY-PERSISTENT-STORE-DESIGN.md参照 ---

HistoryStorePath() {
    return ArchiveBaseDir() . "\history-store.csv"
}

AppendHistoryStore(timeStr, text) {
    path := HistoryStorePath()
    try DirCreate(ArchiveBaseDir())
    isNew := !FileExist(path)
    try {
        ; FileAppend(…, "UTF-8")は新規ファイル作成時にAHK自身がBOMを自動付与する。
        ; ここでChr(0xFEFF)を明示的に足すと二重BOM(EF BB BF EF BB BF)になり、起動時の
        ; RegExReplace("^\x{FEFF}")が1個しか剥がせず、ヘッダ判定(row[1]="time")が
        ; ズレて壊れる(実機で発覚済みのバグ)。ヘッダ文字列だけ書き、BOMはAHKに任せる。
        out := isNew ? "time,type,text`r`n" : ""
        out .= CsvField(timeStr) . ",text," . CsvField(text) . "`r`n"
        FileAppend(out, path, "UTF-8")
    }
}

; 「この履歴を削除」の永続反映。ストアは追記式(AppendHistoryStore)のため、削除は
; メモリのClipHistoryから消すだけでは足りず、再起動でFinishHistoryStoreLoadが
; 復元してしまう(実機で確認されたバグ)。全体書き直しはClipHistLoadMax(既定10000件)
; 打ち切り分の古い行を巻き込んでデータロスするため、削除本文リストとの差分書き直しにする。
; 連続削除は2秒のSetTimerでまとめ、書き直し1回に集約する。
HistStoreMarkDeleted(text) {
    global HistStoreDeletedTexts, ClipHistoryPersist, HistStoreRewritePending
    if !ClipHistoryPersist
        return
    HistStoreDeletedTexts.Push(text)
    HistStoreRewritePending := true
    SetTimer(RewriteHistStoreIfPending, -2000)
}

; 履歴を「使った」(貼り付けに選んだ)ことの永続反映。旧行を除去し、現在時刻で末尾に付け直す
; ことで、FinishHistoryStoreLoadの「末尾(新)から走査」ロジックにより次回起動時も先頭に来る。
; 新規コンテンツの書き込みではなく既存行の並び替えなので、CommitPendingArchiveの検疫を経由
; しない(67行のコメントが指す「書き込み地点」の制約は新規コピーの検疫の話であり、
; 削除・並び替えはHistStoreMarkDeletedと同じ「差分書き直し」カテゴリに属する)。
HistStoreMarkPromoted(text, timeStr) {
    global HistStorePromotedTexts, ClipHistoryPersist, HistStoreRewritePending
    if !ClipHistoryPersist
        return
    HistStorePromotedTexts.Push({text: text, time: timeStr})
    HistStoreRewritePending := true
    SetTimer(RewriteHistStoreIfPending, -2000)
}

RewriteHistStoreIfPending(*) {
    global HistStoreRewritePending, HistStoreDeletedTexts, HistStorePromotedTexts
    if !HistStoreRewritePending
        return
    HistStoreRewritePending := false
    path := HistoryStorePath()
    if !FileExist(path) {
        HistStoreDeletedTexts := []
        HistStorePromotedTexts := []
        return
    }
    del := Map()
    for t in HistStoreDeletedTexts
        del[t] := 1
    promoted := Map()                          ; text -> 最新のtimeStr(同一本文が複数回昇格されても最後の時刻だけ使う)
    for p in HistStorePromotedTexts
        promoted[p.text] := p.time
    try {
        rows := ParseCsv(RegExReplace(FileRead(path, "UTF-8"), "^\x{FEFF}"))
        out := "time,type,text`r`n"
        for i, row in rows {
            if (i = 1 && row.Length >= 3 && Trim(row[1]) = "time")
                continue                       ; ヘッダは自前で書く
            if (row.Length < 3 || del.Has(row[3]) || promoted.Has(row[3]))
                continue                       ; 削除対象・破損行・昇格対象(旧位置)を除去
            out .= CsvField(row[1]) . "," . CsvField(row[2]) . "," . CsvField(row[3]) . "`r`n"
        }
        for text, timeStr in promoted           ; 昇格分は末尾に新時刻で付け直す(=次回起動時に先頭)
            out .= CsvField(timeStr) . ",text," . CsvField(text) . "`r`n"
        tmp := path . ".tmp"
        try FileDelete(tmp)
        FileAppend(out, tmp, "UTF-8")
        FileMove(tmp, path, 1)                 ; 一時ファイル→原子的差し替え(途中失敗なら旧ストア残存=fail-closed)
        HistStoreDeletedTexts := []             ; 成功時のみクリア(失敗なら次回削除時に再試行される)
        HistStorePromotedTexts := []
    }
}

; 起動時ロード。起動シーケンスの同期処理をブロックしないよう、ホットキー登録・トレイ構築が
; 終わった後にSetTimer(-50)で1回だけ予約される(呼び出し元は起動シーケンス末尾を参照)。
; ParseCsvは定型文CSV取込でも使われている実戦投入済みの状態機械。ClipHistLoadMax(既定10000件)で
; 早期に打ち切るため、実運用サイズ(数MB以下)ならこの一括パースで数十ms程度に収まる想定。
StartHistoryStoreLoad() {
    global ClipHistoryPersist
    if !ClipHistoryPersist
        return
    path := HistoryStorePath()
    if (path = "" || !FileExist(path))
        return
    txt := ""
    try txt := RegExReplace(FileRead(path, "UTF-8"), "^\x{FEFF}")
    if (txt = "")
        return
    rows := ParseCsv(txt)
    FinishHistoryStoreLoad(rows)
}

; ストアの行(古→新の追記順)から復元する。合流規則:
; 1. ヘッダ行とtype!="text"の行を捨てる
; 2. 末尾(新)から先頭(古)へ走査し、seen Mapで重複除去(同文の再コピーは最新だけ残す)
; 3. ClipHistLoadMax件で打ち切る
; 4. 集めた「新→古」順の配列を、そのままClipHistory.Push(...)で末尾に追加する
;    (ClipHistoryは常に新しい順・InsertAt(1)で先頭積みという既存不変条件を保つ。
;    起動直後の新規コピーは先頭に積まれるので、末尾に追加する復元分と衝突しない)
FinishHistoryStoreLoad(rows) {
    global ClipHistory, ClipHistLoadMax
    seen := Map()
    restored := []                             ; 新→古の順で集める
    loop rows.Length {
        idx := rows.Length - A_Index + 1       ; 末尾(新)から走査
        row := rows[idx]
        if (idx = 1 && row.Length >= 3 && Trim(row[1]) = "time" && Trim(row[2]) = "type")
            continue                           ; ヘッダ行
        if (row.Length < 3 || Trim(row[2]) != "text")
            continue                           ; 列数不足(途中破損)や画像行(Phase 2)は捨てる
        timeStr := row[1], text := row[3]
        if (text = "" || seen.Has(text))
            continue
        already := false
        for v in ClipHistory                   ; セッション中に既にコピー済みの本文は二重登録しない
            if (v.type = "text" && v.text = text) {
                already := true
                break
            }
        if already
            continue
        seen[text] := true
        restored.Push({type: "text", text: text, time: timeStr})
        if (restored.Length >= ClipHistLoadMax)
            break
    }
    for v in restored
        ClipHistory.Push(v)
    if (restored.Length > 0)
        RefreshLauncherHistory()
}

; --- 設定ウィンドウ（フォルダ保存のON/OFFをチェックボックスで一望できる専用画面） ---
; トレイメニューは項目名を読まないと何が起きるか分からない、という声を受けて新設。
; チェックボックス+短い説明文を並べるだけの単一画面。SnipMgrGuiと同じシングルトンパターン。
global SettingsGui := 0, SettingsChkImage := 0, SettingsChkText := 0, SettingsChkStartup := 0, SettingsChkWatch := 0
global SettingsChkHistPersist := 0

; 設定ウィンドウを開いている間、ランチャーのフォーカス監視(CheckLauncherFocus)を止める。
; 止めないとランチャー→設定ウィンドウへフォーカスが移った瞬間に「アクティブでなくなった」と
; 誤検知してランチャーごと閉じてしまう(右クリックメニュー表示中と同じ地雷・既存の対処と同じ流儀)。
ShowSettingsWindow(*) {
    global SettingsGui, SettingsChkImage, SettingsChkText, SettingsChkStartup, SettingsChkWatch, SettingsChkHistPersist
    global ClipArchiveImage, ClipArchiveText, ClipWatchOn, ClipHistoryPersist, LauncherGui
    SetTimer(CheckLauncherFocus, 0)
    if SettingsGui {
        SettingsChkImage.Value := ClipArchiveImage
        SettingsChkText.Value := ClipArchiveText
        SettingsChkStartup.Value := IsStartupRegistered()
        SettingsChkWatch.Value := ClipWatchOn
        SettingsChkHistPersist.Value := ClipHistoryPersist
        SettingsGui.Show()
        return
    }
    SettingsGui := Gui("+ToolWindow", "設定")
    SettingsGui.SetFont("s9", "Meiryo UI")

    SettingsGui.Add("GroupBox", "x10 y10 w380 h74", "基本")
    SettingsChkStartup := SettingsGui.Add("CheckBox", "x20 y32 w360", "Windows起動時に自動実行する")
    SettingsChkStartup.Value := IsStartupRegistered()
    SettingsChkStartup.OnEvent("Click", (*) => ApplyStartupToggle(SettingsChkStartup))
    SettingsChkWatch := SettingsGui.Add("CheckBox", "x20 y56 w360", "クリップボード監視を有効にする")
    SettingsChkWatch.Value := ClipWatchOn
    SettingsChkWatch.OnEvent("Click", (*) => ApplyClipWatchToggle(SettingsChkWatch))

    SettingsGui.Add("GroupBox", "x10 y92 w380 h130", "フォルダ保存（既定はON・パスワード自動クリアで消えたものは保存されません）")
    SettingsChkImage := SettingsGui.Add("CheckBox", "x20 y114 w360", "スクショ（コピーした画像）をフォルダに保存する")
    SettingsChkImage.Value := ClipArchiveImage
    SettingsChkImage.OnEvent("Click", (*) => ApplyArchiveToggle("image", SettingsChkImage))
    SettingsGui.Add("Text", "x38 y134 w340 h16 cGray", "保存先: clip-archive\screenshot（PNG形式）")

    SettingsChkText := SettingsGui.Add("CheckBox", "x20 y160 w360", "テキストのコピー履歴をフォルダに保存する")
    SettingsChkText.Value := ClipArchiveText
    SettingsChkText.OnEvent("Click", (*) => ApplyArchiveToggle("text", SettingsChkText))
    SettingsGui.Add("Text", "x38 y180 w340 h32 cGray",
        "保存先: clip-archive\history（CSV形式）`nパスワード等を扱う際はOFFのままにしてください")

    ; 履歴の永続化(v1.17.0〜)。フォルダ保存(検疫つき日次ログ)とは別トグル・別ファイル。
    ; ONにするとアプリの履歴タブ自体が再起動を跨いで遡れるようになる。検疫は両トグルで共通・完全維持。
    SettingsGui.Add("GroupBox", "x10 y232 w380 h74", "履歴（既定はON）")
    SettingsChkHistPersist := SettingsGui.Add("CheckBox", "x20 y254 w360", "履歴を再起動後も残す（Clibor方式・検疫付き）")
    SettingsChkHistPersist.Value := ClipHistoryPersist
    SettingsChkHistPersist.OnEvent("Click", (*) => ApplyHistPersistToggle(SettingsChkHistPersist))
    SettingsGui.Add("Text", "x38 y276 w340 h28 cGray",
        "保存先: clip-archive\history-store.csv`nパスワード自動クリアで消えたものは保存されません")

    SettingsGui.Add("Button", "x20 y314 w150 h28", "保存フォルダを開く").OnEvent("Click", OpenArchiveDir)
    SettingsGui.Add("Button", "x290 y314 w100 h28", "閉じる").OnEvent("Click", (*) => HideSettingsWindow())
    ; ブランドロゴ: 他ウィンドウ(定型文の管理)と同じ流儀でフッターに控えめに配置。読み込み失敗は握りつぶす
    try SettingsGui.Add("Picture", "x20 y352 w58 h36", A_ScriptDir . "\kimitolink-full-logo.png")
    SettingsGui.OnEvent("Close", (*) => HideSettingsWindow())
    SettingsGui.OnEvent("Escape", (*) => HideSettingsWindow())
    SettingsGui.Show("w400 h398")
}

; 設定ウィンドウを閉じ、止めていたランチャーのフォーカス監視を再開する。
; ランチャーが既に閉じられている場合はCheckLauncherFocus自身が自己解除するので無害。
HideSettingsWindow() {
    global SettingsGui, LauncherGui
    SettingsGui.Hide()
    if IsObject(LauncherGui)
        SetTimer(CheckLauncherFocus, 150)
}

; 設定ウィンドウのチェックボックスから起動登録を切り替える。トレイに同項目はない(v1.13.0で設定ウィンドウへ一本化)ため
; ラベル同期は不要。EnableStartup/DisableStartupは初回起動確認ダイアログとも共有する。
ApplyStartupToggle(chk) {
    IsStartupRegistered() ? DisableStartup() : EnableStartup()
    chk.Value := IsStartupRegistered()
}

; 設定ウィンドウのチェックボックスからクリップボード監視を切り替える。トレイのToggleClipWatchと状態を共有する。
; ランチャー歯車メニューは開くたびにClipWatchOnの現在値からCheck状態を作り直すため、ここでは触らない。
ApplyClipWatchToggle(chk) {
    global ClipWatchOn
    ClipWatchOn := chk.Value
    SetSetting("clipboard.watch", ClipWatchOn ? "on" : "off")
    ClipWatchOn ? A_TrayMenu.Uncheck("クリップボード監視を一時停止") : A_TrayMenu.Check("クリップボード監視を一時停止")
    Flash(ClipWatchOn ? "クリップボード監視: 再開" : "クリップボード監視: 一時停止", 1200)
}

; 設定ウィンドウのチェックボックスから呼ばれる。ON時は警告→同意→トレイ側と同じ永続化。
; チェックボックスは操作の起点であると同時に表示状態でもあるため、拒否時は元の値へ戻す。
ApplyArchiveToggle(kind, chk) {
    global ClipArchiveImage, ClipArchiveText
    turningOn := chk.Value
    if turningOn {
        msg := (kind = "image")
            ? "コピーした画像がディスク上のファイルに残るようになります。`n有効にしますか？"
            : "コピーしたテキストがディスク上のファイルに残るようになります。`n"
                . "パスワード等を扱う際はOFFのままにしてください。`n`n有効にしますか？"
        if (MsgBox(msg, "フォルダ保存の確認", "YesNo Icon!") != "Yes") {
            chk.Value := 0                    ; 拒否時はチェックを戻す
            return
        }
    }
    if (kind = "image")
        SetSetting("archive.image", turningOn ? "on" : "off")
    else
        SetSetting("archive.text", turningOn ? "on" : "off")
    Flash(turningOn ? "フォルダ保存: ON" : "フォルダ保存: OFF")
}

; 履歴の永続化トグル。ON時は警告→同意。OFF時は保存済みファイルを削除するか確認する
; (削除しない場合、ファイルは残るが次回ロード時にpersist=offなら読み込まれない)。
ApplyHistPersistToggle(chk) {
    global ClipHistoryPersist
    turningOn := chk.Value
    if turningOn {
        msg := "履歴が再起動を跨いで残るようになります(Clibor方式)。`n"
            . "保存先はclip-archiveフォルダ内、パスワード自動クリアで消えたものは保存されません。`n`n有効にしますか？"
        if (MsgBox(msg, "履歴の永続化の確認", "YesNo Icon!") != "Yes") {
            chk.Value := 0
            return
        }
        SetSetting("history.persist", "on")
        Flash("履歴の永続化: ON")
    } else {
        if (FileExist(HistoryStorePath())
            && MsgBox("保存済みの履歴ファイルも削除しますか？", "履歴の永続化を解除", "YesNo Icon?") = "Yes")
            try FileDelete(HistoryStorePath())
        SetSetting("history.persist", "off")
        Flash("履歴の永続化: OFF")
    }
}

; 検疫中(未確定)の項目は保存せず終了する。fail-closed: 「終了直前のコピーが保存されない」より
; 「終了直前のパスワードがディスクに残る」方が重い、という判断(G節参照)。
DiscardPendingArchiveOnExit(*) {
    global PendingArchive
    PendingArchive := []
}

; 300msデバウンス中に終了すると変更が失われるため、終了直前に未反映分を同期的に書き切る。
FlushSettingsOnExit(*) {
    SetTimer(FlushSettings, 0)   ; 保留中のデバウンスタイマーを解除してから即時書き込み
    FlushSettings()
}

; 削除直後2秒以内に終了すると書き直しタイマーが発火せず削除項目が蘇るため、終了直前に同期実行する。
FlushHistStoreRewriteOnExit(*) {
    SetTimer(RewriteHistStoreIfPending, 0)
    RewriteHistStoreIfPending()
}

; 画像要素1件→ImageListへ追加し0始まりindexを返す。失敗は-1(プレースホルダー表示のまま)
; 等倍HBITMAPを一度も作らず、CF_DIBバッファから48x48へ直接縮小描画する(StretchDIBits)。
MakeHistThumb(v) {
    global HistThumbIL
    static TW := 48, TH := 48, SRCCOPY := 0x00CC0020, HALFTONE := 4, WHITE_BRUSH := 0
    if !v.HasOwnProp("dib")                    ; 降格済み(dib解放済み)は再生成不能。呼び出し元はキャッシュ済みthumbIdxを使う前提
        return -1
    off := DibBitsOffset(v.dib)
    if (!off || v.w < 1 || v.h < 1)
        return -1
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcM := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    hBmp := DllCall("CreateCompatibleBitmap", "Ptr", hdcS, "Int", TW, "Int", TH, "Ptr")
    idx := -1
    if (hdcM && hBmp) {
        hOld := DllCall("SelectObject", "Ptr", hdcM, "Ptr", hBmp, "Ptr")
        rc := Buffer(16), NumPut("Int",0,rc,0), NumPut("Int",0,rc,4)
        NumPut("Int",TW,rc,8), NumPut("Int",TH,rc,12)
        DllCall("FillRect", "Ptr", hdcM, "Ptr", rc
            , "Ptr", DllCall("GetStockObject", "Int", WHITE_BRUSH, "Ptr"))
        scale := Min(TW / v.w, TH / v.h)               ; アスペクト比保持・中央寄せ
        dw := Max(1, Round(v.w * scale)), dh := Max(1, Round(v.h * scale))
        dx := (TW - dw) // 2, dy := (TH - dh) // 2
        DllCall("SetStretchBltMode", "Ptr", hdcM, "Int", HALFTONE)
        DllCall("SetBrushOrgEx", "Ptr", hdcM, "Int", 0, "Int", 0, "Ptr", 0)  ; HALFTONE後は必須(MSDN)
        DllCall("StretchDIBits", "Ptr", hdcM
            , "Int", dx, "Int", dy, "Int", dw, "Int", dh
            , "Int", 0, "Int", 0, "Int", v.w, "Int", v.h
            , "Ptr", v.dib.Ptr + off       ; pjBits: ヘッダ＋カラーテーブルの直後
            , "Ptr", v.dib                 ; pbmi:   CF_DIBは先頭がそのままBITMAPINFO
            , "UInt", 0                    ; DIB_RGB_COLORS
            , "UInt", SRCCOPY)
        DllCall("SelectObject", "Ptr", hdcM, "Ptr", hOld, "Ptr")  ; Add前に必ずDCから外す
        idx := DllCall("comctl32\ImageList_Add", "Ptr", HistThumbIL, "Ptr", hBmp, "Ptr", 0, "Int")
    }
    if hBmp
        DllCall("DeleteObject", "Ptr", hBmp)   ; ImageList_Addは内部コピーなので即破棄で安全
    if hdcM
        DllCall("DeleteDC", "Ptr", hdcM)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
    return idx
}

HistThumbIndex(v) {                        ; 生成は要素につき1回。以後はキャッシュ(失敗は再試行のためキャッシュしない)
    if !v.HasOwnProp("thumbIdx")
        v.thumbIdx := MakeHistThumb(v)
    idx := v.thumbIdx
    if (idx = -1)
        v.DeleteProp("thumbIdx")           ; 次回オープン時に再試行(一時的なGDIリソース不足からの回復を期待)
    return idx
}

; クリップボードを開かずに判定できるためコールバック内でも安全
ClipHasIgnoreFormat() {
    static fmts := [DllCall("RegisterClipboardFormat", "Str", "Clipboard Viewer Ignore", "UInt"),
                    DllCall("RegisterClipboardFormat", "Str", "ExcludeClipboardContentFromMonitorProcessing", "UInt")]
    for f in fmts
        if (f && DllCall("IsClipboardFormatAvailable", "UInt", f))
            return true
    return false
}

ClipSourceExcluded() {
    global ClipExcludeExes
    exe := ""
    if (hwnd := DllCall("GetClipboardOwner", "Ptr")) {
        DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid := 0)
        try exe := StrLower(ProcessGetName(pid))
    }
    if (exe = "")
        try exe := StrLower(WinGetProcessName("A"))
    return exe != "" && ClipExcludeExes.Has(exe)
}

MaybeDropAutoCleared() {
    global ClipHistory, LastCaptureText, LastCaptureTick, ClipAutoClearSec, PendingArchive
    if (LastCaptureText = "" || A_TickCount - LastCaptureTick > ClipAutoClearSec * 1000)
        return
    for i, v in ClipHistory
        if (v.type = "text" && v.text = LastCaptureText) {   ; 画像のプレースホルダーと誤爆させない
            ClipHistory.RemoveAt(i)
            Flash("自動クリアを検知したため履歴とフォルダ保存予約からも削除しました", 1500)
            break
        }
    ; 検疫待ちのフォルダ保存予約も同時に取り消す(メモリとディスク行きを同時に守る。D節の核心)
    i := 1
    while (i <= PendingArchive.Length)
        (PendingArchive[i].text = LastCaptureText) ? PendingArchive.RemoveAt(i) : i++
    LastCaptureText := ""
}

CheckLauncherFocus() {
    global LauncherGui
    if !IsObject(LauncherGui) {
        SetTimer(CheckLauncherFocus, 0)
        return
    }
    if !WinActive("ahk_id " . LauncherGui.Hwnd)
        CloseLauncher()
}

CloseLauncher() {
    global LauncherGui, LauncherLvHHwnd, LauncherLvSHwnd
    SetTimer(CheckLauncherFocus, 0)
    SetTimer(LauncherWatchDrag, 0)
    SetTimer(LauncherWatchHover, 0), ToolTip()
    if IsObject(LauncherGui) {
        try LauncherGui.Destroy()
        LauncherGui := 0
    }
    LauncherLvHHwnd := 0, LauncherLvSHwnd := 0   ; hwnd値のOS再利用による誤爆防止
}

; 掴みしろ監視: バー領域内での左クリック押下を検知したら手動ドラッグループへ
; （その場での見やすい位置への移動はできるが、次回起動時はCliborと同じく常にカーソル位置に開き直す）
; ポーリング間隔は30ms/Sleep15から5msに短縮(2026-07-22)。ノートPCの精密タッチパッドは
; 「誤作動防止(AAP)」でキー入力直後のタップ/クリックを一時的に遅延させる既知の仕様があり、
; またドラッグ中に単指移動がジェスチャー扱いへ再分類され得るため、ポーリングの粗さが
; ボタン押下の開始・継続を取りこぼしやすい(デスクトップの通常マウスでは起きにくい)。
; WM_NCHITTEST/WM_LBUTTONDOWNフックへの置き換えは実機で機能せず(-Captionウィンドウの
; クライアント領域内コントロールでは非クライアント処理に委譲できない)撤回済み。
LauncherWatchDrag() {
    global LauncherGui, LauncherDragBar
    if !(IsObject(LauncherGui) && IsObject(LauncherDragBar) && GetKeyState("LButton", "P"))
        return
    MouseGetPos &mx, &my
    LauncherDragBar.GetPos(&bx, &by, &bw, &bh)
    LauncherGui.GetPos(&gx, &gy)
    if !(mx >= gx + bx && mx <= gx + bx + bw && my >= gy + by && my <= gy + by + bh)
        return
    winX := gx, winY := gy, startMx := mx, startMy := my
    while GetKeyState("LButton", "P") {
        if !IsObject(LauncherGui)   ; ドラッグ中にCloseLauncher()で破棄された場合(フォーカス喪失等)
            return
        MouseGetPos &mx2, &my2
        try LauncherGui.Move(winX + (mx2 - startMx), winY + (my2 - startMy))
        catch
            return   ; チェック直後にDestroyされた場合(単一スレッドのAHKでは稀だが念のため)
        Sleep 5
    }
}

; マウス直下のListView行番号(1始まり)。行外は0。履歴・定型文タブ共用(両タブともListView、2026-07-18〜)。
LauncherLVItemUnderMouse(lv) {
    MouseGetPos &mx, &my
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " . lv.Hwnd)
    if (mx < cx || mx >= cx + cw || my < cy || my >= cy + ch)
        return 0
    ht := Buffer(24, 0)                       ; LVHITTESTINFO {POINT, flags, iItem, iSubItem, iGroup}
    NumPut("Int", mx - cx, ht, 0), NumPut("Int", my - cy, ht, 4)
    return SendMessage(0x1012, 0, ht.Ptr, , "ahk_id " . lv.Hwnd) + 1   ; LVM_HITTEST: -1(なし)→0
}

; 1行目の外接矩形から実際の行高を得る。行ゼロ時は0(fail-closed: リサイズしないだけ)
LauncherLVItemHeight(lv) {
    rc := Buffer(16, 0)                       ; rc.left=0 (LVIR_BOUNDS)
    if !SendMessage(0x100E, 0, rc.Ptr, , "ahk_id " . lv.Hwnd)   ; LVM_GETITEMRECT, wParam=item0
        return 0
    return NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
}

; ホバー監視: 直下項目の全文(+履歴は時刻)をToolTip表示。hwnd比較ではなく座標の直接判定で決める
; （MouseGetPosのControl出力はClassNN文字列でありHwndと直接比較できないため）
LauncherWatchHover() {
    global LauncherGui, LauncherLvH, LauncherLvS, LauncherHoverLast, ClipHistory, Snippets, LauncherTab
    if !IsObject(LauncherGui)
        return
    tip := ""
    ; Tab3は非アクティブなタブの子コントロールも実体を保持し続けるため、アクティブタブでヒットテストを
    ; 限定しないと、履歴タブ表示中でも裏に隠れた定型文ListViewの内容がツールチップに出てしまう。
    if (LauncherTab.Value = 1) {
        if (idx := ResolveHistRow(LauncherLVItemUnderMouse(LauncherLvH))) && idx <= ClipHistory.Length
            tip := ClipHistory[idx].time . " にコピー`n" . SubStr(ClipHistory[idx].text, 1, 600)
    } else {
        if (idx := ResolveSnipRow(LauncherLVItemUnderMouse(LauncherLvS))) && idx <= Snippets.Length
            tip := SubStr(Snippets[idx].value, 1, 600)
    }
    if (tip != LauncherHoverLast) {
        LauncherHoverLast := tip
        ToolTip(tip)
    }
}

; 右クリック: 履歴項目=メニュー（開く・昇格・コピー・削除・管理画面）、定型文項目=導線メニュー
; クロージャは行インデックスでなく要素の参照(v)を束縛する: メニュー表示中もクリップボード監視は
; 生きており、新規コピーがInsertAt(1)で先頭に積まれるとidxが1ずれ、隣の項目を誤操作するため。
LauncherContextMenu(g, ctrl, item, isRC, x, y) {
    global LauncherLvH, LauncherLvS, ClipHistory, LauncherGui, Snippets
    if (ctrl = LauncherLvH) {
        idx := ResolveHistRow(LauncherLVItemUnderMouse(LauncherLvH))
        if (idx < 1 || idx > ClipHistory.Length)
            return
        v := ClipHistory[idx]                 ; 参照を掴む。以降idxは使わない
        SetTimer(CheckLauncherFocus, 0)       ; メニュー表示中の誤クローズ防止(必須)
        m := Menu()
        if (v.type = "text") {
            if (p := RunnablePathFrom(v.text))
                m.Add(InStr(FileExist(p), "D") ? "このフォルダを開く" : "このファイルを開く", (*) => OpenHistoryPath(p))
            m.Add("定型文に登録", (*) => PromoteHistoryItem(v))   ; 画像はsnippets.ini非対応のため出さない
            ; --- ワンショット整形/変換(Clibor同等化・第2ラウンド)。Shift押しながら選択でコピーのみ ---
            defs := ClipTransformDefs()
            mF := Menu(), mC := Menu()
            for d in defs.format
                mF.Add(d.name, MakeTransformHandler(v, d.fn))
            for d in defs.convert
                mC.Add(d.name, MakeTransformHandler(v, d.fn))
            for sub in [mF, mC] {
                sub.Add()
                sub.Add("Shift+選択でコピーのみ", (*) => 0)
                sub.Disable("Shift+選択でコピーのみ")     ; 押せないヒント行
            }
            m.Add("整形して貼り付け", mF)
            m.Add("変換して貼り付け", mC)
        }
        m.Add("コピーのみ（貼り付けない）", (*) => CopyHistoryItem(v))
        m.Add()
        m.Add("この履歴を削除", (*) => DeleteHistoryItem(v))
        m.Add("履歴を全削除...", (*) => ConfirmDeleteHistoryAll())
        m.Add()
        m.Add("管理画面で履歴を見る", (*) => OpenHistoryManagerFromLauncher())
        m.Show()
        if IsObject(LauncherGui)
            SetTimer(CheckLauncherFocus, 150)
    } else if (ctrl = LauncherLvS) {
        idx := ResolveSnipRow(LauncherLVItemUnderMouse(LauncherLvS))
        SetTimer(CheckLauncherFocus, 0)
        m := Menu()
        if (idx >= 1 && idx <= Snippets.Length) {
            m.Add("この定型文を使う", (*) => UseSnippetAt(idx))
            m.Add()
        }
        m.Add("編集・削除（定型文の管理）", (*) => (CloseLauncher(), ShowSnippetManager()))
        m.Add("新規登録（定型文の管理）", (*) => (CloseLauncher(), ShowSnippetManager(), SnipMgrNewForm()))
        m.Show()
        if IsObject(LauncherGui)
            SetTimer(CheckLauncherFocus, 150)
    }
}

; 履歴テキストが「実在するローカルのドライブレター絶対パス」のときだけ正規化して返す。
; UNC(\\server)・相対パス・複数行・存在しないパスはすべて空を返す(fail-closed)。
RunnablePathFrom(text) {
    p := Trim(text, " `t`r`n`"'")
    if InStr(p, "`n") || StrLen(p) > 500
        return ""
    if !RegExMatch(p, "i)^[a-z]:\\")
        return ""
    return FileExist(p) ? p : ""
}

OpenHistoryPath(p) {
    CloseLauncher()
    if InStr(FileExist(p), "D") {
        try Run('explorer.exe "' . p . '"')
        return
    }
    if RegExMatch(p, "i)\.(exe|bat|cmd|com|ps1|vbs|js|wsf|msi|scr|lnk)$") {
        if (MsgBox("これはプログラムです。実行しますか？`n`n" . p, "履歴から実行", "YesNo Icon! Default2") != "Yes")
            return
    }
    try Run('"' . p . '"')
    catch
        Flash("開けませんでした: " . p, 1800)
}

; 引数は要素参照v(idxではない)。メモリから消すのに加え、永続ストアにも差分削除を反映する(G節)。
DeleteHistoryItem(v) {
    global ClipHistory
    for i, x in ClipHistory
        if (x = v) {                          ; オブジェクト同一性比較(AHK v2は参照比較)
            ClipHistory.RemoveAt(i)
            if (v.type = "text")
                HistStoreMarkDeleted(v.text)
            break
        }
    RefreshLauncherHistory()
}

DeleteHistoryAll(*) {                          ; トレイメニューからも呼ぶため可変引数
    global ClipHistory, PendingArchive
    ClipHistory := []
    PendingArchive := []                       ; 検疫待ちのフォルダ保存予約も同時に破棄
    try FileDelete(HistoryStorePath())          ; 永続化ONなら再起動しても蘇らないよう同時に消す
    RefreshLauncherHistory()
    Flash("履歴を全削除しました", 1200)
}

; 実質無制限保存(999999件)+永続化が既定ONの現在、無確認の全削除は誤クリック1回で全喪失する
; 事故につながるため確認を挟む。ランチャー右クリック・トレイメニュー共通の入口として使う。
ConfirmDeleteHistoryAll(*) {
    global ClipHistory
    CloseLauncher()                            ; MsgBoxより先に閉じる(CheckLauncherFocusの誤検知対策)
    if (MsgBox("クリップボード履歴 " . ClipHistory.Length . " 件をすべて削除します。`n"
        . "保存済みの履歴ファイルも消え、元に戻せません。よろしいですか？",
        "履歴を全削除", "YesNo Icon! Default2") = "Yes")
        DeleteHistoryAll()
}

; 履歴を右クリック→貼り付けはせずクリップボードへ戻すだけ。SnipMgrHistCopyと同じ実装方針。
CopyHistoryItem(v) {
    CloseLauncher()
    if (v.type = "image") {
        if (dib := GetImageDib(v)) && SetClipboardImage(dib)
            Flash("画像をコピーしました", 1200)
        else
            Flash("画像を再設定できませんでした", 1500)
    } else {
        A_Clipboard := v.text                 ; 監視が拾い先頭昇格するのは意図どおり(SnipMgrHistCopyと同挙動)
        Flash("コピーしました（貼り付けはしていません）", 1400)
    }
}

; 「定型文の管理」ウィンドウの履歴タブへ導線し、ランチャーの検索語を引き継ぐ。
OpenHistoryManagerFromLauncher(*) {
    global SnipMgrTab, SnipMgrHistEd, LauncherSearchEdit
    q := IsObject(LauncherSearchEdit) ? Trim(LauncherSearchEdit.Value) : ""
    CloseLauncher()
    ShowSnippetManager()
    SnipMgrTab.Value := 2
    if (q != "")
        SnipMgrHistEd.Value := q
    SnipMgrHistRefresh()                       ; Tab.Value代入はChangeイベントを発火しないため明示呼び出し必須
}

ToggleClipWatch(name, *) {
    global ClipWatchOn, SettingsGui, SettingsChkWatch
    ClipWatchOn := !ClipWatchOn
    SetSetting("clipboard.watch", ClipWatchOn ? "on" : "off")
    ClipWatchOn ? A_TrayMenu.Uncheck(name) : A_TrayMenu.Check(name)
    if SettingsGui
        SettingsChkWatch.Value := ClipWatchOn
    Flash(ClipWatchOn ? "クリップボード監視: 再開" : "クリップボード監視: 一時停止", 1200)
}

RefreshLauncherHistory() {
    global LauncherGui, LauncherLvH, LauncherTab, ClipHistory, LauncherSearchEdit
    if !IsObject(LauncherGui)
        return
    q := IsObject(LauncherSearchEdit) ? Trim(LauncherSearchEdit.Value) : ""
    FillLauncherHistoryLV(LauncherLvH, q)   ; 検索中の追加/削除でも絞り込み語を維持する
    SetTabLabel(LauncherTab, 1, "履歴 " . ClipHistory.Length)
}

; Tab3のタブ見出しを生成後に書き換える。AHK v2にはGui.Tabの見出し変更メソッドが無いため
; TCM_SETITEMをネイティブに叩く(AHKは常にUnicodeビルドなのでA/W区別不要)。
; TCITEMW構造体(64bit): mask(4)+dwState(4)+dwStateMask(4)+pad(4)
; +pszText(8,ptr,offset16)+cchTextMax(4)+iImage(4)+pad(4)+lParam(8,ptr) = 40バイト。
; TCM_FIRST=0x1300、TCM_SETITEM=TCM_FIRST+61=0x133D(Microsoft Learn commctrl.hで裏取り済み)。
SetTabLabel(tabCtrl, index, text) {
    static TCIF_TEXT := 0x1, TCM_SETITEM := 0x133D
    tcitem := Buffer(40, 0)
    NumPut("UInt", TCIF_TEXT, tcitem, 0)               ; mask
    NumPut("Ptr", StrPtr(text), tcitem, 16)             ; pszText
    SendMessage(TCM_SETITEM, index - 1, tcitem.Ptr, tabCtrl)   ; 0-based index
}

; ShowLauncherのListView初期化とLauncherFilterChangedで共用。ラベル/本文どちらかに部分一致すれば残す。
; ClipHistory側のFillLauncherHistoryLVと同じ「表示行→実インデックス」マップ方式。履歴側と違い
; 表示打ち切り(DisplayMax)は設けない: 定型文はユーザーがsnippets.iniを手動管理する有限リストで、
; 履歴のように無際限に増えないため(意図的な非対称。_docs/LAUNCHER-SNIPPETS-LISTVIEW-DESIGN.md G-3)。
FillLauncherSnippetsLV(lv, query := "") {
    global Snippets, LauncherSnipFilterMap
    ; Critical: -Redraw〜+Redraw区間に0遅延タイマー(RedrawActiveLauncherSnippetsTab等)が
    ; 割り込み、同一ListViewへWM_SETREDRAWトグルが入れ子で走るとOFFが実効的に残留し
    ; 「罫線もアイテムも無い完全空白」になる不具合が実測(uiGridOnly)で確認された。
    ; 関数終了で自動解除される。詳細: _docs/SHINDAN-PAINT-PROBE-DESIGN.md C-4節
    Critical("On")
    LauncherSnipFilterMap := []
    lv.Opt("-Redraw")
    lv.Delete()
    for i, s in Snippets {
        if (query != "" && !InStr(s.label, query) && !InStr(s.value, query))
            continue
        LauncherSnipFilterMap.Push(i)
        dispRow := LauncherSnipFilterMap.Length
        lv.Add(, LauncherRowKeyLabel(dispRow) . (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . s.label)
    }
    lv.Opt("+Redraw")
    ; +Grid(LVS_EX_GRIDLINES)導入後、+Redraw直後は罫線(セル背景)だけ再描画されテキストが
    ; 反映されない状態が実機で確認された(2026-07-18)。WM_SETREDRAW ONだけでは足りないため
    ; 明示的に全体再描画を強制する。InvalidateRectでは不十分だったため、Microsoftが文書で
    ; 指定する完全再描画の形(RedrawWindow+RDW_ALLCHILDREN|RDW_FRAME)に差し替えた。
    DllCall("RedrawWindow", "Ptr", lv.Hwnd, "Ptr", 0, "Ptr", 0
        , "UInt", 0x0001 | 0x0004 | 0x0080 | 0x0400)   ; RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_FRAME
    Critical("Off")
    DiagSchedulePaintProbe()   ; 描画実測プローブ(_docs/SHINDAN-PAINT-PROBE-DESIGN.md)
}

; 表示行番号→行頭ラベル文字列。1〜10は数字キー(0=10番目)、11〜20はShift+数字キー(2026-07-18〜、
; ユーザー要望により11件目以降にも割り当てを拡張)。21件目以降はショートカット対象外のため空白。
; FillLauncherHistoryLV/FillLauncherSnippetsLVで共用。
LauncherRowKeyLabel(dispRow) {
    if (dispRow <= 10)
        return Mod(dispRow, 10) . " "
    if (dispRow <= 20)
        return "⇧" . Mod(dispRow - 10, 10) . " "
    return "   "
}

; ShowLauncherとRefreshLauncherHistoryで共用。21件目以降は番号なし(数字キー対象外)。
; Icon0省略不可(省略すると全行に1枚目が出る既知の仕様。SnipMgrHistRefreshと同じ)
; query != ""のときは本文に部分一致する行だけを表示し、LauncherHistFilterMapに
; 「表示行(1始まり) → ClipHistoryの実インデックス」を積む。数字キー/クリック選択は
; 表示行番号で来るため、呼び出し側(PasteHistoryAt等)の手前でこのマップを経由して実インデックスへ変換する。
; 表示は500件で打ち切る(履歴の永続化でメモリ保持件数が最大10000件になりうるため、UIが
; 全件描画で重くならないようにする)。打ち切り時もLauncherHistFilterMapは必ず表示行ぶん積む
; (空のままだと「マップ空=1:1素通し」という既存規約(ResolveHistRow)と矛盾し、501行目以降が
; 存在しないのに1:1変換が通ってしまう)。検索(query)自体は全件を対象に走査する。
FillLauncherHistoryLV(lv, query := "") {
    global ClipHistory, LauncherHistFilterMap
    static DisplayMax := 500
    ; Critical: FillLauncherSnippetsLVと同じ地雷(-Redraw〜+Redraw区間へのタイマー割り込みで
    ; WM_SETREDRAW OFFが残留)を先回りで防ぐ。詳細: _docs/SHINDAN-PAINT-PROBE-DESIGN.md C-4節
    Critical("On")
    lv.Opt("-Redraw")
    lv.Delete()
    LauncherHistFilterMap := []
    dispRow := 0
    for i, v in ClipHistory {
        s := RegExReplace(v.text, "\s+", " ")
        if (query != "" && !InStr(s, query) && !InStr(v.time, query))
            continue
        dispRow += 1
        if (dispRow > DisplayMax)
            break
        LauncherHistFilterMap.Push(i)
        txt := LauncherRowKeyLabel(dispRow) . (StrLen(s) > 58 ? SubStr(s, 1, 58) . "…" : s)
        lv.Add((v.type = "image") ? "Icon" . (HistThumbIndex(v) + 1) : "Icon0", txt)
    }
    lv.Opt("+Redraw")
    DllCall("RedrawWindow", "Ptr", lv.Hwnd, "Ptr", 0, "Ptr", 0
        , "UInt", 0x0001 | 0x0004 | 0x0080 | 0x0400)   ; RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_FRAME
    Critical("Off")
    DiagSchedulePaintProbe()   ; 描画実測プローブ(_docs/SHINDAN-PAINT-PROBE-DESIGN.md)
}

; 履歴→定型文昇格。IniWriteは使わず、UTF-8明示のFileAppendで追記する
; 引数は要素参照v(idxではない)。メニュー表示中の新規コピーでidxがずれても対象は動かない(G節)。
PromoteHistoryItem(v) {
    if (v.type != "text")
        return                                 ; 画像はsnippets.ini非対応(メニュー非表示と二重の防御)
    text := v.text
    CloseLauncher()
    ib := InputBox("この内容を定型文に登録します。名前を入力:", "定型文に昇格", "w380 h120", SubStr(RegExReplace(text, "\s+", " "), 1, 12))
    label := (ib.Result = "OK") ? RegExReplace(Trim(ib.Value), "[=\[\];]") : ""
    if (label = "")
        return
    body := StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "\n")
    path := A_ScriptDir . "\snippets.ini"
    try {
        nl := (FileExist(path) && !RegExMatch(FileRead(path, "UTF-8"), "\R$")) ? "`n" : ""
        FileAppend(nl . label . "=" . body . "`n", path, "UTF-8")
        ArchiveSnippetsCsv()                  ; 定型文フォルダ保存(ONの場合のみ)
        Flash("定型文に登録しました: " . label, 1800)
    } catch as e {
        Flash("登録に失敗しました: " . e.Message, 2000)
    }
}

; hk例: "1"〜"9","0"(1〜10番目) / "+1"〜"+9","+0"(Shift付き、11〜20番目、2026-07-18〜)
LauncherPickKey(hk, *) {
    shifted := (SubStr(hk, 1, 1) = "+")
    digit := shifted ? SubStr(hk, 2) : hk
    n := (digit = "0" ? 10 : Integer(digit)) + (shifted ? 10 : 0)
    if (LauncherTab.Value = 1)
        PasteHistoryAt(ResolveHistRow(n))
    else
        UseSnippetAt(ResolveSnipRow(n))
}

; --- 起動時 ---
LoadSitesConfig()
SettingDefsInit()
if FileExist(A_ScriptDir . "\settings.ini")
    LoadSettingsIni()
else
    MigrateSettingsIfNeeded()   ; sites.ini/startup-prompted.flagから現在有効値を吸い上げsettings.iniを初回生成
SetTimer(StartHistoryStoreLoad, -50)   ; 起動シーケンス本体を待ってから履歴ストアを読み込む
SetTimer(StartDiagAutoSendIfConsented, -1000)   ; 同意済みなら起動のたびに自動送信を再開(未同意なら何もしない)
OnClipboardChange(ClipChanged)
; 検疫中の未確定項目は書かずに終了する(fail-closed)。PendingArchiveは単なるメモリ配列なので
; プロセス終了で自然に消えるが、意図を明示するためOnExitで明示クリアする。
OnExit(DiscardPendingArchiveOnExit)
OnExit(FlushSettingsOnExit)
OnExit(FlushHistStoreRewriteOnExit)
; 数字キー1-9,0=10、Shift+数字=11-20(2026-07-18〜): ランチャーがアクティブな間だけ有効
; （HotIfスコープ限定・解除処理は不要）
HotIf (*) => IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)
Loop 10
    Hotkey Mod(A_Index, 10) . "", LauncherPickKey
Loop 10
    Hotkey "+" . Mod(A_Index, 10) . "", LauncherPickKey
HotIf
; 定型文の管理ウィンドウの数字キー1-9,0 = 「表示中のn行目を選択」専用(ペーストはしない)。
; ランチャー側の数字キー=ペースト実行とは役割を分離する(貼り付け先の文脈がここには無いため)。
; 一覧ListViewにフォーカスがある間だけ有効にし、ラベル/本文/検索Editへの数字入力を奪わない。
HotIf (*) => IsObject(SnipMgrGui) && WinActive("ahk_id " . SnipMgrGui.Hwnd) && SnipMgrLVFocused()
Loop 10
    Hotkey Mod(A_Index, 10) . "", SnipMgrPickKey
HotIf
; Ctrl+Shift+F = 検索へフォーカス(Clibor同キー・第2ラウンド)。ランチャーは開いた瞬間に検索欄へ
; 自動フォーカス済みだが、一覧クリック後に検索へ戻る手段として両窓に同キーを揃える。
HotIf (*) => IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)
Hotkey "^+f", (*) => LauncherSearchEdit.Focus()
HotIf
HotIf (*) => IsObject(SnipMgrGui) && WinActive("ahk_id " . SnipMgrGui.Hwnd)
Hotkey "^+f", SnipMgrFocusSearch
HotIf
EnsureStartMenuShortcut()   ; トースト通知アイコンのためのAUMID登録(TrayTipより前に実行する必要がある)
TrayTip("送信サジェスト", "常駐を開始しました", "Mute")

; トレイメニューに監視トグル・バージョン表示を追加。自動起動のON/OFFは設定ウィンドウに一本化(v1.13.0〜)。
A_TrayMenu.Add("クリップボード監視を一時停止", ToggleClipWatch)
A_TrayMenu.Add("クリップボード履歴を全削除...", ConfirmDeleteHistoryAll)
A_TrayMenu.Add("定型文の管理...", ShowSnippetManager)
A_TrayMenu.Add("定型文ファイルを編集 (snippets.ini)", EditSnippetsFile)   ; 上級者向け(生のiniを直接編集)。通常は上のGUIで足りる
A_TrayMenu.Add()  ; セパレータ
; 非永続の原則の例外(v1.18.0〜既定ON)。経緯は_docs/CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md参照
; トレイ項目名だけでは何が起きるか分からないという声を受け、専用の設定ウィンドウに集約。
A_TrayMenu.Add("設定...", ShowSettingsWindow)
A_TrayMenu.Add()  ; セパレータ
A_TrayMenu.Add("設定フォルダを開く", (*) => Run('explorer.exe "' . A_ScriptDir . '"'))
A_TrayMenu.Add("診断情報をコピー", CopyDiagnostics)   ; AIチャットに貼るための計器ダンプ(履歴本文は含まない)
A_TrayMenu.Add("診断ページで見る", ShowDiagnosticPage)   ; 診断情報を送信してshindan/を自動で開く(2026-07-18〜)
A_TrayMenu.Add()  ; セパレータ
A_TrayMenu.Add("v" . AppVersion, (*) => 0), A_TrayMenu.Disable("v" . AppVersion)
A_TrayMenu.Add()  ; セパレータ

; 初回起動時（スタートアップ未登録かつ確認未表示）は自動実行を促す
if !IsStartupRegistered() && !SettingsMap.Has("state.firstrunprompted") {
    SetSetting("state.firstrunprompted", "1")
    result := MsgBox("次回からWindows起動時に自動で立ち上げますか？`n（あとからトレイの「設定...」でいつでも切り替えられます）",
        "送信サジェスト", "YesNo Icon?")
    if (result = "Yes")
        EnableStartup()
}
