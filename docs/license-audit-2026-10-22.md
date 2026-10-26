# 配布ライセンス点検 — 2026-10-22

対象はSoundPrepの公開ソース用allowlistと、ReaPack／macOS・Windows ZIPのruntime allowlistです。開発リポジトリ全体をMITとして再配布できるという判定ではありません。以下はv0.11.1に向けた修正についての記録で、既に公開済みのv0.11.0アセットを差し替えたという意味ではありません。

## 原本と通知の照合

| 対象 | 照合結果と修正 |
| --- | --- |
| プロジェクト独自部分 | ルートのMIT本文と著作権表示を維持。第三者コードの権利までこのMITで置き換えません。 |
| libebur128 v1.2.6 | 同梱MIT本文が上流タグの`COPYING`とバイト単位で一致。Jan Kokemüllerの著作権表示を保持。派生C++の両ファイルにもMIT・出典・改変表示を明記しました。 |
| nlohmann/json v3.12.0 | `json.hpp`と`LICENSE.MIT`が上流タグの原本とバイト単位で一致。Niels Lohmannの通知は既存配布にありました。 |
| 同ヘッダー内のUTF-8 decoder / Grisu2 / Hedley | ソースにはBjörn Hoehrmann、Florian Loitsch、Evan Nemersonの表示がある一方、従来のruntime ZIPにはヘッダーがなく、追加作者の通知もありませんでした。`json.THIRD_PARTY_NOTICES.md`に著作権表示とMIT本文を追加し、全配布形態へ含めました。Hedleyの単体配布は上流文書でCC0、組込コピーのSPDXはMITという違いも記録しています。 |
| 同ヘッダー内のAbseil由来部分 | 包含セクションのSPDXはMITですが、抜粋元へのコメントはApache-2.0を明記しています。指定コミットの原本は2017年の著作権表示、組込側は2018年です。両方の帰属と原本のApache本文を追加しました。C++17ビルドではC++11 fallbackを使いませんが、公開するヘッダーには残っています。指定コミットの全Git treeに独立したNOTICEはありませんでした。 |
| MoSQITo 1.2.1 | PyPI wheelのSHA-256をPyPIメタデータと照合。同梱Apache本文がwheel内のLICENSEとバイト単位で一致し、wheelに独立したNOTICEがないことを確認。C++移植の両ファイルにApache-2.0・改変表示を明記し、上流のZwicker / FastlとISO表への帰属参照も保持しました。 |
| Cockos REAPER SDK抜粋 | `reaper_audio_abi.h`の元の許諾文・著作権・改変表示を保持し、配布通知にも全文を保持。MITへの置換はしていません。 |
| REAPER標準JSFX・外部拡張 | 既定チェインは利用者の既存JSFXを参照し、その実装を同梱しません。REAPER、SWS、JS_ReaScriptAPI、ReaImGui等の別製品を本プロジェクトのMITに含めません。 |

固定URL・取得原本のSHA-256は[third-party-provenance.json](../resources/third-party-provenance.json)に記録しています。元の通知は[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)、追加通知は[JSON内の第三者コード](../native/vendor/json.THIRD_PARTY_NOTICES.md)を参照してください。

MITは、派生物全体を同じライセンスにする義務ではなく、複製・重要部分に元の著作権表示と許諾文を含める条件を持ちます。SoundPrep独自部分はMITを維持し、MIT由来部分の通知も保持します。MoSQITo由来部分にはApache-2.0を維持します。Apacheのソース／オブジェクト配布条件に従い、本文、改変表示、帰属情報を残します。[libebur128のMIT原文](https://github.com/jiixyj/libebur128/blob/v1.2.6/COPYING)、[Apache-2.0 §4](https://www.apache.org/licenses/LICENSE-2.0)。

## 辞書の配布除外

辞書検索支援、辞書JSON、旧類語JSON、出典資料、専用Actionsと辞書依存テストを公開ソース・runtimeの両allowlistから除外しました。Lua起動時に辞書を読み込んだりユーザー辞書を作成したりせず、操作バーとEditの検索支援UIも外しています。旧ショートカットや遅れて届いた検索支援イベントは標準検索を書き換えません。Media Explorer標準の検索は引き続き使用できます。

開発環境の元辞書と出典記録は残しています。参照メーカー名だけを削って同じデータを配布する変更ではありません。今回、参照メタデータの辞書利用・再配布について権利確認が完了したとは扱っていません。

## 来歴の確認と公開時の条件

- 最適化Pythonの提供物`analyzer/fast_loudness.py`は、記録済みSHA-256と一致しました。元ファイル・README・pyprojectには変更部分の権利者表示がありませんでしたが、2026-10-22にメンテナー本人から、最適化変更部分は自作であるとの確認を得ました。これは最適化変更部分の来歴についての本人申告であり、MoSQITo由来部分のApache-2.0を変更するものではありません。
- 今回の通知修正は、上流がさらに参照する全資料の権利関係を独立に認定するものではありません。確認した固定版の配布条件と、手元の派生・配布経路を照合した範囲です。
- 検索ボタン撤去後のhelperはbar revision 4が必要です。旧helperを再利用できないよう、同じ版番号でも機能revisionが不足するバイナリをパッケージ作成時に拒否します。両OSの新しいhelperを用意し、公開済みv0.11.0と区別してv0.11.1で配布します。既存タグ・既存アセットを上書きしてはいけません。

再確認用の検査:

```sh
python3 -m unittest discover -s tests -p 'test_distribution_policy.py' -v
python3 -m unittest discover -s tests -p 'test_package_release.py' -v
python3 -m unittest discover -s tests -p 'test_public_source.py' -v
python3 -m unittest discover -s tests -p 'test_prebuilt_helpers.py' -v
lua tests/run.lua
```

ハッシュ検査は原本との一致を検知し、配布テストは追加通知の同梱・辞書の除外を検知します。これらだけで未記録の来歴や権利者の許諾まで証明することはできません。
