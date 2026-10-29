#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
#
# Created by Kévin Naudin on 2026-10-29.
#
"""Build bigrams_common.txt from a Leipzig Corpora Collection sentences file.

Source: https://wortschatz.uni-leipzig.de/en/download/English, corpus
eng_news_2024_1M (CC BY 3.0, see THIRD_PARTY_NOTICES.md section 6).

    curl -O https://downloads.wortschatz-leipzig.de/corpora/eng_news_2024_1M.tar.gz
    tar -xzf eng_news_2024_1M.tar.gz eng_news_2024_1M/eng_news_2024_1M-sentences.txt
    python3 scripts/data/build_common_bigrams.py \
        eng_news_2024_1M/eng_news_2024_1M-sentences.txt \
        macos/Onit/Transcription/Training/bigrams_common.txt

Output format: one lowercase "word1 word2" per line, [a-z] words only, sorted
alphabetically. A bigram is kept when it occurs at least --min-count times.
The default of 30 gives about 58k pairs, the size of the list it replaces; it was
chosen as the F1 optimum against that list (precision 0.61, recall 0.61).
Pairs are only counted between neighbouring whitespace-separated tokens that are
purely alphabetic, and never across a comma, semicolon, colon, bracket or quote
(the first token must carry no punctuation), so "however, the" is not a bigram.
"""

import argparse
import re
from collections import Counter
from pathlib import Path

WORD = re.compile(r"[A-Za-z]+")
# The second token may end a clause ("... of the." / "... the end,"); the first may not.
TRAILING = ".,;:!?\"')”’"


def bigrams(sentence: str):
    tokens = sentence.split()
    for first, second in zip(tokens, tokens[1:]):
        if not WORD.fullmatch(first):
            continue
        if WORD.fullmatch(second.rstrip(TRAILING)):
            yield f"{first.lower()} {second.rstrip(TRAILING).lower()}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("sentences", type=Path, help="Leipzig *-sentences.txt (id<TAB>sentence)")
    parser.add_argument("output", type=Path)
    parser.add_argument("--min-count", type=int, default=30)
    args = parser.parse_args()

    counts: Counter[str] = Counter()
    with args.sentences.open(encoding="utf-8") as handle:
        for line in handle:
            _, _, sentence = line.rstrip("\n").partition("\t")
            counts.update(bigrams(sentence))

    kept = sorted(b for b, c in counts.items() if c >= args.min_count)
    args.output.write_text("\n".join(kept) + "\n", encoding="utf-8")
    print(f"{len(counts)} distinct bigrams, {len(kept)} kept (min count {args.min_count})")


if __name__ == "__main__":
    main()
