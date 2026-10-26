# Native Presets & Tools

Media Explorerの **Edit…** から開く常設パネル。macOSはCocoa、WindowsはWin32のネイティブ部品を使う。外側をクリックしても閉じず、Done・タイトルバーの閉じるボタン・Escapeで閉じる。MacではCmd+Wも利用できる。再度Edit…を押すと既存パネルを前面へ戻す。

上部にRaw／各Presetのボタンを横並びで表示し、1クリックで編集対象を切り替える。選択中のボタンは押下表示になり、入りきらない場合は次の行へ折り返す。長い名前はツールチップでも確認できる。その下でSave preset・Revert saved・Edit FXを操作する。Play／Stop、Replay、Raw / Processed、Focus MEも利用できる。

- **Sound**: 名前、Reverse、Pitch、Rate、Preserve Pitch、Output gain。
- **Normalize**: LUFS MaxM／Zwicker Max／Zwicker P95、目標値、Max boost、原音Peak guard、校正値。操作バーのCustom…はこのタブを開く。
- **Export options**: プリセットごとのTail、最終LUFS正規化、True peak limiter。
- **Manage**: 新規作成、複製、順序変更、FXチェーン取り込み、Action slot、削除。削除は同じプリセットのConfirm deleteで確定する。
- **Tools**: 解析結果、再解析、選択したDropのレンダー、出力フォルダー選択、WAV書き出し、REAPERのRender設定。

音の変更は試聴に反映され、パネルを閉じたり別のプリセットへ切り替えても保持する。Save presetはFXを含めて保存し、Quit時も各プリセットを保存する。RawはNormalizeとPeak guardを保存し、Reverse／Preserve Pitchは一時的な切替になる。App settingsは引き続き独立したSettings…パネルで変更する。

旧スタンドアロンUIは削除済みで、ReaImGuiの導入は不要。対応していないNative helperは起動時に更新を案内する。今回のLuaとNative helperはセットで更新し、helperの置換前にREAPERを終了する。

## 実装と検証

`lib/am/editor_panel.lua`が両OS共通の入力検証、下書き、保存・解析・書き出しを担当する。Nativeの各イベントにプリセットIDを添え、選択変更前の遅延イベントを新しいプリセットへ適用しない。不正な値は下書きへ格納する前に拒否する。入力中の値は定期状態更新で上書きせず、別プロジェクトでは編集を無効にして閉じる操作だけを維持する。

`tests/editor_panel.lua`で下書き保持、入力検証、Raw制約、削除確認、各操作の接続を確認する。`native/test_bar.mm`と`native/windows/test_windows.cpp`は同じ`tests/native-editor-state.json`を使い、実際のCocoa／Win32コントロール、キーボード入力、フォーカス喪失後の維持、終了時の破棄を検証する。Windowsの実行テストはMSVC x64のCI対象。

2026-10-24のローカル検証: 共有Lua 66件、Cocoa実コントロール試験、Universal helperビルド、契約生成・配布・パッケージ試験25件が通過。ReaImGuiを外した専用REAPER 7.82でUnicode名の保存、数値編集、複製、解析、WAV書き出し、閉じる／再表示を確認した。WindowsはMinGWによるUIソースと実コントロール試験のコンパイルを確認。MSVC／Windows実機での実行結果はこのローカル検証には含めていない。
