# Author: Kévin Naudin
#
# Dumps encoder parity fixtures for SYNTHETIC inputs whose length is an exact
# multiple of context_size (200), exercising the encoder's remainder==0 path and
# num_blocks >= 3 - neither of which any real dataset case hits (all have
# N % 200 != 0). The input mel is deterministic (seeded) and saved verbatim so
# the Swift test feeds byte-identical data.
#
# Usage:
#   source tools/granite_parity/.venv/bin/activate
#   python tools/granite_parity/dump_synthetic_encoder.py

import numpy as np
import mlx.core as mx

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dump_granite_fixtures import _patch_sanitize, _np, dump_encoder_with_blocks


def main():
    from mlx_audio.stt.utils import load_model

    _patch_sanitize()
    # repo-relative, independent of cwd
    out_root = Path(__file__).resolve().parent / "fixtures"

    print("Loading model...")
    model = load_model("ibm-granite/granite-speech-4.1-2b")
    mx.eval(model.parameters())

    rng = np.random.default_rng(0)
    # N multiples of context_size=200 -> remainder==0 at num_blocks 1, 2, 3.
    for n in (200, 400, 600):
        name = f"synthetic_{n}"
        case_out = out_root / name
        case_out.mkdir(parents=True, exist_ok=True)

        # realistic logmel-normalized range (~[-1, 1.5] after max-8/4+1)
        mel = rng.uniform(-1.0, 1.5, size=(1, n, 160)).astype(np.float32)
        np.save(case_out / "mel_features.npy", mel)

        input_features = mx.array(mel)
        encoder_out = dump_encoder_with_blocks(model, input_features, case_out)
        np.save(case_out / "encoder_out.npy", _np(encoder_out))
        print(f"{name}: encoder_out {encoder_out.shape}")

    print("Done.")


if __name__ == "__main__":
    main()
