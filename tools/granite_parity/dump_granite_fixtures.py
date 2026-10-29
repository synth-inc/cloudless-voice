# Author: Kévin Naudin
#
# Parity fixture generator for the native MLX-Swift Granite-Speech port.
#
# Loads ibm-granite/granite-speech-4.1-2b via mlx-audio (the Python reference
# implementation) and dumps fp32 .npy tensors at every module boundary, so the
# Swift port can assert allclose() against ground-truth intermediates at each
# sub-phase (4b preprocessing, 4c encoder, 4d projector, 4e decoder, 4g decode).
#
# Usage:
#   source tools/granite_parity/.venv/bin/activate
#   python tools/granite_parity/dump_granite_fixtures.py \
#       --repo ibm-granite/granite-speech-4.1-2b \
#       --datasets <dir of case folders, each with an audio.wav> \
#       --out tools/granite_parity/fixtures \
#       --cases case_010 case_011 case_012 case_013 case_014 case_015

import argparse
import json
import math
from pathlib import Path

import mlx.core as mx
import numpy as np


def _np(x) -> np.ndarray:
    """MLX array (any dtype) -> contiguous fp32 numpy."""
    return np.array(x.astype(mx.float32))


def _patch_sanitize():
    """mlx-audio 0.4.3 `Model.sanitize` only transposes conv weights when
    shape[-1] > shape[-2], which MISSES kernel-1 convs (up_conv/down_conv):
    the original bf16 HF checkpoint stores them as (out, in, 1) (PyTorch) but
    MLX Conv1d needs (out, 1, in). depth_conv (kernel 15) passes the heuristic,
    the kernel-1 ones don't -> conv1d channel-mismatch crash.

    Fix: on a non-pre-converted checkpoint, transpose ALL of up/down/depth_conv
    weights unconditionally (out, in, kernel) -> (out, kernel, in). This is also
    exactly what the Swift WeightLoading sanitize must do.
    """
    from mlx_audio.stt.models.granite_speech import granite_speech as gs

    def sanitize(weights):
        already = any("scales" in k for k in weights)
        out = {}
        for k, v in weights.items():
            if "num_batches_tracked" in k:
                continue
            if (
                not already
                and any(n in k for n in ["up_conv", "down_conv", "depth_conv"])
                and "weight" in k
                and v.ndim == 3
            ):
                v = v.transpose(0, 2, 1)
            out[k] = v
        return out

    gs.Model.sanitize = staticmethod(sanitize)


def dump_encoder_with_blocks(model, input_features, case_dir: Path):
    """Replicate CTCEncoder.__call__ so we can snapshot every conformer block."""
    enc = model.encoder
    x = enc.input_linear(input_features)
    dists = enc._attention_dists
    for idx, layer in enumerate(enc.layers, start=1):
        x = layer(x, attention_dists=dists)
        mx.eval(x)
        # NOTE: encoder_block_{idx} is the raw output of layer `idx`, saved
        # BEFORE the mid-layer CTC injection. So block_{n+1} != layer(block_n)
        # across the idx == num_layers//2 (==8) boundary: layer 9 actually sees
        # `block_08 + out_mid(softmax(out(block_08)))`. The Swift 4c test must
        # apply the same injection separately, not chain block_08 -> block_09.
        np.save(case_dir / f"encoder_block_{idx:02d}.npy", _np(x))
        if idx == enc.num_layers // 2:
            x_mid = enc.out(x)
            x = x + enc.out_mid(mx.softmax(x_mid, axis=-1))
            mx.eval(x)
    return x  # == model.encoder(input_features) (block_16 == encoder_out, exact)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="ibm-granite/granite-speech-4.1-2b")
    ap.add_argument("--datasets", required=True,
                    help="directory of case folders, each containing an audio.wav")
    ap.add_argument("--out", default="tools/granite_parity/fixtures")
    ap.add_argument("--cases", nargs="*", default=None,
                    help="case dir names; default = first N with audio.wav")
    ap.add_argument("--limit", type=int, default=6)
    ap.add_argument("--max-tokens", type=int, default=256)
    args = ap.parse_args()

    from mlx_audio.stt.utils import load_audio, load_model

    _patch_sanitize()

    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)

    print(f"Loading {args.repo} (downloads ~4.6 GB on first run)...")
    model = load_model(args.repo)
    mx.eval(model.parameters())
    print("Model loaded.")

    # Persist the resolved config + tokenizer special ids for the Swift side.
    cfg = model.config
    meta = {
        "repo": args.repo,
        "audio_token_index": cfg.audio_token_index,
        "downsample_rate": cfg.downsample_rate,
        "window_size": cfg.window_size,
        "encoder": cfg.encoder_config.__dict__,
        "projector": cfg.projector_config.__dict__,
        "text": cfg.text_config.__dict__,
        "eos_token_id": model._tokenizer.eos_token_id,
        "bos_token_id": getattr(model._tokenizer, "bos_token_id", None),
    }
    (out_root / "config_dump.json").write_text(json.dumps(meta, indent=2, default=str))
    print("Wrote config_dump.json")

    ds = Path(args.datasets)
    if args.cases:
        case_dirs = [ds / c for c in args.cases]
    else:
        case_dirs = sorted(p.parent for p in ds.glob("*/audio.wav"))[: args.limit]

    eos = model._tokenizer.eos_token_id

    for cdir in case_dirs:
        wav = cdir / "audio.wav"
        if not wav.exists():
            print(f"skip {cdir.name}: no audio.wav")
            continue
        case_out = out_root / cdir.name
        case_out.mkdir(parents=True, exist_ok=True)
        print(f"\n=== {cdir.name} ===")

        audio = load_audio(str(wav))
        np.save(case_out / "audio_input.npy", _np(audio))

        # 4b - preprocessing
        input_features, num_audio_tokens = model._extract_features(audio)
        mx.eval(input_features)
        np.save(case_out / "mel_features.npy", _np(input_features))
        print(f"mel_features {input_features.shape}  num_audio_tokens={num_audio_tokens}")

        # 4c - conformer encoder (+ per-block)
        encoder_out = dump_encoder_with_blocks(model, input_features, case_out)
        np.save(case_out / "encoder_out.npy", _np(encoder_out))
        print(f"encoder_out {encoder_out.shape}")

        # 4d - qformer projector
        projected = model.projector(encoder_out)
        mx.eval(projected)
        np.save(case_out / "projector_out.npy", _np(projected))
        print(f"projector_out {projected.shape}")

        # 4f - prompt + inputs_embeds splicing
        prompt_ids = model._build_prompt(num_audio_tokens, None)
        np.save(case_out / "prompt_ids.npy", np.array(prompt_ids).astype(np.int32))
        inputs_embeds = model._build_inputs_embeds(prompt_ids, projected)
        mx.eval(inputs_embeds)
        np.save(case_out / "inputs_embeds.npy", _np(inputs_embeds))
        print(f"prompt_ids {prompt_ids.shape}  inputs_embeds {inputs_embeds.shape}")

        # 4e - decoder logits at the first generated position (teacher-forced)
        logits = model(input_ids=prompt_ids[None], input_embeddings=inputs_embeds)
        mx.eval(logits)
        first_logits = logits[0, -1]
        np.save(case_out / "lm_logits_step0.npy", _np(first_logits))
        print(f"logits {logits.shape}  argmax0={int(mx.argmax(first_logits).item())}")

        # 4g - greedy decode (temperature 0). Capture the REAL ids emitted by
        # generate_step (NOT encode(decode(...)), which is not idempotent and
        # would give a circular / wrong exact-match target). Reuse the already
        # computed prompt_ids + inputs_embeds, mirroring Model.generate().
        from mlx_lm.generate import generate_step
        from mlx_lm.sample_utils import make_sampler

        sampler = make_sampler(0.0)  # temperature 0 -> greedy / deterministic
        gen_ids = []
        for token, _ in generate_step(
            prompt=prompt_ids,
            input_embeddings=inputs_embeds.squeeze(0),
            model=model,
            max_tokens=args.max_tokens,
            sampler=sampler,
        ):
            if token == eos:
                break
            gen_ids.append(int(token))
        text = model._tokenizer.decode(gen_ids, skip_special_tokens=True)
        np.save(case_out / "token_ids.npy", np.array(gen_ids).astype(np.int32))
        (case_out / "final_text.txt").write_text(text)
        print(f"token_ids[{len(gen_ids)}] text: {text!r}")

    print("\nDone. Fixtures in", out_root)


if __name__ == "__main__":
    main()
