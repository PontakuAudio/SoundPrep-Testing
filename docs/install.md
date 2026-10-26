# SoundPrepの導入

以下は**SoundPrep v0.11.3**の導入手順です。

配布先は[SoundPrep Releases](https://github.com/PontakuAudio/SoundPrep-Testing/releases)です。掲載されたReaPack indexとOS別ZIPを利用してください。

## 必要な環境

| 項目 | 必要なもの |
|---|---|
| REAPER | 7.35以降 |
| macOS | Apple Silicon / Intel向けuniversal helper |
| Windows | Windows 10/11、REAPER x64 |
| 拡張 | SWS、JS_ReaScriptAPI |
| ReaPackで導入する場合 | ReaPack |

Native helperは配布パッケージに同梱します。利用者によるビルドは不要です。REAPER本体と上記の拡張は同梱しません。Normalize／source peak guardも同梱helper内で処理するため、Python／FFmpeg／ffprobeの導入は不要です。Windows ARM64/32bitとLinuxは対象外です。

v0.11.0の解析はmacOS arm64の実REAPERでLUFS・Zwicker Max/P95、44.1／48／96 kHz、多ch・AmbiXと再生中のゲイン移行を確認しています。加工D&Dの実レンダー11ケースでもチャンネル数・ピーク・極性・共通ゲイン・Downmix OFF時のMacro FXバイパスを確認しました。新しい解析経路のWindows実機確認は未完了です。

## ReaPackから導入

1. REAPERにSWS、JS_ReaScriptAPI、ReaPackを導入します。
2. `Extensions → ReaPack → Import repositories…` に、次のURLを指定します。

   ```text
   https://github.com/PontakuAudio/SoundPrep-Testing/releases/latest/download/index.xml
   ```

3. `Extensions → ReaPack → Browse packages…` で `SoundPrep` を検索し、パッケージを選んでInstallを適用します。主スクリプトは `SoundPrep.lua` です。
4. Native helperも導入されるため、作業を保存してREAPERを再起動します。
5. Main Action Listで `SoundPrep.lua` を実行します。Media Explorerの一覧上に操作バーが表示されます。

Main／Media ExplorerのActionsはReaPackが登録します。Media ExplorerのAction ListでSlot 0〜9、Reverse、AB等へキーを割り当てます。既存のキー割当は変更しません。

## ZIPから導入

[Releaseページ](https://github.com/PontakuAudio/SoundPrep-Testing/releases)から、`soundprep-0.11.3-macos-universal.zip` または `soundprep-0.11.3-windows-x64.zip` を選びます。ZIP内の `SoundPrep` フォルダーを、書き込み可能な固定の場所へ展開します。Windowsの例は `Documents/SoundPrep` です。

フォルダー内の配置を維持してください。主な内容は次のとおりです。

```text
SoundPrep/
  SoundPrep.lua
  SoundPrep - Install actions.lua
  actions/
  internal/
  lib/
  resources/
  build/reaper_audition_macro.dylib または .dll
  tools/install_native.sh
  tools/install_native.ps1
  LICENSE
  THIRD_PARTY_NOTICES.md
  native/vendor/（第三者ライセンス）
```

1. REAPERにSWS、JS_ReaScriptAPIを導入します。
2. Main Action Listの `New action → Load ReaScript` から `SoundPrep - Install actions.lua` を読み込み、実行します。
3. helperが未導入なら、Installerが同梱のhelperをREAPER Resource Pathの `UserPlugins` へ配置します。作業を保存してREAPERを再起動します。
4. Main Action Listの `SoundPrep.lua` を実行します。

既存helperがある場合、Action Installerは上書きしません。下記のZIP更新手順で、REAPER終了中に更新してください。

## Normalizeの設定

追加の実行環境は不要です。`Edit…` のNormalizeタブで `Loudness meter` を選び、Normalizeを有効にします。設定はRaw／各Presetごとに保持します。Macroの変更は `Save preset` またはQuitで保存します。

- `LUFS MaxM` は既定の方式です。400 ms窓・100 ms間隔で得た最大LUFSを目標値へ合わせます。初期目標は−18 LUFS-M Maxです。旧Presetもこの方式を維持します。
- `Zwicker` は時間変動・自由音場モデルでsonesを評価します。`Max` が既定で、短い効果音に使えます。`P95` は時間系列の95パーセンタイルです。いずれも原音全体と400 msの応答用末尾を対象とし、P95には原音内の無音と末尾も含めます。
- Zwickerの目標は初期値36 sones、校正はRMS −20 dBFS = 79 dB SPLです。目標と校正はPresetごとに保存します。校正値は評価上の仮定で、実際のスピーカー音圧を自動測定しません。モノは1本、ステレオは左右を個別に測って `sqrt(NL² + NR²)` で合成します。バイノーラル処理ではありません。
- Normalize中は常に原音True PeakとSource ceiling（既定−1 dBTP）でゲインを制限します。`Peak guard also when Normalize is off` はNormalize OFFでも制限を使う設定です。Pitch／Rate／FX後の出力limiterではありません。

新しい初期値は、新規Raw／Presetと欠けているZwicker目標の補完に適用します。保存済みの−16 LUFSや8 sones等は変更しません。既存Presetにも使う場合は、目標を−18 LUFS／36 sonesへ変更して `Save preset` を押してください。36 sonesは31本・13種類の効果音で選定した開始点で、全素材が−18 LUFSになる換算値ではありません。[検証結果](loudness-defaults.md)。

素材を選んでNormalizeを有効にすると、最初は無補正で試聴し、解析完了後に再生中の音量が徐々に変わります。停止／Pause中に解析が完了しても自動再生しません。Normalize付きD&Dは解析中でも受け付け、配置したアイテムを一時ミュートして待機します。解析完了後にドロップ時の設定による補正を適用してミュートを解除します。Previewのゲイン移行中でも最終的な補正値を使います。

解析はローカルのNative helperがREAPERのデコーダーを使って行います。対応形式は利用中のREAPERが読める1〜128ch音声です。Zwickerでは推定メモリー量が1ジョブ1 GiBを超える素材（ステレオでおおむね8分超）をエラーにします。長い素材にはLUFS MaxMまたは短い素材を使ってください。Zwickerの一時ディスク容量と解析時間も長さ・ch数に応じて増えます。

## キャッシュの保存先

`Edit… → App settings → Choose cache folder...` から保存先フォルダーを選びます。選択先には解析結果と `jobs/` 内の解析用一時ファイル（Zwickerの一時PCMを含む）を保存します。書き込み可能か確認してから設定を保存し、新しい解析ジョブから反映します。処理中のジョブは元の場所で完了します。

`Use default cache folder` で従来の `data/cache/`・`data/jobs/` に戻せます。既存のキャッシュは移動・削除しません。D&Dで配置する生成音声はプロジェクトが参照するメディアのため、この設定では移動しません。

## 更新

更新前にSoundPrepをQuitします。設定と保存したMacroはインストール先の `data/` にあるため、このフォルダーを保持してください。更新は導入時と同じ方法を使います。

ReaPack版はReaPackでパッケージを同期・更新します。Native helperを更新した場合は、作業を保存してREAPERを再起動します。互換性のあるLuaだけの更新なら、SoundPrepを起動し直すことで反映します。

ZIP版は既存の `data/` を保持して新しいファイルを展開します。Native helperの更新は、すべてのREAPERを終了してから、展開した `SoundPrep` フォルダーで実行します。

macOS:

```sh
sh tools/install_native.sh
# Resource Pathが標準と異なる場合:
sh tools/install_native.sh "/path/to/REAPER resource"
```

Windows PowerShell:

```powershell
./tools/install_native.ps1
# Portable版など、Resource Pathが標準と異なる場合:
./tools/install_native.ps1 -ResourcePath 'D:\REAPER portable'
```

Resource PathはREAPERの `Options → Show REAPER resource path in explorer/finder` で確認できます。更新ツールは起動中のREAPERがあると置換を拒否し、既存helperのバックアップを残します。REAPERを起動し直した後、Action Installerを再実行すると追加Actionsを登録できます。

v0.11.3にはNative helper 0.11.1を同梱します。**v0.11.0以前からの更新ではLuaパッケージとNative helperをともに更新し、REAPERを再起動してください。** 検索支援UIを除いたbar revision 4のhelperが必要です。互換性は機能revisionと必要APIで判定し、不足するhelperでは更新を案内します。旧FFmpeg解析キャッシュは新しい解析結果として再利用しません。

## 旧Audition Macroからの切替

### ZIP版・開発フォルダーを同じ場所で更新

旧Audition MacroをQuitし、bank・FXチェーンなどを含む `data/` 全体をバックアップしてください。既存フォルダーの名前を変える必要はありません。`data/` を保持したまま、新しいファイルと同梱の旧名互換スクリプトを同じ場所へ展開します。この場合は旧Action IDとキー割当を維持でき、設定の移行作業も不要です。現在の開発フォルダーをそのまま使う場合も同じです。

### 旧ReaPackパッケージから切替

旧Audition MacroとSoundPrepは、同じ `UserPlugins/reaper_audition_macro.dll`（macOSでは `.dylib`）を所有するため、両パッケージを共存導入できません。SoundPrepは `Scripts/SoundPrep/` 以下の別パッケージで、設定は自動移行しません。

1. 旧Audition MacroをQuitし、bank・FXチェーンなどを含む旧 `data/` 全体をバックアップします。必要なキー割当も記録してください。
2. ReaPackの `Browse packages…` で旧Audition Macroパッケージを選び、`Uninstall` をApplyします。作業を保存してREAPERを再起動し、旧パッケージの削除が完了したことを確認します。
3. このページのSoundPrep用ReaPack URLを登録し、新パッケージを導入します。新しいhelperを読み込むため、作業を保存してREAPERを再起動します。
4. SoundPrepを起動する前に、バックアップした `data/` 全体を、新しい `SoundPrep.lua` と同じ階層の `data/` へ引き継ぎます。
5. 新しく登録されたSoundPrepのActionsに、必要なキーを手動で割り当て、`SoundPrep.lua` を実行します。

旧パッケージのアンインストールでは旧Actionsの登録も解除されます。この切替では、同じフォルダーの旧名互換スクリプトによるAction ID・キー割当の維持は適用されません。

設定を引き継いでからSoundPrepを起動してください。新旧を同時に起動せず、切り替えるときは実行中の方をQuitします。

## 最初の確認

Ambisonicsは1〜10次AmbiX（ACN/SN3D、4〜121ch）を入力として扱い、W/Yのみで簡易ステレオ試聴します。高次成分の空間デコードは行いません。

短い音声ファイルでPlay／StopとMacro切替を確認します。Normalizeを使う場合は、解析中にD&Dしても一時ミュートで配置され、完了後に補正が適用されることを確認します。3ch以上ではDownmixを選べます。OFFは元ch数とch間の比率を保持し、Macro FXをバイパスします。ONはステレオへまとめ、Macro FXを適用します。

Masterが2chのプロジェクトで3ch目以降も聴きたい場合は、DownmixをONにするか、プロジェクトの出力ルーティングを設定してください。SoundPrepはMaster設定を変更しません。

helperや依存APIが見つからない場合はMain Actionの `SoundPrep - Diagnostics.lua` で状態を確認できます。旧helperの更新後も案内が出る場合は、REAPERを再起動したことと、使用中のResource Pathを確認してください。

多chのSource + FXを別の環境で開く場合は、使用したMacro FXに加えて `Effects/AuditionMacro/channels_v1` が必要です。この専用JSFXは最初の多ch D&Dで配置します。

本プロジェクトの独自部分のライセンスは[MIT](../LICENSE)です。MoSQITo由来のコードにはApache-2.0など、それぞれの第三者ライセンスが適用されます。第三者コードの出典とライセンスは[第三者ライセンスと出典](../THIRD_PARTY_NOTICES.md)に記載しています。

公開済みのLua・Nativeソースは維持し、v0.11.0で追加した解析エンジンは既存helperのDLL／dylibに同梱して配布します。独自部分のMITは変更しません。ソースの公開範囲は[配布方針](source-distribution.md)を参照してください。
