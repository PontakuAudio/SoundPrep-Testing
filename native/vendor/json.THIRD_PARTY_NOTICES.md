# Code included in nlohmann/json v3.12.0

These notices accompany the unmodified `json.hpp` in source distributions and
the compiled helper in binary distributions. They supplement `json.LICENSE.MIT`.
References are pinned to v3.12.0, not the current upstream development version.

## Additional MIT notices

The v3.12.0 single header retains these authors' notices for its UTF-8 decoder,
Grisu2 conversion and embedded Hedley macros:

```text
Copyright (c) 2008-2009 Björn Hoehrmann <bjoern@hoehrmann.de>
Copyright (c) 2009 Florian Loitsch
Copyright (c) 2016-2021 Evan Nemerson <evan@nemerson.com>

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

Sources: [v3.12.0 MIT license](https://github.com/nlohmann/json/blob/v3.12.0/LICENSE.MIT),
[v3.12.0 single header](https://github.com/nlohmann/json/blob/v3.12.0/single_include/nlohmann/json.hpp).
The upstream documentation describes standalone Hedley as CC0-1.0; the embedded
copy carries Evan Nemerson's copyright and an MIT SPDX identifier. Both the
embedded attribution and its MIT permission notice are retained here.

## Abseil integer_sequence adaptation

The header also contains an adapted C++11 fallback from Abseil. Its source comment
explicitly identifies Apache-2.0, although the enclosing nlohmann header section
has an MIT SPDX identifier. We preserve the original Apache terms as well.
SoundPrep builds in C++17 mode; this fallback is still part of the distributed
source header.

```text
Copyright 2017 The Abseil Authors.
SPDX-FileCopyrightText: 2018 The Abseil Authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

The 2017 notice is from the pinned Abseil source; the 2018 notice is retained in
the nlohmann/json adaptation. The complete, unchanged upstream license is in
[abseil.LICENSE](abseil.LICENSE).
Source: [Abseil utility.h at 10cb35e459f5ecca5b2ff107635da0bfa41011b4](https://github.com/abseil/abseil-cpp/blob/10cb35e459f5ecca5b2ff107635da0bfa41011b4/absl/utility/utility.h).
The adaptation is by nlohmann/json; SoundPrep has not modified `json.hpp`.
