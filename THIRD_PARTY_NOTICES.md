# Third-party notices

Cloudless Voice is licensed under the GNU General Public License v3.0 or
later, with additional permissions (see [LICENSE](LICENSE) and
[LICENSE-EXCEPTION](LICENSE-EXCEPTION)). Some parts
of this repository are derived from, or bundle, third-party work under
other licenses. This file gives the notices and attributions those
licenses require.

Sections 1 and 2 cover code derived from other projects and bundled
components. Section 3 covers models downloaded at runtime. Section 4 lists
every Swift package that is linked into the app (name, pinned version,
license, copyright, upstream), section 5 the local packages, and section 6
the data files bundled in the app. The full license texts are in the
appendices.

## 1. Code derived from other projects

### FluidAudio

- **Project:** FluidAudio, https://github.com/FluidInference/FluidAudio
- **Copyright:** Copyright (c) FluidInference (the FluidAudio authors)
- **License:** Apache License, Version 2.0 (full text in
  [Appendix A](#appendix-a-apache-license-version-20))
- **Files in this repository derived from it** (modified by Synthetic Exploration, Inc.):
  - `macos/Onit/Transcription/CustomDictionary/BpeTokenizer.swift`
  - `macos/Onit/Transcription/CustomDictionary/ContextBiasingConstants.swift`
  - `macos/Onit/Transcription/CustomDictionary/CtcDPAlgorithm.swift`
  - `macos/Onit/Transcription/Services/CanaryCoreMLEngine.swift` (decode
    algorithm and Core ML input/output names, from FluidAudio's Canary
    reference implementation)

FluidAudio's upstream LICENSE contains no NOTICE file or named copyright
line; the copyright line above names the project's authors as credited in
its `CITATION.cff`.

### NVIDIA NeMo

- **Project:** NeMo, https://github.com/NVIDIA/NeMo
- **Copyright:** Copyright (c) NVIDIA CORPORATION & AFFILIATES. All rights
  reserved.
- **License:** Apache License, Version 2.0 (full text in
  [Appendix A](#appendix-a-apache-license-version-20))
- **File in this repository derived from it** (via FluidAudio, modified by
  Synthetic Exploration, Inc.):
  - `macos/Onit/Transcription/CustomDictionary/CtcDPAlgorithm.swift`
    (CTC word-spotting dynamic programming, from NeMo's
    `nemo/collections/asr/parts/context_biasing/` word spotter)

### mlx-audio (Granite Speech port)

- **Project:** mlx-audio, https://github.com/Blaizzy/mlx-audio
- **Copyright:** Copyright (c) 2024 Prince Canuma
- **License:** MIT (full text in [Appendix B](#appendix-b-mit-license))
- **Where:** `libs/speech-swift-vendored/Sources/GraniteSpeech/` (in the
  `speech-swift-vendored` submodule) is a Swift port of mlx-audio's Granite
  Speech model code.
- The IBM Granite Speech model it runs (`ibm-granite/granite-speech-4.1-2b`)
  is licensed by IBM under the Apache License, Version 2.0.

## 2. Bundled and linked components

### Moonshine

- **Project:** Moonshine, https://github.com/moonshine-ai/moonshine, used
  through the `moonshine-swift` package
  (https://github.com/moonshine-ai/moonshine-swift) and its prebuilt
  `Moonshine.xcframework`
- **Copyright:** Copyright (c) 2025 Useful Sensors, Inc. (dba Moonshine AI)
- **License:** MIT (full text in [Appendix B](#appendix-b-mit-license)).
  The `moonshine-swift` wrapper repository has no license file of its own;
  it is treated as MIT through the parent `moonshine-ai/moonshine`
  repository, whose code and English models (including the Moonshine Base
  English model the app downloads) are MIT.
- The prebuilt framework also contains third-party code from Moonshine's
  `core/third-party` directory (for example ONNX Runtime, Eigen, KissFFT,
  kaldi-native-fbank, nlohmann/json and utf8proc), each under its own
  license.

### BoringSSL (OpenSSL derivative)

- **Project:** BoringSSL, https://boringssl.googlesource.com/boringssl, a
  fork of OpenSSL
- **How it ships:** inside the official app as `openssl_grpc.framework`,
  part of gRPC's prebuilt binaries (`google/grpc-binary`), which Firebase
  Firestore depends on. It is downloaded by SwiftPM, not stored in this
  repository.
- **License:** the OpenSSL License and the original SSLeay license (dual,
  both apply), the ISC license for Google's new files, and MIT for
  `third_party/fiat`. Full text in
  [Appendix D](#appendix-d-boringssl-license).
- **GPL compatibility:** the OpenSSL and SSLeay licenses are not
  compatible with the GPL on their own. Cloudless Voice's
  [LICENSE-EXCEPTION](LICENSE-EXCEPTION) grants an additional permission
  to combine the app with OpenSSL and OpenSSL-derived libraries such as
  BoringSSL.

As the OpenSSL and SSLeay licenses require:

- This product includes software developed by the OpenSSL Project for use
  in the OpenSSL Toolkit (http://www.openssl.org/).
- This product includes cryptographic software written by Eric Young
  (eay@cryptsoft.com).
- This product includes software written by Tim Hudson
  (tjh@cryptsoft.com).

### Fonts

The app bundles three font families under the SIL Open Font License,
Version 1.1 (full text in
[Appendix C](#appendix-c-sil-open-font-license-version-11)):

- **Inter**, `macos/Onit/General/Resources/Inter/`.
  Copyright 2020 The Inter Project Authors (https://github.com/rsms/inter)
- **Libre Baskerville**, `macos/Onit/General/Resources/LibreBaskerville/`.
  Copyright 2012 The Libre Baskerville Project Authors
  (https://github.com/impallari/Libre-Baskerville) with Reserved Font Name
  Libre Baskerville.
- **Sometype Mono**, `macos/Onit/General/Resources/Sometype/`.
  Copyright 2018 The Sometype Mono Project Authors
  (https://github.com/googlefonts/sometype-mono)

## 3. Models downloaded at runtime

The app does not include speech or language-model weights. It downloads
them when you first use them. These models carry attribution requirements:

### NVIDIA Parakeet TDT 0.6B v3 (default speech model)

"Parakeet TDT 0.6B v3" by NVIDIA,
https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3, licensed under
Creative Commons Attribution 4.0 International (CC BY 4.0),
https://creativecommons.org/licenses/by/4.0/. The app downloads the Core ML
conversion by FluidInference,
https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
(converted and quantized from the original; also CC BY 4.0).

### NVIDIA Canary 1B v2

"Canary 1B v2" by NVIDIA, https://huggingface.co/nvidia/canary-1b-v2,
licensed under CC BY 4.0, https://creativecommons.org/licenses/by/4.0/. The
app downloads the Core ML conversion by FluidInference,
https://huggingface.co/FluidInference/canary-1b-v2-coreml (converted and
quantized from the original; also CC BY 4.0).

### Llama 3.2

The default scoring model (`mlx-community/Llama-3.2-1B-Instruct-8bit`) and
Synth's cleanup model (`getonit/transcription-cleanup-llama3.2-1b`) are
based on Meta's Llama 3.2 and are subject to the Llama 3.2 Community
License Agreement and Acceptable Use Policy.

Llama 3.2 is licensed under the Llama 3.2 Community License, Copyright ©
Meta Platforms, Inc. All Rights Reserved.

## 4. Swift packages linked into the app

These are the Swift packages that `macos/Onit.xcodeproj` pulls in through
SwiftPM and that end up in the app. The versions are the ones pinned in
`macos/Onit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The license of each package was read from the license files of its checkout
at exactly the pinned revision (checked against `Package.resolved`), not
from memory. SPDX identifiers were assigned by reading the text of those
files. The complete license texts are in the appendices.

How "linked" was established: the direct products come from
`macos/Onit.xcodeproj/project.pbxproj`; the transitive ones from the link file
list and the embedded frameworks of a Debug build of the pinned tree. A
Release build links the same packages.

### 4.1 Direct dependencies

| Package | Pinned version | Products linked | License (SPDX, read from the file) | Copyright | Upstream |
| --- | --- | --- | --- | --- | --- |
| Defaults | 9.0.6 | Defaults, DefaultsMacros | MIT ([Appendix B](#appendix-b-mit-license)) | Copyright (c) Sindre Sorhus | <https://github.com/sindresorhus/Defaults> |
| EventSource | 0.1.5 | EventSource | MIT ([Appendix B](#appendix-b-mit-license)) | Copyright 2023 Firdavs Khaydarov | <https://github.com/Recouse/EventSource> |
| Firebase iOS SDK | 11.15.0 | FirebaseAuth, FirebaseCrashlytics, FirebaseFirestore, FirebaseStorage (and the Firebase modules they pull in: Core, Installations, Sessions, SharedSwift) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)), with MIT parts in Crashlytics and Firestore ([Appendix B](#appendix-b-mit-license)) and a Runtime Library Exception on FirestoreEncoder | Copyright Google LLC / Google Inc. (source file headers); LICENSE keeps the unfilled Apache boilerplate | <https://github.com/firebase/firebase-ios-sdk> |
| FluidAudio | 0.13.6 | FluidAudio (and its FastClusterWrapper) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | See section 1; the repository LICENSE has no filled copyright line. Bundled: VBx, Copyright 2021-2024 BUT Speech@FIT (Apache-2.0); fastcluster (BSD-2-Clause, [Appendix E](#appendix-e-bsd-2-clause-licenses)) | <https://github.com/FluidInference/FluidAudio> |
| GoogleSignIn-iOS | branch main @ 913b4005 (tag 9.1.0) | GoogleSignIn, GoogleSignInSwift | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2021 Google LLC (source file headers) | <https://github.com/google/GoogleSignIn-iOS> |
| GRDB.swift | 7.5.0 | GRDB | MIT ([Appendix B](#appendix-b-mit-license)) | Copyright (C) 2015-2025 Gwendal Roué | <https://github.com/groue/GRDB.swift> |
| KeyboardShortcuts | 2.4.0 | KeyboardShortcuts | MIT ([Appendix B](#appendix-b-mit-license)) | Copyright (c) Sindre Sorhus | <https://github.com/sindresorhus/KeyboardShortcuts> |
| mlx-swift-lm | 2.30.3 | MLXLLM, MLXLMCommon | MIT ([Appendix B](#appendix-b-mit-license)) | Copyright (c) 2024 ml-explore | <https://github.com/ml-explore/mlx-swift-lm> |
| moonshine-swift | 0.0.60 | MoonshineVoice | MIT (see section 2, Moonshine) | Copyright (c) 2025 Useful Sensors, Inc. (dba Moonshine AI) | <https://github.com/moonshine-ai/moonshine-swift> |
| posthog-ios | 3.38.0 | PostHog (with a vendored libwebp) | MIT ([Appendix B](#appendix-b-mit-license)); vendored libwebp BSD-3-Clause ([Appendix F](#appendix-f-bsd-3-clause-licenses)) | Copyright (c) [2023] [PostHog]; libwebp Copyright (c) 2010, Google Inc. | <https://github.com/PostHog/posthog-ios> |
| Sparkle | 2.8.1 | Sparkle | MIT ([Appendix B](#appendix-b-mit-license)) AND BSD-2-Clause ([Appendix E](#appendix-e-bsd-2-clause-licenses)) AND Zlib ([Appendix G](#appendix-g-zlib-licenses)) | Copyright (c) 2006-2013 Andy Matuschak and the other holders listed in Appendix B; third-party parts: bsdiff (Colin Percival), sais-lite (Yuta Mori), ed25519 (Orson Peters), SUSignatureVerifier (Mark Hamlin) | <https://github.com/sparkle-project/Sparkle> |
| swift-markdown | 0.7.3 | Markdown | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright (c) 2021 Apple Inc. and the Swift project authors | <https://github.com/apple/swift-markdown> |
| SwiftyBeaver | 2.1.1 | SwiftyBeaver | MIT ([Appendix B](#appendix-b-mit-license)) | Copyright (c) 2015 Sebastian Kreutzberger | <https://github.com/SwiftyBeaver/SwiftyBeaver> |
| WhisperKit | 0.18.0 | WhisperKit, ArgmaxCore | MIT ([Appendix B](#appendix-b-mit-license)) | Copyright (c) 2024 argmax, inc. | <https://github.com/argmaxinc/WhisperKit> |

Notes:

- GoogleSignIn-iOS is pinned in `project.pbxproj` to the `main` branch, not
  to a version. `Package.resolved` fixes it at revision `913b4005`, which is
  the tag 9.1.0.
- The Sparkle, nanopb, leveldb, fmt, metal-cpp, libwebp, fastcluster and
  other components named in the Copyright column are code that these
  packages bundle; their texts are in the appendices.

### 4.2 Transitive dependencies

| Package | Pinned version | Products linked | License (SPDX, read from the file) | Copyright | Upstream |
| --- | --- | --- | --- | --- | --- |
| abseil-cpp-binary | 1.2024072200.0 | absl.framework (via Firestore) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2023-2024 Google LLC (source file headers) | <https://github.com/google/abseil-cpp-binary> |
| app-check | 11.2.0 | AppCheckCore (via GoogleSignIn, Firebase) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2020-2021 Google LLC (source file headers) | <https://github.com/google/app-check> |
| AppAuth-iOS | 2.0.0 | AppAuth, AppAuthCore (via GTMAppAuth, GoogleSignIn) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2015-2016 Google Inc. (source file headers) | <https://github.com/openid/AppAuth-iOS> |
| GoogleDataTransport | 10.1.0 | GoogleDataTransport (via Crashlytics, Firebase Sessions) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2019-2020 Google (source file headers) | <https://github.com/google/GoogleDataTransport> |
| GoogleUtilities | 8.1.0 | GoogleUtilities (Environment, Logger, Network, NSData, Reachability, UserDefaults, AppDelegateSwizzler) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) AND MIT ([Appendix B](#appendix-b-mit-license)) | Copyright 2018 Google LLC (source file headers); Copyright (c) 2017 Landon J. Fuller (MIT part) | <https://github.com/google/GoogleUtilities> |
| grpc-binary | 1.69.1 | grpc.framework, grpcpp.framework, openssl_grpc.framework (via Firestore) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)); contains BoringSSL (see section 2) | Copyright 2023-2024 Google LLC (source file headers) | <https://github.com/google/grpc-binary> |
| gtm-session-fetcher | 3.5.0 | GTMSessionFetcherCore (via GoogleSignIn, Firebase) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2014-2024 Google Inc. (source file headers) | <https://github.com/google/gtm-session-fetcher> |
| GTMAppAuth | 5.0.0 | GTMAppAuth (via GoogleSignIn) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2016-2022 Google Inc. / Google LLC (source file headers) | <https://github.com/google/GTMAppAuth> |
| interop-ios-for-google-sdks | 101.0.0 | RecaptchaInterop (via Firebase Auth) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2021-2023 Google LLC (source file headers) | <https://github.com/google/interop-ios-for-google-sdks> |
| leveldb (Firebase fork) | 1.22.5 | leveldb (via Firestore) | BSD-3-Clause ([Appendix F](#appendix-f-bsd-3-clause-licenses)) | Copyright (c) 2011 The LevelDB Authors | <https://github.com/firebase/leveldb> |
| mlx-swift | 0.30.3 | MLX, MLXNN, MLXFast, MLXFFT, MLXOptimizers, MLXCommon, Cmlx (via mlx-swift-lm, WhisperKit, the vendored speech package) | MIT ([Appendix B](#appendix-b-mit-license)); Cmlx vendors MIT parts and Apache-2.0 metal-cpp | Copyright (c) 2023 ml-explore; vendored: mlx Copyright 2023 Apple Inc., mlx-c Copyright (c) 2023 ml-explore, fmt Copyright (c) 2012-present Victor Zverovich, nlohmann/json Copyright (c) 2013-2022 Niels Lohmann, metal-cpp Copyright 2024 Apple Inc. | <https://github.com/ml-explore/mlx-swift> |
| nanopb (Firebase fork) | 2.30910.0 | nanopb (via Firestore, Crashlytics) | Zlib ([Appendix G](#appendix-g-zlib-licenses)) | Copyright (c) 2011 Petteri Aimonen | <https://github.com/firebase/nanopb> |
| Promises | 2.4.0 | FBLPromises, Promises (via Firebase) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2018 Google Inc. (source file headers) | <https://github.com/google/promises> |
| swift-cmark | 0.7.1 | cmark-gfm, cmark-gfm-extensions (via swift-markdown) | BSD-2-Clause ([Appendix E](#appendix-e-bsd-2-clause-licenses)) AND MIT ([Appendix B](#appendix-b-mit-license)) | Copyright (c) 2014, John MacFarlane; derived parts listed in Appendix B | <https://github.com/swiftlang/swift-cmark> |
| swift-collections | 1.4.1 | OrderedCollections, InternalCollectionsUtilities | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright (c) 2021-2026 Apple Inc. and the Swift project authors | <https://github.com/apple/swift-collections> |
| swift-jinja | 2.3.1 | Jinja (via swift-transformers) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2022 Hugging Face SAS. | <https://github.com/huggingface/swift-jinja> |
| swift-numerics | 1.1.1 | Numerics, ComplexModule, RealModule | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright (c) 2019-2025 Apple Inc. and the Swift Numerics project authors | <https://github.com/apple/swift-numerics> |
| swift-transformers | 1.1.6 | Hub, Tokenizers, Models, Generation (via WhisperKit, mlx-swift-lm, vendored speech package) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)) | Copyright 2022 Hugging Face SAS. | <https://github.com/huggingface/swift-transformers> |

### 4.3 In Package.resolved but not linked into the app

These packages appear in `Package.resolved` but are not part of the app
binary, so no notice is required for them. They are listed so the
difference with `Package.resolved` is explained.

| Package | Pinned version | License (read from the file) | Why it is not linked |
| --- | --- | --- | --- |
| swift-argument-parser | 1.7.1 | Apache-2.0 | a dependency of WhisperKit and swift-markdown; no `ArgumentParser` object in the link list of a Debug build |
| swift-protobuf | 1.33.3 | Apache-2.0 | no `SwiftProtobuf` object in the link list of a Debug build |
| swift-syntax | 602.0.0 | Apache-2.0 | build-time host of the Defaults macros; not part of the app binary |
| GoogleAppMeasurement | 11.15.0 | Apache-2.0 | listed in Package.resolved; `project.pbxproj` has no reference to it and no object is linked |
| google-ads-on-device-conversion-ios-sdk | 2.3.0 | Apache-2.0 | listed in Package.resolved; `project.pbxproj` has no reference to it and no object is linked |

## 5. Local packages

| Package | License | Copyright | Notes |
| --- | --- | --- | --- |
| `libs/speech-swift-vendored` (targets Qwen3ASR, AudioCommon, MLXCommon, SpeechVAD, GraniteSpeech) | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)), see its `LICENSE` and `NOTICE.md` | Copyright 2025 Ivan Digital (original work, per its `NOTICE.md`) | Vendored subset of soniqo/speech-swift 0.0.15, plus the Granite Speech port (section 1). |
| `libs/transcription-cleanup-swift` (TranscriptionCleanup) | Proprietary, see [its license](libs/transcription-cleanup-swift/LICENSE) | Synthetic Exploration, Inc. | Closed-source binary; not an open-source component. |

## 6. Data and files bundled in the app

Data files shipped inside the app bundle (they are read with
`Bundle.main`). The "Provenance" column is what the repository itself says;
nothing here comes from outside the repository.

| File (under `macos/Onit/`) | What it is | Provenance as stated in the repository | License |
| --- | --- | --- | --- |
| `Transcription/Training/cmudict_phones.txt` (124,996 lines) | English word to ARPAbet phones, stress removed. Used by `PhoneticLexicon` for homophone matching | `PhoneticLexicon.swift` calls it CMUdict. Checked against the upstream CMU Pronouncing Dictionary (https://github.com/cmusphinx/cmudict): 115,517 of its 115,533 distinct words are in the upstream file and 113,866 of those carry only pronunciations that the upstream file also has (after stress removal and lowercasing). The upstream version it was taken from is not recorded in the repository | CMU license, 2-clause BSD style with a funding acknowledgement ([Appendix I](#appendix-i-cmu-pronouncing-dictionary-license)). Copyright (C) 1993-2015 Carnegie Mellon University per the current upstream `LICENSE` |
| `Transcription/Training/eng_news_2024_100K-words.txt` (161,296 lines) | Word frequency list: rank, word, count (tab separated) | Data of the Leipzig Corpora Collection corpus `eng_news_2024_100K` (English news crawl, 100,000 sentences, 2,218,130 tokens, built 2025-01-18), file `eng_news_2024_100K-words.txt`, from https://downloads.wortschatz-leipzig.de/corpora/eng_news_2024_100K.tar.gz, except that one line (`34716 Cerity 3`) was removed. Copyright Leipzig University, Saxon Academy of Sciences and Humanities in Leipzig and InfAI (Wortschatz Leipzig). Citation: D. Goldhahn, T. Eckart and U. Quasthoff (2012), Building Large Monolingual Dictionaries at the Leipzig Corpora Collection: From 100 to 200 Languages, Proceedings of LREC 2012, https://aclanthology.org/L12-1154/ | Creative Commons Attribution 3.0 (CC BY 3.0) (https://creativecommons.org/licenses/by/3.0/). The Terms of Usage of https://wortschatz.uni-leipzig.de/en/usage say: "The text corpora offered for download are made available under the Creative Commons licence CC BY." Wortschatz Leipzig states that its word lists "can be used freely under the Creative Commons Licence CC-BY 3.0"; the corpus page itself gives no version number, so version 3.0 is applied. |
| `Transcription/Training/bigrams_common.txt` (57,766 lines) | Common English bigrams (lowercase `word word`, sorted), used so the format matcher does not alter everyday phrases | Generated with `scripts/data/build_common_bigrams.py` from the sentences of the Leipzig Corpora Collection corpus `eng_news_2024_1M` (English news crawl, 1,000,000 sentences, built 2025-01-18, https://downloads.wortschatz-leipzig.de/corpora/eng_news_2024_1M.tar.gz): every pair of adjacent alphabetic words occurring at least 30 times. This is a modified, derived work; the source data is copyright Leipzig University, Saxon Academy of Sciences and Humanities in Leipzig and InfAI (Wortschatz Leipzig), citation as for the frequency list above. It replaces an earlier list taken from Peter Norvig's web bigram data (derived from the Google Web Trillion Word Corpus, distributed by the Linguistic Data Consortium), which has no data license and was removed | Creative Commons Attribution 3.0 (CC BY 3.0) (https://creativecommons.org/licenses/by/3.0/), same terms as the frequency list |
| `Transcription/Training/asr_confusable_terms.txt` (24,183 lines) | Words Qwen3-ASR fails to transcribe in isolation, subtracted from the mining vocabulary | Built in-house in 2026-08 by synthesizing words of the Leipzig list with three Kokoro-82M voices and ElevenLabs, then transcribing them back (`Transcription/Training/asr_confusable_terms.README.md`). The word list derives from the Leipzig list | CC BY 3.0, as a derived work of the Leipzig list above |
| `Transcription/EmojiSemantic/MiniLMEmoji.mlpackage` | CoreML int8 conversion of a MiniLM-L6-v2 sentence embedding model (mean-pool and L2 norm baked in), used to match spoken descriptors to emoji | `MiniLMEmojiEmbedder.swift` and `SemanticEmojiMatcher.swift` say "all-MiniLM-L6-v2". The model metadata says "MiniLM-L6-v2 sentence embedding" and was exported with coremltools from torch 2.5.1. The conversion script is not in the repository. The upstream model sentence-transformers/all-MiniLM-L6-v2 is published on the Hugging Face Hub under Apache-2.0, fine-tuned from nreimers/MiniLM-L6-H384-uncased (MIT on its Hub card) | Apache-2.0 for the upstream model ([Appendix A](#appendix-a-apache-license-version-20)) |
| `Transcription/EmojiSemantic/vocab.txt` | Word-piece vocabulary (30,522 entries) used by `BertWordPieceTokenizer` with that model | Byte-identical (SHA-256 07eced37...38a3) to the `vocab.txt` of sentence-transformers/all-MiniLM-L6-v2 and of google-bert/bert-base-uncased on the Hugging Face Hub | Apache-2.0 ([Appendix A](#appendix-a-apache-license-version-20)), the license of both upstream repositories on the Hub |
| `Transcription/EmojiSemantic/emoji_anchors.json`, `emoji_anchors.f32.bin` | 2,056 emoji glyphs with their names, and the precomputed embedding of each (computed with the model above) | All 2,056 glyphs are in the Unicode `emoji-test.txt`, and 1,944 names equal its names exactly; the others differ only in wording (typographic quotes, a `flag:` prefix, and similar). The script that built the table and the Unicode version are not in the repository | Names: Unicode License v3 ([Appendix J](#appendix-j-unicode-license-v3)), Copyright Unicode, Inc.. The embeddings are computed data derived from the model above |
| `General/Resources/` fonts (Inter, Libre Baskerville, Sometype Mono) | UI fonts | See section 2, Fonts | See section 2 and [Appendix C](#appendix-c-sil-open-font-license-version-11) |

## Appendix A: Apache License, Version 2.0

Applies to the FluidAudio- and NeMo-derived files listed in section 1 and
to every package marked Apache-2.0 in sections 4 and 5. The license text is
the same for all of them. The copyright notices of the individual holders
are given in the Copyright column of section 4 (the Apache files of these
packages keep the unfilled boilerplate and carry the holder in their
source file headers) and the NOTICE files in [Appendix H](#appendix-h-upstream-notice-files).

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

## Appendix B: MIT License

One block per copyright holder, with the license text exactly as found in
the component's own license file where there is one. The standard MIT text
is the same in every block; the copyright notice and the holder differ.

### Prince Canuma

Used by: mlx-audio (Granite Speech port, section 1).

```text
Copyright (c) 2024 Prince Canuma

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

### Useful Sensors, Inc. (dba Moonshine AI)

Used by: Moonshine (section 2).

```text
Copyright (c) 2025 Useful Sensors, Inc. (dba Moonshine AI)

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

### Sindre Sorhus

Used by: Defaults, KeyboardShortcuts (the two license files are identical).

```text
MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Firdavs Khaydarov

Used by: EventSource.

```text
Copyright 2023 Firdavs Khaydarov

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and 
associated documentation files (the “Software”), to deal in the Software without restriction, including 
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell 
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the 
following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial 
portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT 
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN 
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, 
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Gwendal Roué

Used by: GRDB.swift.

```text
Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Sebastian Kreutzberger

Used by: SwiftyBeaver.

```text
The MIT License (MIT)

Copyright (c) 2015 Sebastian Kreutzberger

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

### argmax, inc.

Used by: WhisperKit.

```text
MIT License

Copyright (c) 2024 argmax, inc.

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

### ml-explore (2024)

Used by: mlx-swift-lm.

```text
MIT License

Copyright (c) 2024 ml-explore

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

### ml-explore (2023)

Used by: mlx-swift, and mlx-c vendored in it (the two files carry the same notice).

```text
MIT License

Copyright (c) 2023 ml-explore

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

### Apple Inc. (mlx, 2023)

Used by: mlx, vendored in mlx-swift (Cmlx).

```text
MIT License

Copyright © 2023 Apple Inc.

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

### Niels Lohmann

Used by: nlohmann/json, vendored in mlx-swift (Cmlx, 2013-2022) and in Firebase Firestore (2013-2020; the Firestore copy has the same text with "Copyright (c) 2013-2020 Niels Lohmann").

```text
MIT License 

Copyright (c) 2013-2022 Niels Lohmann

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

### Victor Zverovich and {fmt} contributors

Used by: fmt, vendored in mlx-swift (Cmlx). This license has an additional exception for object-form redistribution, kept below.

```text
Copyright (c) 2012 - present, Victor Zverovich and {fmt} contributors

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

--- Optional exception to the license ---

As an exception, if, as a result of your compiling your source code, portions
of this Software are embedded into a machine-executable object form of such
source code, you may redistribute such embedded portions in such object form
without including the above copyright and permission notices.
```

### PostHog

Used by: posthog-ios.

```text
MIT License

Copyright (c) [2023] [PostHog]

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

### Andy Matuschak and the other Sparkle holders

Used by: Sparkle.

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Yuta Mori

Used by: sais-lite, vendored in Sparkle.

```text
sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
```

### Landon J. Fuller

Used by: GoogleUtilities.

```text
Copyright (c) 2017 Landon J. Fuller <landon@landonf.org>
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Hewlett-Packard Development Company, L.P.

Used by: libunwind `dwarf.h`, in Firebase Crashlytics (Crashlytics/LICENSE).

```text
The following copyright from Hewlett-Packard Development Company, L.P.
applies to the dwarf.h file in third_party/libunwind

   libunwind - a platform-independent unwind library
   Copyright (c) 2003-2005 Hewlett-Packard Development Company, L.P.
        Contributed by David Mosberger-Tang <davidm@hpl.hp.com>

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Vicent Martí

Used by: houdini, derived in swift-cmark.

```text
houdini.h, houdini_href_e.c, houdini_html_e.c, houdini_html_u.c

derive from https://github.com/vmg/houdini (with some modifications)

Copyright (C) 2012 Vicent Martí

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

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

### GitHub, Inc.

Used by: buffer and chunk code derived in swift-cmark.

```text
buffer.h, buffer.c, chunk.h

are derived from code (C) 2012 Github, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

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

### Public Software Group e. V.

Used by: utf8proc, derived in swift-cmark.

```text
utf8.c and utf8.c

are derived from utf8proc
(<http://www.public-software-group.org/utf8proc>),
(C) 2009 Public Software Group e. V., Berlin, Germany.

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

## Appendix C: SIL Open Font License, Version 1.1

Applies to Inter, Libre Baskerville and Sometype Mono, with the copyright
notices listed in section 2.

```text
-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

## Appendix D: BoringSSL license

The LICENSE file of BoringSSL, verbatim.

```text
BoringSSL is a fork of OpenSSL. As such, large parts of it fall under OpenSSL
licensing. Files that are completely new have a Google copyright and an ISC
license. This license is reproduced at the bottom of this file.

Contributors to BoringSSL are required to follow the CLA rules for Chromium:
https://cla.developers.google.com/clas

Files in third_party/ have their own licenses, as described therein. The MIT
license, for third_party/fiat, which, unlike other third_party directories, is
compiled into non-test libraries, is included below.

The OpenSSL toolkit stays under a dual license, i.e. both the conditions of the
OpenSSL License and the original SSLeay license apply to the toolkit. See below
for the actual license texts. Actually both licenses are BSD-style Open Source
licenses. In case of any license issues related to OpenSSL please contact
openssl-core@openssl.org.

The following are Google-internal bug numbers where explicit permission from
some authors is recorded for use of their work. (This is purely for our own
record keeping.)
  27287199
  27287880
  27287883
  263291445

  OpenSSL License
  ---------------

/* ====================================================================
 * Copyright (c) 1998-2011 The OpenSSL Project.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer. 
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 *
 * 3. All advertising materials mentioning features or use of this
 *    software must display the following acknowledgment:
 *    "This product includes software developed by the OpenSSL Project
 *    for use in the OpenSSL Toolkit. (http://www.openssl.org/)"
 *
 * 4. The names "OpenSSL Toolkit" and "OpenSSL Project" must not be used to
 *    endorse or promote products derived from this software without
 *    prior written permission. For written permission, please contact
 *    openssl-core@openssl.org.
 *
 * 5. Products derived from this software may not be called "OpenSSL"
 *    nor may "OpenSSL" appear in their names without prior written
 *    permission of the OpenSSL Project.
 *
 * 6. Redistributions of any form whatsoever must retain the following
 *    acknowledgment:
 *    "This product includes software developed by the OpenSSL Project
 *    for use in the OpenSSL Toolkit (http://www.openssl.org/)"
 *
 * THIS SOFTWARE IS PROVIDED BY THE OpenSSL PROJECT ``AS IS'' AND ANY
 * EXPRESSED OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE OpenSSL PROJECT OR
 * ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 * ====================================================================
 *
 * This product includes cryptographic software written by Eric Young
 * (eay@cryptsoft.com).  This product includes software written by Tim
 * Hudson (tjh@cryptsoft.com).
 *
 */

 Original SSLeay License
 -----------------------

/* Copyright (C) 1995-1998 Eric Young (eay@cryptsoft.com)
 * All rights reserved.
 *
 * This package is an SSL implementation written
 * by Eric Young (eay@cryptsoft.com).
 * The implementation was written so as to conform with Netscapes SSL.
 * 
 * This library is free for commercial and non-commercial use as long as
 * the following conditions are aheared to.  The following conditions
 * apply to all code found in this distribution, be it the RC4, RSA,
 * lhash, DES, etc., code; not just the SSL code.  The SSL documentation
 * included with this distribution is covered by the same copyright terms
 * except that the holder is Tim Hudson (tjh@cryptsoft.com).
 * 
 * Copyright remains Eric Young's, and as such any Copyright notices in
 * the code are not to be removed.
 * If this package is used in a product, Eric Young should be given attribution
 * as the author of the parts of the library used.
 * This can be in the form of a textual message at program startup or
 * in documentation (online or textual) provided with the package.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. All advertising materials mentioning features or use of this software
 *    must display the following acknowledgement:
 *    "This product includes cryptographic software written by
 *     Eric Young (eay@cryptsoft.com)"
 *    The word 'cryptographic' can be left out if the rouines from the library
 *    being used are not cryptographic related :-).
 * 4. If you include any Windows specific code (or a derivative thereof) from 
 *    the apps directory (application code) you must include an acknowledgement:
 *    "This product includes software written by Tim Hudson (tjh@cryptsoft.com)"
 * 
 * THIS SOFTWARE IS PROVIDED BY ERIC YOUNG ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 * 
 * The licence and distribution terms for any publically available version or
 * derivative of this code cannot be changed.  i.e. this code cannot simply be
 * copied and put under another distribution licence
 * [including the GNU Public Licence.]
 */


ISC license used for completely new code in BoringSSL:

/* Copyright (c) 2015, Google Inc.
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
 * SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
 * OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
 * CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. */


The code in third_party/fiat carries the MIT license:

Copyright (c) 2015-2016 the fiat-crypto authors (see
https://github.com/mit-plv/fiat-crypto/blob/master/AUTHORS).

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


Licenses for support code
-------------------------

Parts of the TLS test suite are under the Go license. This code is not included
in BoringSSL (i.e. libcrypto and libssl) when compiled, however, so
distributing code linked against BoringSSL does not trigger this license:

Copyright (c) 2009 The Go Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


BoringSSL uses the Chromium test infrastructure to run a continuous build,
trybots etc. The scripts which manage this, and the script for generating build
metadata, are under the Chromium license. Distributing code linked against
BoringSSL does not trigger this license.

Copyright 2015 The Chromium Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Appendix E: BSD 2-Clause licenses

One block per copyright holder, verbatim from the component's license file.

### John MacFarlane

Used by: cmark-gfm, in swift-cmark (file `COPYING`; the same file also carries the MIT notices of Appendix B).

```text
Copyright (c) 2014, John MacFarlane

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Colin Percival

Used by: bsdiff and bspatch, in Sparkle.

```text
bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### Mark Hamlin

Used by: SUSignatureVerifier, in Sparkle.

```text
SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### Daniel Müllner and Google Inc. (fastcluster)

Used by: fastcluster, bundled in FluidAudio.

```text
Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Appendix F: BSD 3-Clause licenses

One block per copyright holder, verbatim from the component's license file.

### The LevelDB Authors

Used by: leveldb (Firebase fork).

```text
Copyright (c) 2011 The LevelDB Authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Google Inc. (libwebp)

Used by: libwebp, vendored in posthog-ios.

```text
Copyright (c) 2010, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Appendix G: zlib licenses

One block per copyright holder, verbatim from the component's license file.

### Petteri Aimonen

Used by: nanopb (Firebase fork).

```text
Copyright (c) 2011 Petteri Aimonen <jpa at nanopb.mail.kapsi.fi>

This software is provided 'as-is', without any express or 
implied warranty. In no event will the authors be held liable 
for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any 
purpose, including commercial applications, and to alter it and 
redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you 
   must not claim that you wrote the original software. If you use 
   this software in a product, an acknowledgment in the product 
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and 
   must not be misrepresented as being the original software.

3. This notice may not be removed or altered from any source 
   distribution.
```

### Orson Peters

Used by: ed25519, vendored in Sparkle.

```text
Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.
```

## Appendix H: Upstream NOTICE files

Apache License 2.0 section 4(d) asks that the NOTICE file of a work be kept.
Among the packages linked into the app, the only upstream NOTICE file found
in the checkouts is the one below (swift-markdown). The Firebase iOS SDK
also ships `CoreOnly/NOTICES`, an aggregated list of third-party notices,
which is not reproduced here.

### swift-markdown (`NOTICE.txt`)

```text
                            The Swift Markdown Project
                            ==========================

Please visit the Swift Markdown web site for more information:

  * https://github.com/apple/swift-markdown

Copyright (c) 2021 Apple Inc. and the Swift project authors

The Swift Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

-------------------------------------------------------------------------------

This product contains Swift Argument Parser.

  * LICENSE (Apache License 2.0):
    * https://www.apache.org/licenses/LICENSE-2.0
  * HOMEPAGE:
    * https://github.com/apple/swift-argument-parser

---

This product contains a derivation of the cmark-gfm project, available at
https://github.com/apple/swift-cmark.

  * LICENSE (BSD-2):
    * https://opensource.org/licenses/BSD-2-Clause
  * HOMEPAGE:
    * https://github.com/github/cmark-gfm
```

### Additional terms found in Apache-2.0 files

- Firebase Firestore, `Firestore/LICENSE`: the `FirestoreEncoder` code is
  Apache-2.0 with this exception:

      As an exception, if you use this Software to compile your source code and
      portions of this Software are embedded into the binary product as a result,
      you may redistribute such product without providing attribution as would
      otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.

## Appendix I: CMU Pronouncing Dictionary license

Applies to `Transcription/Training/cmudict_phones.txt` (section 6). Text as
published in https://github.com/cmusphinx/cmudict (`LICENSE`).

```
Copyright (C) 1993-2015 Carnegie Mellon University. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
   The contents of this file are deemed to be source code.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in
   the documentation and/or other materials provided with the
   distribution.

This work was supported in part by funding from the Defense Advanced
Research Projects Agency, the Office of Naval Research and the National
Science Foundation of the United States of America, and by member
companies of the Carnegie Mellon Sphinx Speech Consortium. We acknowledge
the contributions of many volunteers to the expansion and improvement of
this dictionary.

THIS SOFTWARE IS PROVIDED BY CARNEGIE MELLON UNIVERSITY ``AS IS'' AND
ANY EXPRESSED OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL CARNEGIE MELLON UNIVERSITY
NOR ITS EMPLOYEES BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Appendix J: Unicode License v3

Applies to the emoji names in `Transcription/EmojiSemantic/emoji_anchors.json`
(section 6). Text as published at https://www.unicode.org/license.txt.

```
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```
