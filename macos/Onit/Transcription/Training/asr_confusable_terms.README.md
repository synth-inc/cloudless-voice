# `asr_confusable_terms.txt`

24,183 lowercased words that **Qwen3-ASR fails to transcribe correctly when spoken
in isolation**. `CapsTermSelector` subtracts them from the mining vocabulary, so a
word on this list is treated as out-of-vocabulary and becomes eligible for the ASR
glossary when it appears on screen.

## Why it exists

Layer C mining decides "is this word worth biasing?" by asking whether it is
out-of-vocabulary against `eng_news_2024_100K-words.txt`. That list is a news
crawl, and it is wrong in both directions:

- It lists rare names as common English - "Yann", "Huang", even "Abbie"
  (freq 2) - so mining skipped exactly the words that needed biasing. Dictating
  "Abbie" produced "Abby" for this reason.
- It clears true homophones the model reliably gets wrong: Wright→"Right",
  Moore→"More", Leeds→"Leads", Capitol→"Capital".

Frequency and capitalization heuristics could not separate these. Measuring could.

## How it was built (2026-08)

Every candidate word was synthesized and transcribed back through the shipping
ASR (`Qwen3-ASR-1.7B-8bit`, no glossary, no boost, empty prompt). A word is
"confusable" when the ASR does not reproduce it as a whole token.

- **3 Kokoro-82M voices** (`af_heart`, `am_michael`, `bf_emma`) via MLX, majority
  vote - 23,360 verdicts. Local, free, ~8.6 words/sec.
- **ElevenLabs `multilingual_v2`** ground truth - 824 verdicts, used for the
  ordinary-English words where a wrong entry would pollute the glossary.

**A single TTS voice is not sufficient**, which is the main lesson here. macOS
Samantha alone disagreed with ElevenLabs on ~20% of words, mispronouncing ordinary
words into false entries ("brought"→"Broad", "Musk"→"Mosque"). Kokoro alone has the
opposite failure: it falls back to espeak-ng letter-to-sound rules for anything
outside its lexicon, so it mangles well-known proper nouns ("Ottawa"→"How do I?",
"Ohio"→"Pirate"). The two systems' errors are largely independent, which is why the
high-stakes band is arbitrated by ElevenLabs.

Measured agreement with ElevenLabs on a stratified sample: Samantha alone 79%,
Kokoro 3-voice majority 84%. ElevenLabs' own two models agree with each other 89%,
so ~85% is close to the practical ceiling - rare-word rendering is genuinely
variable, and the rare-band verdicts carry real residual error.

## What is deliberately NOT affected

`isKnownEnglishWord` still reads the **full** 100k list. It gates trie-boost
aliases, where a false negative turns a real English word into an unconditional
rewrite of the user's speech, so it must stay permissive: "Wright" is still English
even though the ASR mishears it. Same for `isCommonWord` (the format matcher's
top-25k ambiguity test).

## Regenerating

Scripts live in the analysis scratchpad, not the repo (they need `mlx-audio`,
`misaki`, and a Homebrew `espeak-ng`). The pipeline is: build a manifest from the
frequency list, synthesize per voice with Kokoro, transcribe with the
`TtsNameRoundTripTests` batch harness (`ONIT_TTS_WAV_DIR` / `ONIT_TTS_OUT`),
score by whole-token match, majority-vote across voices, then arbitrate the
everyday-English band with ElevenLabs.

Note the scoring rule matters: substring containment is **not** enough. "Mooresville"
contains "moore" but is a different word, and scoring that as success silently
cleared real failures.
