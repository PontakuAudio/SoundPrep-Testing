# ソースとバイナリの配布方針

SoundPrepの公開先は[PontakuAudio/SoundPrep](https://github.com/PontakuAudio/SoundPrep-Testing)です。公開ソースには既存のLua、Nativeコード、旧Python解析コードを含みます。

今回追加したC++解析エンジンの実装は非公開とし、Windowsの `reaper_audition_macro.dll` とmacOSの `reaper_audition_macro.dylib` に同梱します。解析専用の追加DLLを利用者が導入する必要はありません。非公開の対象は新しいLUFS MaxM・True Peak・Zwickerの実装と、その内部検証コード・最適化参照実装です。LuaのUI、REAPER連携、既存Nativeコードと公開APIの定義は引き続き読めます。

独自部分の[MIT License](../LICENSE)は維持します。バイナリの利用・再配布にも同じライセンスが適用され、逆解析禁止などの条件は追加しません。第三者由来の部分は引き続きそれぞれのライセンスに従い、通知をソースと実行用パッケージの両方に含めます。特にMoSQITo由来部分のApache-2.0をMITで置き換えません。[第三者ライセンスと出典](../THIRD_PARTY_NOTICES.md)を参照してください。

## 利用者向けの配布物

通常の導入にはReaPackまたはOS別のRelease ZIPを使います。これらにはLua、必要なリソース、ライセンスとビルド済みhelperを含めます。解析ソース、開発用試験、PDBなどのデバッグ情報は含めません。公開リポジトリの自動生成「Source code」アーカイブは通常のインストーラーではありません。

公開リポジトリの `prebuilt/` には、公開用に選んだ両OSのhelperと `manifest.json` を置きます。manifestはパッケージ版、helper版、ファイル名、サイズ、SHA-256を記録します。公開CIは版・機能revision・形式・ハッシュと公開Luaの試験を確認し、このバイナリからZIPとReaPack indexを作ります。SHA-256は内容の一致を確認するもので、安全性の保証や独立監査の証明ではありません。

## 公開ソースからの検証

v0.11.xの公開ソースには解析エンジンが含まれないため、公開リポジトリだけで完全なhelperを再ビルドすることはできません。Nativeのビルドスクリプトは、その場合に理由を表示して停止します。公開済みNativeコードは参照・変更できる状態で残します。完全なNativeビルドと内部DSPの試験は開発環境で実行し、公開CIによるパッケージ検証と区別します。

公開チェックアウトでは、Python 3.10以降とLua 5.4を使って次を確認できます。これらは開発用で、通常利用の依存ではありません。

```sh
python3 tools/generate_native_contract.py --check
python3 tools/prebuilt_helpers.py
lua tests/run.lua
python3 -m unittest discover -s tests -p 'test_package_release.py' -v
python3 -m unittest discover -s tests -p 'test_prebuilt_helpers.py' -v
```

## メンテナーの公開準備

1. 開発環境のmacOS／Windowsビルドと試験を通し、同じhelper版の2つのバイナリを選びます。
2. `resources/public-source-files.json` の明示リストから新しい公開用スナップショットを作ります。既存の公開ディレクトリやGit履歴はこのツールで削除・変更しません。
3. 出力の `public-source-manifest.json` と差分を確認します。未レビューのファイルは自動追加されず、解析実装・内部試験・参照実装・個人データは除外されます。
4. 公開リポジトリへ反映し、公開CIを通した後、必要に応じて手動のReaPack releaseを実行します。スナップショット作成自体はpush・タグ作成・リリース公開を行いません。

Release workflowは配布対象コミットの日時をUTCで `--release-time` に渡し、ReaPack indexの各新規versionの `time` と `release.json` に記録します。これがReaPackのLast Update表示に使われます。同じコミットからの再実行で日時を変えず、既存バージョンの日時・内容も保持します。手動で配布用パッケージを作る場合も `--release-time YYYY-MM-DDTHH:MM:SSZ` を指定してください。省略はローカル試験用で、Last Updateは空欄になります。

```sh
python3 tools/prepare_public_source.py \
  --output build/public-candidate \
  --macos-helper build/reaper_audition_macro.dylib \
  --windows-helper build/windows-release/reaper_audition_macro.dll
python3 build/public-candidate/tools/prebuilt_helpers.py
```

出力先は新規または空のディレクトリを指定します。helperは両方まとめて指定します。省略するとレビュー用のソースのみを出力しますが、その状態では公開CIとリリース作成に必要なバイナリがありません。公開用スナップショットのworkflowは `resources/public-workflows/` にある公開専用の定義へ置き換え、非公開のNativeビルドジョブは持ち込みません。
