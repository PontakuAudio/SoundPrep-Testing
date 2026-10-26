# SoundPrep

REAPER Media Explorer用の試聴・音量調整ツール。Windows / macOSでの動作確認用配布です。

**起動するのは `SoundPrep.lua` だけです。** 起動後はMedia Explorerに表示される操作バーを使います。

## ReaPackから導入

必要環境: REAPER 7.35以降、SWS、JS_ReaScriptAPI、ReaPack。Windowsは10/11のx64版が対象です。

1. `Extensions → ReaPack → Import repositories…` に次のURLを追加します。

   ```text
   https://github.com/PontakuAudio/SoundPrep-Testing/releases/latest/download/index.xml
   ```

2. `Browse packages…` で **SoundPrep** を検索してInstallします。
3. REAPERを再起動し、Main Action Listから `SoundPrep.lua` を実行します。

Native helperは同梱済みです。Python / FFmpegは不要です。同じSoundPrepパッケージの更新はReaPackから行います。旧Audition Macroパッケージから切り替える場合は、[設定の引継ぎ手順](docs/install.md#旧audition-macroからの切替)を参照してください。

ZIP版も、Main Action Listの `New action → Load ReaScript…` から `SoundPrep.lua` を読み込んで実行します。初回に再起動の案内が出たら、作業を保存してREAPERを再起動し、同じ `SoundPrep.lua` を実行してください。

新規導入時に自動登録するActionは起動用の1個です。キー操作・診断用Actionsが必要な場合だけ、同梱の `SoundPrep - Install actions.lua` を読み込んで実行します。通常の起動には不要です。既存のAction登録・キー割当は自動削除しません。

[ZIP配布](https://github.com/PontakuAudio/SoundPrep-Testing/releases/latest) · [詳しい導入手順](docs/install.md) · [MIT License](LICENSE) · [第三者ライセンス](THIRD_PARTY_NOTICES.md)
