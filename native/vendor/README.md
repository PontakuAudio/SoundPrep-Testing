# Third-party dependency provenance

The runtime package includes these license files. No dependencies are downloaded at runtime.

| Component | Pinned reference | License | Use |
|---|---|---|---|
| nlohmann/json | [v3.12.0](https://github.com/nlohmann/json/releases/tag/v3.12.0) | [MIT](json.LICENSE.MIT) | `json.hpp` is the unmodified single header. Used by both macOS and Windows native analysis, and the Windows UI/transport adapters. |
| MoSQITo | [1.2.1](https://pypi.org/project/mosqito/1.2.1/) | [Apache-2.0](mosqito.LICENSE.md) | Time-varying Zwicker algorithms, via the supplied optimized Python kernels, ported and modified in `native/zwicker.cpp` and `.h`. No Python package is bundled for runtime. |
| libebur128 | [v1.2.6](https://github.com/jiixyj/libebur128/tree/v1.2.6) | [MIT](ebur128.LICENSE.MIT) | K-weighting and true-peak interpolation adapted in `native/lufs_meter.cpp` and `.h`; the complete upstream library is not bundled. |

`mosqito.LICENSE.md` is the unchanged `LICENSE` from the MoSQITo 1.2.1 Python distribution used for reference validation. Its package metadata identifies MoSQITo Developers and the [Eomys/MoSQITo repository](https://github.com/Eomys/MoSQITo). `ebur128.LICENSE.MIT` is the unchanged [v1.2.6 COPYING](https://raw.githubusercontent.com/jiixyj/libebur128/v1.2.6/COPYING).

The additional UTF-8 decoder, Grisu2, Hedley and Abseil notices embedded in `json.hpp` also ship in [json.THIRD_PARTY_NOTICES.md](json.THIRD_PARTY_NOTICES.md), together with the unchanged [Abseil Apache-2.0 license](abseil.LICENSE). Keeping only Niels Lohmann's MIT notice is not the complete binary attribution inventory.

See [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) for derivative/change notices and other components' terms. The project MIT license does not replace these third-party licenses.
