# 標準波形から加工音を配置する

2026-10-03 / v0.10.19。操作の中心はMedia Explorerの標準一覧・波形。波形で範囲を選択し、そのままタイムラインまたはトラックパネルへドラッグする。別のDragボタンやPreset Browserは作らない。

## 決定した仕様

- Normalize・source peak guard・Macro output gainだけの場合は、元ファイルの1テイクへ合計ゲインをItem Volumeで設定する。Take Volumeは1、Monitorゲインは除外する。範囲・位置・元音声を保持し、レンダー・待機recipe・後続レンダーを作らない。再生／録音は継続する。加工のないRawは標準D&Dのまま。
- FX・Reverse・Pitch・Rate変更・チャンネル変換を伴う場合は、新しいArrangeアイテムに2テイクを作る。`Source + FX` は元音声と編集可能なTake FX、`Rendered` は加工済み音声。初期選択はRenderedで、同時再生はOFF。NormalizeはFX前のゲインとして維持する。
- Rendered選択中の元テイクはFXをOfflineにする。FX画面の表示だけでは復帰しない。常駐中はSource選択・全テイク再生で復帰する。元からのOffline／バイパスは保持する。常駐終了中はMain Actionの `Restore selected source FX` で復帰する。`Offline inactive source FX` は現在のプロジェクトの既存分を一括処理する。
- 既定は `settings.insert_handles = true`。全尺を加工して保持し、アイテムの表示範囲を選択範囲に合わせる。左右を伸ばしたときも同じ加工の続きが聴ける。
- OFFは選択範囲だけを音声化する。範囲外とFX tailを持たない。
- レンダー対象で範囲未指定なら全尺。Reverse・Pitch・Rate・原音のNormalize Gain・FX・Macro Output Gainを焼き込む。MonitorとExport専用の最終マスタリングは含めない。
- 設定は既存JSONのschema 1へ追加。項目のない既存bankはONへ移行する。

## 解析完了前のD&D（2026-10-23、未公開修正）

Normalize／peak guardが必要でも、解析中・未解析という理由だけではドロップを拒否しない。標準D&Dが作ったアイテムをその位置で一時ミュートし、名前に `[SoundPrep: analysing]` を表示する。音量目標・チャンネル選択・FX・範囲をドロップ時点で固定し、全ファイルの解析が揃ってから補正／加工を適用して元のミュート状態へ戻す。解析済みの場合は従来の即時処理を使う。

待機中にMedia Explorerの選択を変えて元の解析がキャンセルされても、ドロップ専用の解析で続行する。アイテムの移動・選択変更は保持する。削除・Undo・音声編集・元ファイル／レンダー設定の変更は検証し、古い結果を適用しない。解析失敗やSoundPrep終了時に残る未処理アイテムはミュートを維持し、再ドロップが必要な旨を表示する。待機中のSoundPrep終了やプロジェクト再読込みからの自動復帰は行わない。

待機後の適用は挿入と別のUndo操作になる。適用後のUndoはまず待機アイテムへ戻し、さらにUndoすると挿入を取り消す。後からの適用で再生・録音を停止しない。加工が必要ならSource + FXを有効にし、自動レンダーは停止後に行う。音量だけの補正は元ファイルのItem Volumeへ設定する。

Luaのみの変更で、反映にはSoundPrepのQuit→再起動が必要。今回の変更によるNative helperの更新は不要。

## 責務とドロップ処理

`lib/am/insert.lua` は音声生成・再利用・時間変換・Takeへの設定を担当する。両OSのD&Dで音声加工が必要な場合は `render_item.lua` を使い、現在のプロジェクト内の一時トラックで標準アイテムFXレンダー（40209）を実行する。トラックは終了時に削除し、選択・書き出し設定・tail・波形進捗設定を成功／失敗時とも復元する。別プロジェクト・別REAPER・デバイス再初期化は行わない。通常のExportは従来の `export.lua` を使う。波形範囲はドラッグ開始時に固定する。

`native/drop.mm` は、macOSの実際の `NSDraggingDestination` 呼び出しに限定した同期トランザクションを作る。Arrange、TCP、メインcontent viewのインスタンスにだけサブクラスを付ける。終了時は復元する。他の拡張が上に重なった場合はそのクラスを上書きしない。

1. `NSDraggingInfo` のsourceが標準波形またはファイル一覧であることを確認する。SWELLが所有view/windowをsourceとして返す場合は、同じジェスチャーのmouse-downが対応するコントロール内だったことも必要。アプリ内mouse monitorはイベントをそのまま返し、操作を横取りしない。
2. ドロップ先がArrangeまたはTCP内、波形ならファイルが1件、一覧なら1件以上、対象プロジェクトがcompanionと同じことを確認する。TCPは数値IDではなく `REAPERTCPDisplay` クラスで特定する。ルートviewに配送される場合も、この2領域にだけ処理を限定する。
3. `internal/Process waveform drop.lua` を同期実行。ファイルidentity・Macro・live FX状態・標準Pitch/RateとTempo match・波形の範囲を固定する。この段階ではプロジェクトを変更しない。検証失敗時は標準挿入を呼ばない。
4. 元のREAPERドロップハンドラーを呼び、配置先・位置・標準の挿入動作をREAPERに任せる。TCP上の既存トラックへの挿入と、空白部分への新規トラック作成もこの経路を通る。
5. **この同期呼び出しの前後だけ**で生まれた新規アイテムを識別し、GUIDと元の音声ファイルを再照合する。対応はファイルごとに1つの新規アイテム。別のdefer cycleで新規アイテムを監視する方式ではない。
6. 停止中は同じUndo block内で加工音を生成／再利用する。元音声のテイクに凍結したFX chainとReverse / Pitch / Rate、原音Normalize Gainを設定する。Take volumeはFX前なので、Macro Output Gainが非ゼロなら標準JSFX Volume/Pan Smootherを末尾へ追加する。レンダー音声はFX・追加Pitch・Rate・Gainを持たない第2テイクとして追加し、こちらを選択する。2テイクのoffsetをそれぞれの時間軸に合わせ、ループと全Take同時再生を無効にする。全体を1つのUndo blockにまとめる。

既存Takeの置換など、要求と異なる挿入になった場合はこのトランザクションだけを戻す。以前のユーザー操作をUndoしない。Finderからの通常のドロップや別プロジェクトへのドロップは、この加工処理の対象外。後者ではバーも試聴操作を停止表示にする。

専用の公開「Media Explorer加工D&D API」はSDKに確認できない。この接続部分はmacOS/CocoaとREAPER内部UI（波形1046、ファイル一覧1001、Arrange1000）に依存する。音声処理・レンダー・アイテム設定には公開APIを使う。[Cockos SWELLのD&D実装](https://github.com/justinfrankel/WDL/blob/main/WDL/swell/swell-dlg.mm)、[REAPER SDK](https://github.com/justinfrankel/reaper-sdk/blob/main/sdk/reaper_plugin.h)

## 時間対応

元の長さ `L`、選択範囲 `[a,b]`、再生速度 `r` のとき、配置長は `(b-a)/r`。

| モード | Take source offset | 音声に残る範囲 |
|---|---:|---|
| 範囲外保持・順方向 | `a/r` | 元の全尺とMacroのtail |
| 範囲外保持・Reverse | `(L-b)/r` | 逆転した全尺とMacroのtail |
| 完全クロップ | `0` | 指定範囲だけ。tailなし |

上表はRenderedのoffset。Source + FXは両モードで元音声の全尺を保持し、offsetは順方向が `a`、Reverseが `L-b`、Take rateは `r`。Renderedが範囲限定でも、元テイクの端を伸ばせる。

全尺を先にFX処理するため、残響やディレイには選択範囲より前の文脈が入る。完全クロップは範囲の先頭からFXを処理する。この違いは範囲外を音声として残すかどうかに伴う仕様。

D&Dでは一時アイテムの長さと開始位置を公開APIで設定してからアイテムFXを適用する。レンダー音声長はサンプル単位になり、生成後に期待長さとtailを検証する。

## 保存・再利用

保存済みプロジェクトの隣の `Audition Macro Media/` にWAV / RPP / Macro JSON / 再利用判定JSONを作る。未保存プロジェクトは `data/inserted-media/`。プロジェクトが参照する実ファイルなので自動削除しない。プロジェクト移動・共有時はREAPERのメディアコピーを使う。

判定には元ファイルのpath/mtime/size、Macro、FX状態、Normalize Gain、fade、render revisionを含める。短いhashが衝突しても完全なJSON一致を確認し、別の出力へ誤って再利用しない。生成後も長さと元ファイルidentityを検証する。保持モードでは範囲を変えても全尺レンダーを再利用できる。

未キャッシュの場合は同期offline renderなので、素材の長さやFXによって待ち時間がある。フルhandles音声では範囲だけ変えても再レンダーしない。自動焼き込みは既定ON。再生・一時停止中は未キャッシュならタイムラインを停止し、そのD&D内でRenderedまで作成する。完了後は停止状態を維持する。キャッシュ済みなら再生を継続する。録音中だけはSource + FXを配置し、停止後に焼き込む。待機中に移動したアイテムは維持し、トリム・FX等を編集したものや削除したものは自動変更しない。手動モードは `Automatically render uncached drops` をOFFにし、選択後に `Render selected drops` を実行する。凍結したrecipeを恒久保存するため、保存／再起動後やトリム・Take FX編集後も手動焼き込みできる。

companionが所有する別PCM sourceで、欠けている波形だけを `PCM_Source_BuildPeaks` のBegin / Run / Finishで作る。各tickでは約4 msを目安にRun間で制御を返し、完了時にArrangeを再描画する。デコーダーの1回の処理時間自体を制限するものではない。選択やアイテム位置・長さは変更せず、処理途中の終了ではPCM sourceを破棄する。D&D成功時はArrangeへキーボードフォーカスを戻す。[公式ピークAPI](https://www.reaper.fm/sdk/reascript/reascripthelp.html#PCM_Source_BuildPeaks)、[計測と検証](validation.md)。

## 試聴との関係と残る制限

`MediaExplorerGetLastPlayedFileInfo` から同じファイルの範囲だけを読み、ループ選択（128）・時間選択（256）の両方に試聴範囲が自動追従する。古いファイルの情報は流用しない。範囲変更時は範囲先頭から加工再生し、手動の「Use ME time selection」は不要にした。[公式API](https://www.reaper.fm/sdk/reascript/reascripthelp.html#MediaExplorerGetLastPlayedFileInfo)

v0.7の音声試聴は公開SDKの低遅延Previewと既存FX bankを使う（旧helperはSWS CF Previewへフォールバック）。v0.4ではMacro / Raw A/B・Reverse切替で元ファイルの時間位置を保持する。v0.7.1で標準波形のクリックシークを連携した。v0.8では加工音の実位置を標準波形へ描画し、時計も更新する。音声は同じ低遅延Previewで再生し、二重再生やFXの再生成は行わない。バー操作後は直前のコントロールとテキストカーソルへ復帰する。

v0.5の別ホスト先読みはv0.10.16で廃止。既存bankの `prepare_drops` は互換性のため読めるが、ONでも別REAPERを起動しない。[旧先読みの検証記録](background-preparation.md)

macOS arm64 / Windows x64のmono/stereo・通常の新規アイテム挿入を対象とする。Sampler、既存Take置換、多チャンネル、Linuxは対象外。macOS 7.81ではCocoaの実ドロップ先にテスト用payloadを渡して確認した。物理マウスジェスチャーや商用FXの検証には制約が残る。API統合テストとの区別は [検証記録](validation.md) に記載する。

## v0.6の標準コントロール連携

標準の選択モード40015（Stop preview and display info/waveform）を使い、素材変更時にREAPER自身にピークと情報を更新させる。1011/autoplayをOFFにするだけでは40070/continue previousが残り、波形を読み込まない設定になり得る。元の3状態を保存して終了時に復元する。REAPER 7.80/macOSのOptionsメニュー操作とtoggle状態の差分でIDを確認した。

2026-10-23修正: 起動時の選択は停止状態で読み込み、最初のpollを選択操作として自動再生しない。後続の選択は`Follow file selection`に従う。フルパス42026、先頭パス42134、拡張子42091をセッション全体で強制しない。非表示のパスを特定する必要がある場合だけ、同じ同期呼び出し内で表示形式を切り替えて選択行を読み、終了・失敗時に元へ戻す。検索結果の同名行をキャッシュで混同しないよう、行番号と検索文字列も照合する。last-played APIは別素材の情報が残るためパス解決には使わない。Windowsのmodalな複数選択D&Dも同様にNative側で一時的な表示切替を復元する。旧セッションの復旧情報は従来通り復元し、新セッションの終了ではユーザーによる表示設定の変更を保持する。

Pitch 1021、Rate 1454、Preserve pitch 40068を読み、CFの同じハンドルを更新する。Macro選択時は逆方向に標準コントロールへ保存値を反映する。標準の素材変更時リセット42014は起動中だけ解除し、終了時に戻す。範囲編集後も停止中の `MediaExplorerGetLastPlayedFileInfo` にtime selectionが反映されることを確認した。

ファイル一覧のD&Dはpayloadのpathを正とし、試聴中でないファイルや複数選択にも対応する。Macro・live FX状態・直前のnative Pitch/Rateを同一トランザクションで固定し、一覧では全尺を使用する。音量だけのRaw NormalizeはItem Volumeで反映する。Normalizeが必要な各ファイルはpath/mtime/size/解析方式が一致するキャッシュを照合し、1件でも未解析なら全体を中止する。

標準Stopは「すでに停止中」だと波形も解除する。CFの通常再生開始ではStopを送らない。v0.6 helperの `AM_TransportOwnAudio` が標準transport操作をCFへ直接渡し、native transportを二重に開始させない。初回attach/recoveryではミュートしたPlay/Stopの組で素材を読み込んだままnative transportを静止させる。旧helperとの互換経路でも、単独Stopの代わりにこの組を使用する。

## v0.7の音声応答

SWS CF Previewは `Buffered | Varispeed` で再生し、加工済みブロックの先読みがPitch変更を約240 ms遅らせる条件を再現した。トラックのI_PERFFLAGSやpitch modeだけでは解消しなかった。v0.7は公開 `PlayTrackPreview2Ex` のbufferingを無効にし、REAPERのデコーダーとpitch-shift APIで現在のブロックを処理する。変換変更時もFXインスタンスは維持する。標準コントロールの通知をnative側で処理するため、Cocoaのノブ操作中もLua deferを待たない。

Source + FXは編集可能な再処理であり、全尺を先に処理したRenderedの残響・ランダムなFX状態まで再現するものではない。保持された加工済みの続きと確定した音はRenderedで利用する。FX snapshotはプロジェクトのTake FXへ埋め込むため、元のMacro bankを変更・削除しても保存済みTake FXは残る。


## v0.7.1の波形シーク

`native/wave.mm` は標準波形のWndProcへ全イベントを転送し、通常クリックのmouse-up処理が完了した後にREAPERが確定した時刻を取得する。独自のピクセル→時刻換算を使わず、標準のズーム・スクロール処理を利用する。選択範囲があると標準時計はその範囲の先頭からの相対時刻になるため、公式APIの範囲と時計の全長から元ファイルの位置へ換算する。秒単位／拍単位の丸め表示が有効な場合は、同期的に精密表示を読み、再描画前に設定を戻す。検索欄や一覧へフォーカスを移動しない。

再生中かつ同じソース範囲なら、既存Previewの位置をnative callback内で更新する。Luaのdefer・ファイル再ロード・FX再生成を待たない。Reverseと現在のRateから内部位置を換算する。REAPER自身がクリック時に範囲を解除した場合は、次のcontroller更新でSECTIONだけを再生成してクリック位置を適用する。停止中は元ファイルの位置をbookmarkにし、Play / Play-pause / Play from last seek positionで利用する。

範囲ドラッグ、修飾キー付きジェスチャー、キャンセルされた操作を通常クリックへ変換しない。D&D用のCocoa handlerは既存のものを利用する。Media Explorerのclose/reopenや子コントロール再作成時にobserverを付け直し、終了時は他の拡張のWndProcを上書きせずに解除する。

標準操作の維持は受け入れ条件とする。クリック・範囲選択・ズーム・transport・ファイル変更・D&D・フォーカス復帰を変更時に回帰確認する。v0.8でカーソル、Tempo match、Start on bar、自動次ファイル再生を連携した。検証対象と結果は下記およびvalidation.mdに記録する。第三者が定義した任意のカスタムactionまで検証済みという意味ではない。


## v0.8の連続カーソルと標準transport

`native/cursor.cpp` が公開Previewの位置を読み、JS_ReaScriptAPIの `JS_Composite` で2ピクセルの線を標準波形へ重ねる。波形、ルーラー、スクロールバー、マウス操作はREAPERが管理する。独立したウィンドウや追加の音声再生は作らない。音声ロックを取れないフレームは描画を待たせずスキップし、同じ位置なら再合成しない。

元ファイル位置へRate・Reverse・SECTION範囲を逆変換する。ループ境界は剰余で折り返し、Pause中は位置を保持する。時間表示の丸め設定を保ち、native操作の前にはREAPER自身の時計を戻す。Detach時は自分が最後に書いた表示だけを復元する。素材不一致、非表示、無効な波形には描画しない。

表示位置は標準の水平スクロール情報から求める。Zoom to selectionではREAPER 7.80の前後5%の余白とクリック確定位置を利用し、狭い範囲で整数スクロール値の丸め誤差が拡大しないようにする。任意の手動ズーム／スクロールでは公開スクロール情報の精度に従う。音声のシーク位置そのものは引き続きREAPERが確定した時計を使う。

Tempo matchは標準APIのsource BPM、mode、プロジェクトBPMから実効Rateを求める。Macroの保存Rateと標準Rateノブは倍率適用前の値を保持する。試聴・挿入snapshotは実効Rateを使う。

Start on barは標準の1012と42171を読む。プロジェクト再生中に待機を指定した場合は、公開TimeMapで次の小節を求め、音声ブロック内の無音区間で開始位置を合わせる。待機中にRateを変えても待ち時間を伸縮しない。待機なしの場合は現在の小節内位相から始める。Luaのdeferで再生開始を予約する方式ではない。待機を予約した後のテンポマップ編集は、次の再生操作で再評価する。

EOFの次ファイル移動は標準の40030に任せる。ソートや検索結果の走査を独自実装しない。RepeatがOFFかつ標準42004がONの場合にのみ進み、手動Stopでは進まない。Unloadは加工音も止め、その後のPlayで標準波形を再ロードする。
