# Normalize初期値の検証（2026-10-22）

新規Raw／Macroの初期目標を **−18 LUFS-M Max／36 sones** にする。Zwickerの既定SummaryはMax、校正は従来のRMS −20 dBFS = 79 dB SPLを維持する。Source ceilingは−1 dBTPで、Normalize中は目標ラウドネスより優先する。既存Presetに保存されている目標値・校正値は変更しない。欠けているZwicker目標には36 sonesを補完する。

36 sonesは今回の効果音群から選んだ開始点であり、−18 LUFSへの固定換算値ではない。数値解析と実REAPERの一致を確認した検証で、試聴パネルによる聴感評価や実スピーカー音圧の校正ではない。

## 素材と比較条件

ローカルの制作済み効果音31本を使用。全て48 kHz・2ch、長さは約0.21〜23.17秒。元素材を変更せず、全尺と400 msの応答用末尾を測定する。テスト信号は初期値の選定に含めない。

| 種類 | 本数 |
|---|---:|
| ドア閉め | 1 |
| 鍵の取り出し | 1 |
| 階段の足音 | 1 |
| ふすま開閉 | 2 |
| ディーゼル列車 | 1 |
| UIクリック | 4 |
| UIコミカル | 2 |
| UI決定 | 6 |
| UIロックオン | 3 |
| UI疑問 | 2 |
| SF起動・ウィンドウ | 4 |
| SFデータ処理 | 3 |
| 洞窟の風 | 1 |

開発用FFmpegでPCMを読み、製品と同じC++のLUFS／True Peak／Zwickerカーネルへ入力した。全素材が48 kHzなのでリサンプルは不要。ステレオZwickerは製品と同じ左右の `sqrt(NL² + NR²)` 合成を使う。

比較基準のゲインは `min(−18 − source LUFS-M Max, +18, −1 − source dBTP)`。31本中4本はピーク上限のため−18 LUFSまで上がらない。Zwickerも同じ最大ブーストとピーク上限を適用し、8／28／32／36／40 sonesへ合わせるゲインを再評価して求めた。

バリエーション数の偏りを抑えるため、ゲイン差の絶対値を種類内で平均し、その後13種類を等しい重みで平均する。Max／P95の双方を同じ重みで扱い、共通の初期値を選ぶ。

## 結果

| 目標sones | Maxの平均絶対ゲイン差 | P95の平均絶対ゲイン差 | 両方式の平均 | Maxの出力中央値 | P95の出力中央値 |
|---:|---:|---:|---:|---:|---:|
| 8（旧） | 22.96 dB | 18.89 dB | 20.92 dB | −41.25 LUFS-M | −38.26 LUFS-M |
| 28 | 5.44 dB | 2.98 dB | 4.21 dB | −22.76 LUFS-M | −19.51 LUFS-M |
| 32 | 3.88 dB | 2.19 dB | 3.03 dB | −20.77 LUFS-M | −17.95 LUFS-M |
| **36** | **2.92 dB** | **2.31 dB** | **2.61 dB** | **−18.95 LUFS-M** | **−17.49 LUFS-M** |
| 40 | 2.75 dB | 2.66 dB | 2.70 dB | −17.45 LUFS-M | −16.17 LUFS-M |

36が比較した候補中で最小。1種類ずつ除いて再集計すると13通り中10通りで36、3通りで40になった。近接した候補では増幅が小さい36を採用する。Maxだけなら40、P95だけなら32の誤差が小さく、共通値36は両方式の折衷でもある。

36 sonesでの全素材の範囲はMaxが約−25.89〜−8.02 LUFS-M Max、P95が約−21.55〜−8.02 LUFS-M Max。周波数・時間特性によって両方式の評価は大きく異なるため、全素材を−18±一定幅に揃える保証ではない。短い効果音には既定Maxを使用し、P95は素材内の無音・末尾の影響も確認する。全候補で原音ピーク上限を超えないことを検査した。

## 実装と再現

- `lib/am/model.lua` に初期値を集約し、Raw／新規Macro／不足フィールドの補完と、`analysis_policy.lua` の解析descriptorで同じ値を使う。
- Lua回帰56群PASS。旧−16 LUFS／8 sonesと任意の保存値を保持し、新規値だけが変わることを確認。
- REAPER 7.82 / macOS arm64の専用ホストで29ケースPASS。実素材6本（ドア・足音・列車・クリック・SF起動・風）×Max／P95の12ケースを含み、解析・D&D capture・再生中の反映・キャッシュ再生を確認。通常環境のプロジェクトには触れず、物理出力は消音した。
- 詳細な数値・素材識別用SHA-256・C++ソースSHA-256・実ホストとの差は[測定結果JSON](loudness-defaults-2026-10-22.json)に保存。原音・ファイル名・個人フォルダのパスは含めない。

開発ツリーでの再測定にはC++コンパイラーとFFmpegが必要（通常利用には不要）。解析エンジンのソースを含まない公開ツリーではこの開発用プローブをビルドできない。

```sh
python3 tools/calibrate_loudness_defaults.py \
  --manifest /absolute/path/to/local-effects.json \
  --output build/loudness-calibration \
  --targets 8 28 32 36 40
```

Manifestは `[{"path":"/absolute/effect.wav","id":"effect-01","family":"door"}]` の配列。mono／stereoに対応し、familyを明示する。原音を変更せず、PCM一時ファイルは終了時に削除する。今回の初期値選定はステレオ31本の範囲であり、他ライブラリ・mono／多ch・他の校正条件にも最適と主張しない。

実ホストとの比較には `tools/run_macos_quality.py --suite native_analysis --corpus-manifest /absolute/path/to/expectations.json --directory /tmp/fresh-loudness-host --timeout 360` を使う。素材と期待値はローカルに用意する。
