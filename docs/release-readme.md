# SoundPrep

REAPER Media Explorer用の試聴・音量調整ツール。Windows / macOSでの動作確認用配布です。

## ReaPackから導入

必要環境: REAPER 7.35以降、SWS、JS_ReaScriptAPI、ReaPack。Windowsは10/11のx64版が対象です。

1. `Extensions → ReaPack → Import repositories…` に次のURLを追加します。

   ```text
   https://github.com/PontakuAudio/SoundPrep-Testing/releases/latest/download/index.xml
   ```

2. `Browse packages…` で **SoundPrep** を検索してInstallします。
3. REAPERを再起動し、Main Action Listから `SoundPrep.lua` を実行します。

Native helperは同梱済みです。Python / FFmpegは不要です。旧SoundPrepを導入済みの場合は、旧パッケージをアンインストールしてREAPERを再起動してから導入してください。

[ZIP配布](https://github.com/PontakuAudio/SoundPrep-Testing/releases/latest) · [詳しい導入手順](docs/install.md) · [MIT License](LICENSE) · [第三者ライセンス](THIRD_PARTY_NOTICES.md)
