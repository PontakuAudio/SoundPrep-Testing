# SoundPrep — Windows 10/11・REAPER x64

**SoundPrep v0.11.4** の通常利用の解析は同梱C++ helperがREAPERのデコーダーで行い、Python／FFmpegは不要。同梱DLLは0.11.4。更新後はDLLを読み直すためREAPER再起動が必要。新版の解析経路のWindows実機確認は未完了。以下の版番号付き説明は変更履歴である。

v0.10.0でWindows用ネイティブhelper、埋め込み操作バー、D&Dアダプター、解析／先読みworkerの起動処理を追加した。MacroのJSON、FX bank、試聴・書き出しのLua処理はmacOSと共有する。

Windows CIにはMSVCビルドと自動試験がある。2026-09-30にWindows実REAPER 7.81で旧版の試聴API、標準Pitch/Rate、解析、隔離レンダー、2テイクとRendered波形、Undo/Redo、検索UIの条件変更とフォーカスを確認した。**最新の多ch・自動NormalizeのWindows実機確認、マウスD&Dの配送全経路、実IME変換、WASAPI／商用FXの可聴評価は未完了。** 下表は引き続き受け入れ確認項目として使用する。

## 導入

ReaPackのImport URLと導入手順は[導入ガイド](install.md)を参照。ReaPack版ではNative helperも導入されるため、インストール後にREAPERを再起動する。以下はZIPを使う場合の手順。

1. [Releaseページ](https://github.com/PontakuAudio/SoundPrep-Testing/releases)から `soundprep-0.11.4-windows-x64.zip` を選ぶ。
2. ZIPの `SoundPrep` フォルダーを書込み可能な固定の場所に展開する。例: `Documents/SoundPrep`。`Program Files` 配下は避ける。スクリプトと `lib` / `resources` / `build` / `native/vendor` の配置を維持する。
3. REAPER **x64** にSWS、JS_ReaScriptAPIのWindows x64版を導入する。REAPER 7.35以降が必要。
4. REAPERのMain Action List → New action → Load ReaScriptから `SoundPrep - Install actions.lua` を実行する。初回は `build/reaper_audition_macro.dll` をResource Pathの `UserPlugins` に配置する。作業を保存し、REAPERを再起動する。
5. Mainの `SoundPrep.lua` を実行する。Media ExplorerのAction ListでSlot 0〜9、Reverse、AB等のキーを割り当てる。既存のキー割当は自動で変更しない。

Normalizeは追加の実行環境なしで利用できる。Editの `Loudness meter` で既定のLUFS MaxMまたはZwickerを選ぶ。ZwickerはMaxが既定、P95も選択可能。目標sones・校正値・原音Peak guardの設定は[導入ガイド](install.md#normalizeの設定)を参照。

v0.10.7以降のWindows D&Dは同じREAPER内で直接レンダーする。別REAPER・レンダーworker・Pythonは不要。v0.11.0ではラウドネス解析にもPython / FFmpegは不要。現在の自動焼き込みONでは、キャッシュ済みなら再生を続けて配置し、未キャッシュならタイムラインを停止してD&D内でRenderedまで作成する。完了後は停止状態を維持する。録音中はSource + FXで挿入し、停止後にRenderedを追加する。このD&D変更はLua更新とcompanion再起動で反映される。

v0.10.8ではD&D完了でMEPの試聴を停止し、波形の範囲選択・変更で停止／Pause中も範囲先頭から即時再生するよう変更した。Preserve PitchはRaw・初期Macro・新規Macroで既定OFF。起動済みcompanionにはLua変更が反映されないため、SoundPrepをQuitして起動し直す。現在のパッケージには同梱のhelperを使用する。

`.RfxChain` とJSONは共通だが、Macで使っていた市販FXはWindows版も必要になる。Mac専用AUを含むchainはWindows用FXに置き換える。同梱Macroは標準JSFXを使用する。

## 更新とPortable版

ReaPack版はReaPackから更新する。Native helperを更新した場合はREAPERを再起動する。ZIP版では既存の `data` を保存したまま新しいパッケージのファイルを展開する。すべてのREAPERを終了し、パッケージのフォルダーでPowerShellから実行する。

```powershell
./tools/install_native.ps1
# Portable版など、標準の %APPDATA%/REAPER と異なる場合:
./tools/install_native.ps1 -ResourcePath 'D:\REAPER portable'
```

Resource PathはREAPERのOptions → Show REAPER resource path in explorer/finderで確認できる。更新ツールは起動中のREAPERがあると停止し、x64 DLLを確認してから置換する。以前のDLLを `.backup` に保持する。再起動後にAction Installerを再実行して追加Actionsを登録する。

PowerShellの実行ポリシーでスクリプトを実行できない場合は、REAPER終了中に `build/reaper_audition_macro.dll` をResource Pathの `UserPlugins` へ手動コピーしてもよい。システムの実行ポリシーを変える必要はない。旧先読みworker用DLLは現在の実行に不要で、公開用ZIPに含めない。

## Windows実機での確認

範囲試聴のRepeatは、Media Explorerのボタン／Action操作と同時にNative previewへ反映する。短い範囲がLuaの次回更新前に終端へ達する場合もループを維持する。この修正にはDLL更新とREAPER再起動が必要。ソースに含まれる `python tools/run_windows_integration.py --playback-test` は実ボタン操作、Lua更新待ち中の反復、Raw／Macro／Preserve Pitchとタイムライン再生中の範囲ループを専用ホストで確認する。

テスト用の空プロジェクトと、短いモノ／ステレオWAVを使う。まず既定のHeavy / Dark / Reverseで確認し、その後に常用FXを試す。標準MEとの比較はcompanionを終了した状態を基準にする。

| 確認 | 合格条件 |
|---|---|
| 起動と復元 | 一覧上にバーが表示される。終了すると一覧寸法・標準Previewの設定が戻る。閉じる／再表示、ドック、幅変更でも波形を維持する |
| 一覧と試聴 | 上下キーで素材変更、0〜9でMacro、Raw/A/B、RでReverse。フォーカスが一覧に戻り、通常操作を続けられる |
| 波形 | クリック位置へシーク、カーソルが連続追従。範囲選択・ズーム・Play/Pause/Stop/Repeatを維持する |
| Pitch / Rate | 再生中の標準欄変更が反映され、操作から不自然に長く遅れない。音声デバイスのbuffer設定も記録する |
| Normalize | Python／FFmpegなしでLUFS MaxM・Zwicker Max/P95をRaw・Macro両方で確認する。初回解析後は再生を止めず徐々に反映し、同じファイル・解析方式はキャッシュを再利用する。停止／Pause中は自動再生しない |
| 多ch | Downmix OFFは元ch数・共通Normalize gain・Macro FXバイパス、ONはステレオ・Macro FXを確認。D&Dも同じ方式とゲインを保持する |
| 波形D&D | ArrangeとTCPの既存トラック／空白部分の両方。選択範囲、Source + FX / Renderedの2テイク、Rendered初期選択、Undo/Redoを確認 |
| 一覧D&D | 単一／複数ファイルをArrangeとTCPへ。全尺の2テイク、標準の配置ダイアログと挿入位置、1回のUndo/Redoを確認 |
| クロップ設定 | retain processed audio outside selection ONなら左右へ伸ばせる。OFFなら範囲外を保持しない。Reverse / Rate変更も確認 |
| 外部D&D | Windows Explorerからの挿入は標準のままで、Macroを勝手に適用しない |
| 検索 | slam展開、日文変換、条件解除、検索式編集、Apply/Restore。標準欄の手動変更を保護する。IME変換中に0/R等のActionが発火しない |
| 保存 | Macro名・Raw Normalize・設定を複数回変更し、終了／再起動後も保持する。日本語・空白を含むパスでも確認 |

Windowsでは旧先読み設定がONでも別REAPERを起動しない。ソースに含まれる `python tools/run_windows_integration.py --direct-test` は再生中の未キャッシュD&Dの即時完了、キャッシュ済みD&Dの再生継続、一時停止中と複数ファイルの挿入、Undo/Redoを確認する。商用プラグインのライセンス画面や固有のレンダー時間は別途確認が必要。

v0.10.2のD&Dアダプターは `WM_DROPFILES` に加え、MEのドラッグ処理内で直接新規アイテムを作る経路も扱う。Arrange/TCPの子ウィンドウへの配送とスクリーン座標を処理し、波形の範囲・Macro状態は標準挿入前に固定する。選択のみ／キャンセルではレンダーしない。一覧からは全尺、波形からは選択範囲を挿入する。**今回のWindows修正は実機での再確認が必要。** Win32 fixtureでは直接挿入・子ウィンドウ・選択情報の変化を検査するが、実REAPERの全ジェスチャーを再現したものではない。

## 状態の採取

Main Actionの `SoundPrep - Diagnostics.lua` はバージョン、依存API、DLL、バーの状態（旧解析用Python/FFmpeg候補が残る版もある）をConsoleに表示する。プロジェクトや設定は変更せず、外部送信もしない。パスが含まれるので共有時には必要に応じて伏せる。

v0.10.2は `Windows drops` に直近16イベントの配送経路と保存した範囲、読み込まれたアダプターのrevision（2）も出す。再現後に採取する。`AM_DropDiagnostics` が無ければ古いDLLがロードされているので、Resource Pathの `UserPlugins` を更新してREAPERを再起動する。

v0.10.3は再生中に `Preview timing`（処理位置、可聴位置、FX遅延、デバイス出力遅延、実際のブロックサイズ）と、MEP専用チェインの各FXの報告PDCを表示する。Rawと問題のMacroをそれぞれ再生して採取すると比較できる。`AM_Preview_SetLatencyTrack` がMISSINGなら、スクリプトだけ新しくなっておりDLLの更新が必要。

v0.10.4は `Waveform seek` にクリック通知数・キュー経由のrelease数・最後に解決した位置／範囲／標準時計／クリック座標、`Waveform cursor` に緑線の位置・波形幅・スクロール座標を表示する。`AM_WaveDiagnostics` がMISSINGなら旧DLL。イベントは診断で消費しないので、クリック直後に採取しても試聴操作に影響しない。

### 波形クリックのシーク修正（v0.10.4）

「白い線はクリック位置に出るが、緑の線と加工音は以前の位置を進む」という報告への修正。従来は波形WndProcに `WM_LBUTTONUP` が届くことを前提としていた。Windowsの標準側が内部のマウス処理ループでreleaseを消費する場合に備え、当該処理中だけREAPER UIスレッドのキューを観察し、標準側が位置を確定した後でシークする。範囲ドラッグ、修飾キー付き操作、Escapeやcapture喪失によるキャンセルではシークしない。緑線と早送りの座標計算は、スクロール座標単位と実際の波形幅を分ける。

**git pullだけではDLLは更新されない。** REAPER終了後、更新ZIPの `build` 内のDLLをpullしたリポジトリの `build` へコピーして `./tools/install_native.ps1` を実行し、REAPERを再起動する。スクリプトとDLLの両方を揃える。Windows実REAPERでのユーザー環境の再確認は必要。

### FXプレビューのタイミング修正（v0.10.3）

WASAPI / 2048 samplesで「Rawは正常、独自FX chainで位置ずれ・冒頭欠け・遅延」と報告された問題への修正。試聴専用のFXチェインはPDC先読みを使わず、Macro出力はフェーダーをゼロから戻さずに切り替える。プレビューの端点フェードは既定0 ms。従来の書き出し用フェード値は維持し、App settingsで個別に指定できる。レンダー、保存した `.RfxChain`、Source takeには試聴専用PDC設定を持ち込まない。

FXが内部で必要とするlookaheadやデバイスバッファはこの修正でも残る。2048 samplesは48 kHzなら1ブロック約42.7 ms、44.1 kHzなら約46.4 ms。これは総出力遅延とは異なる。ドライバー設定やMacroのFX設定を自動変更することはない。診断の値はREAPERとプラグインの報告に基づき、実出力の物理計測ではない。

開発側ではmacOSの実REAPERで512 / 2048 samplesと100 ms遅延FXを使って信号を検査した。Windows/WASAPIと報告された独自FX chainでの修正版の受け入れ確認は別途必要。

不具合があれば、診断結果に加え「波形／一覧」「Arrange／TCP」「ドック／別ウィンドウ」、表示スケール、REAPERのバージョンを記録する。音声遅延の場合はデバイス種類、サンプルレート、buffer size、使用FXも記録する。

## ソースからビルド

v0.11.0の公開リポジトリには既存Nativeコードを残しますが、新しい解析エンジンの実装はDLL内のバイナリとして配布します。公開ソースのみで完全なhelperをビルドすることはできません。通常はRelease ZIP／ReaPackを使用し、公開用の検証済みDLLは `prebuilt/` にも置きます。[配布方針](source-distribution.md)を参照してください。以下のフルビルド手順は、解析実装を含む開発環境向けです。

Windows実ホスト回帰は、ビルド後に `python tools/run_windows_integration.py` で実行する。開発用のSWS / JS_ReaScriptAPI / Pythonと、比較試験用のFFmpegを導入する。これらの検証用Python／FFmpegは通常利用の必要条件ではない。通常の設定を変更せず、`build/windows-review-*/host` に専用Resource Pathと合成WAVを作る。検索UIの目視には `--inspect-seconds 60`、実D&Dの検証には `--drag-test` を追加できる。専用起動DLL `reaper_am_test_host.dll` はテスト用で、通常のUserPluginsへは入れない。

Visual Studio 2022 C++ Build Tools、Windows SDK、CMakeを導入する。PowerShellで次を実行する。

```powershell
./native/build-windows.ps1
# 共通Lua試験も含める場合（公式Lua 5.4.8をSHA256検証して取得）:
./native/build-windows.ps1 -LuaTests
```

MSVC x64のDLLが `build` に作られる。REAPERの[公開C++ SDK](https://github.com/justinfrankel/reaper-sdk/blob/main/sdk/reaper_plugin.h)のABIに合わせ、MinGW DLL、x86、ARM64は対象にしない。公開用ZIPには実行用スクリプトとビルド済みDLL・ライセンス通知を同梱し、個人の設定・FX・解析キャッシュ・REAPERのライセンスファイルは含めない。

Preset／ToolsもWin32の常設パネルを使います。詳細は[ネイティブ編集パネル](preset-tools.md)を参照してください。
