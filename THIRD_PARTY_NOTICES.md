# Third-party notices

SoundPrepの独自部分には[MIT License](LICENSE)を適用します。以下の第三者コードにはそれぞれのライセンスが適用されます。この文書と同梱のライセンス通知は、バイナリ配布にも含めます。

v0.11.0の新しい解析実装はビルド済みhelper内で配布し、そのソースは非公開とします。既存の公開ソースとMITは維持します。以下の解析用ソースパスは開発環境での対応箇所を示し、公開チェックアウトにファイルがあることを意味しません。第三者コードのライセンス・改変表示はこの配布方針でも保持します。[配布方針](docs/source-distribution.md)を参照してください。

## nlohmann/json

macOS／WindowsのNative helperは解析要求・結果などにnlohmann/json v3.12.0を使用します。ソースの `native/vendor/json.hpp` は変更していないsingle-header版です。

- 出典: [nlohmann/json v3.12.0](https://github.com/nlohmann/json/releases/tag/v3.12.0)
- 同梱ライセンス: [native/vendor/json.LICENSE.MIT](native/vendor/json.LICENSE.MIT)
- 同ヘッダー内のUTF-8 decoder、Grisu2、Hedley、Abseil由来コードの追加通知: [native/vendor/json.THIRD_PARTY_NOTICES.md](native/vendor/json.THIRD_PARTY_NOTICES.md)。追加作者のMIT通知と[AbseilのApache-2.0本文](native/vendor/abseil.LICENSE)をソース・バイナリの両配布へ含めます。

```text
MIT License

Copyright (c) 2013-2025 Niels Lohmann

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## MoSQITo / time-varying Zwicker loudness

`native/zwicker.cpp`、`native/zwicker.h` の時間変動Zwickerカーネルは、MoSQITo 1.2.1由来の最適化Python実装をC++へ移植した改変版です。元のMoSQIToをそのまま組み込んだものではありません。

- 提供元: MoSQITo Developers
- 出典: [MoSQITo](https://github.com/Eomys/MoSQITo)、[固定した参照パッケージ1.2.1](https://pypi.org/project/mosqito/1.2.1/)
- ライセンス: Apache License 2.0。参照に使用した1.2.1配布パッケージの `LICENSE` を変更せず、[native/vendor/mosqito.LICENSE.md](native/vendor/mosqito.LICENSE.md) に収録しています。
- 上流の帰属情報: `_main_loudness.py` はE. Zwicker / H. FastlのBASICプログラム（J.A.S.J. (E), 12(1), 1991）を基にすると記載し、ISO 532-1:2017の対応処理を挙げています。`_third_octave_levels.py` の係数は同規格Table A.1 / A.2への参照を保持します。MoSQITo 1.2.1のwheelには独立したNOTICEファイルはありません。
- 対応する処理: 1/3 octave filters、main loudness、nonlinear decay、critical-band slopes、temporal weighting。
- Audition Macroでの変更: 最適化済みPythonカーネルのC++ double精度への移植、帯域powerの再利用、ゲイン候補の反復評価、固定長の作業領域、キャンセル対応、時間系列のMax／P95集計。呼出し側で校正、400 msの応答用末尾、ch合成、メモリー上限を加えています。

元の最適化実装は提供されたZwickerプロジェクトの `analyzer/fast_loudness.py`（SHA-256 `d8d524fb825f1eaa495dfb91cb8100427fd0467d9e983586b7cda4c4c8ddeebb`）です。最適化変更部分はメンテナーが作成したものです。参照ライブラリーやPython実行環境は通常利用の配布物には含めません。移植した派生部分にはApache-2.0が適用され、本プロジェクト独自部分のMIT表記で置き換えません。

## libebur128

`native/lufs_meter.cpp`、`native/lufs_meter.h` のK-weightingとTrue Peak補間は、libebur128 v1.2.6を参照・改変したC++実装です。

- 出典: [libebur128 v1.2.6](https://github.com/jiixyj/libebur128/tree/v1.2.6)
- Copyright (c) 2011 Jan Kokemüller
- ライセンス: MIT。上流のv1.2.6 `COPYING` を変更せず、[native/vendor/ebur128.LICENSE.MIT](native/vendor/ebur128.LICENSE.MIT) に収録しています。
- Audition Macroでの変更: 400 ms／100 msのMax Momentary専用ストリーミング処理、dual-monoと独立ch方針、C++の状態管理、異常値検査、source-rate別のTrue Peak補間。libebur128のライブラリー全体・公開APIを同梱するものではありません。True Peak推定は旧FFmpeg解析の数値と完全一致することを保証しません。

## Cockos REAPER Plug-in API

`native/reaper_audio_abi.h` はCockosの `reaper_plugin.h` から音声ABI部分を抜粋した改変版です。macOS / Windows x64用の宣言を含み、元のSDK全体ではありません。ソース内に改変表示、出典、次の通知を保持しています。

出典: [Cockos REAPER SDK — reaper_plugin.h](https://github.com/justinfrankel/reaper-sdk/blob/main/sdk/reaper_plugin.h)

```text
REAPER Plug-in API

Copyright (C) 2006-2015, Cockos Incorporated

   This software is provided 'as-is', without any express or implied
   warranty.  In no event will the authors be held liable for any damages
   arising from the use of this software.

   Permission is granted to anyone to use this software for any purpose,
   including commercial applications, and to alter it and redistribute it
   freely, subject to the following restrictions:

   1. The origin of this software must not be misrepresented; you must not
      claim that you wrote the original software. If you use this software
      in a product, an acknowledgment in the product documentation would be
      appreciated but is not required.
   2. Altered source versions must be plainly marked as such, and must not be
      misrepresented as being the original software.
   3. This notice may not be removed or altered from any source distribution.

Notes: the C++ interfaces used require MSVC on win32, or at least the MSVC-compatible C++ ABI. Sorry, mingw users :(
```

## REAPER付属JSFXと実行時の依存

既定のFX chainとモノ／ステレオ用の出力ゲインは、利用者のREAPER環境にある `filters/resonantlowpass`、`loser/TransientController`、`loser/Saturation`、`utility/volume_pan` を参照します。これらのJSFXの実装コードはAudition Macroの配布物に含めません。それぞれの提供元のライセンスが適用されます。

`resources/audition_macro_channels_v1.jsfx` はAudition Macroのチャンネル変換・出力ゲイン用コードです。本プロジェクトのライセンス対象に含まれます。

REAPER、SWS、JS_ReaScriptAPI、ReaPackは利用者が別途導入するソフトウェアです。v0.11.0の通常利用にPython、FFmpeg / ffprobe、MoSQIToのインストールは不要です。これらは任意の開発用比較試験で使用する場合があります。Audition MacroのMIT Licenseは、これらのソフトウェアのライセンスを置き換えません。
