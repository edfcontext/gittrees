#!/usr/bin/env python3
"""Convert the GitTrees commit-intent ONNX/PyTorch model to a Core ML mlpackage.

Prefers the ONNX file the user asked to ship (`model.int8.onnx`). onnxruntime INT8
graphs often use ops coremltools cannot lower, so the script falls back to the
matching FP32 ONNX, then to the PyTorch checkpoint that produced it. Weights are
then linearly quantized to INT8 so the bundled package stays in the ~20 MB range.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import numpy as np

MODEL_ROOT = Path("/Users/user/Dev/AI-Projects/gittrees-model")
DEFAULT_OUT = Path(__file__).resolve().parents[1] / "Sources/GitTreesCore/Resources/CommitIntentModel"


def _convert_onnx(onnx_path: Path, seq: int):
    import coremltools as ct

    print(f"converting ONNX {onnx_path} …")
    # coremltools 9 dropped an explicit ONNX source; "auto" still sniffs the file.
    return ct.convert(
        str(onnx_path),
        source="auto",
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, seq), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, seq), dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="type_logits"),
            ct.TensorType(name="action_logits"),
            ct.TensorType(name="scope_logits"),
        ],
    )


def _coreml_io(seq: int):
    import coremltools as ct
    inputs = [
        ct.TensorType(name="input_ids", shape=(1, seq), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, seq), dtype=np.int32),
    ]
    outputs = [
        ct.TensorType(name="type_logits"),
        ct.TensorType(name="action_logits"),
        ct.TensorType(name="scope_logits"),
    ]
    return inputs, outputs


def _convert_torch(checkpoint: Path, seq: int):
    """Trace with fixed-length embedding buffers so Core ML never sees BERT's
    dynamic `position_ids` arange/slice — the usual MiniLM conversion failure."""
    import coremltools as ct
    import torch
    import torch.nn as nn

    sys.path.insert(0, str(MODEL_ROOT))
    from training.model import build_model, default_spec

    cfg = json.loads((checkpoint / "train_config.json").read_text())
    spec = default_spec(str(checkpoint / "labels.json"), cfg["encoder"], cfg["max_tokens"])
    model = build_model(spec)
    state = torch.load(checkpoint / "pytorch_model.pt", map_location="cpu", weights_only=True)
    model.load_state_dict(state)
    model.eval()

    src = model.encoder.embeddings

    class FixedEmbeddings(nn.Module):
        def __init__(self):
            super().__init__()
            self.word_embeddings = src.word_embeddings
            self.position_embeddings = src.position_embeddings
            self.token_type_embeddings = src.token_type_embeddings
            self.LayerNorm = src.LayerNorm
            self.register_buffer("position_ids", torch.arange(seq).unsqueeze(0))
            self.register_buffer("token_type_ids", torch.zeros(1, seq, dtype=torch.long))

        def forward(self, input_ids=None, token_type_ids=None, position_ids=None,
                    inputs_embeds=None, past_key_values_length=0):
            hidden = self.word_embeddings(input_ids)
            hidden = hidden + self.token_type_embeddings(self.token_type_ids)
            hidden = hidden + self.position_embeddings(self.position_ids)
            return self.LayerNorm(hidden)

    model.encoder.embeddings = FixedEmbeddings()
    model.eval()

    class Wrapper(nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, input_ids, attention_mask):
            out = self.inner.encoder(input_ids=input_ids, attention_mask=attention_mask)
            cls = out.last_hidden_state[:, 0]
            return (
                self.inner.heads["head_type"](cls),
                self.inner.heads["head_action"](cls),
                self.inner.heads["head_scope"](cls),
            )

    wrapped = Wrapper(model)
    wrapped.eval()
    dummy = torch.ones(1, seq, dtype=torch.long)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, (dummy, dummy), check_trace=False, strict=False)
    traced.eval()

    inputs, outputs = _coreml_io(seq)
    last_err = None
    for backend in ("mlprogram", "neuralnetwork"):
        try:
            print(f"converting traced PyTorch checkpoint {checkpoint} as {backend} …")
            kwargs = dict(
                source="pytorch",
                convert_to=backend,
                minimum_deployment_target=ct.target.macOS14,
                inputs=inputs,
                outputs=outputs,
            )
            if backend == "mlprogram":
                kwargs["compute_precision"] = ct.precision.FLOAT32
            return ct.convert(traced, **kwargs)
        except Exception as exc:
            last_err = exc
            print(f"{backend} failed: {type(exc).__name__}: {exc}")
    raise last_err


def _quantize(mlmodel):
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    print("quantizing weights to int8 …")
    config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
    )
    return linear_quantize_weights(mlmodel, config=config)


def _copy_sidecar(checkpoint: Path, package: Path, out: Path, seq: int, source: str):
    out.mkdir(parents=True, exist_ok=True)
    for name in ("tokenizer.json", "tokenizer_config.json", "labels.json"):
        src = checkpoint / name
        if not src.exists():
            src = package / name
        if src.exists():
            shutil.copy(src, out / name)
    manifest = {
        "name": "gittrees-commit-intent",
        "version": "0.1.0",
        "runtime": "coreml",
        "modelType": "multi-head-classifier",
        "maxTokens": seq,
        "encoder": "sentence-transformers/all-MiniLM-L6-v2",
        "outputs": ["type", "action", "scope"],
        "convertedFrom": source,
        "confidenceThreshold": 0.50,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def convert(
    onnx_int8: Path,
    onnx_fp32: Path,
    checkpoint: Path,
    package: Path,
    out: Path,
    seq: int,
):
    last_err = None
    mlmodel = None
    source = None
    for label, path, fn in (
        ("pytorch", checkpoint, lambda: _convert_torch(checkpoint, seq)),
        ("onnx-int8", onnx_int8, lambda: _convert_onnx(onnx_int8, seq)),
        ("onnx-fp32", onnx_fp32, lambda: _convert_onnx(onnx_fp32, seq)),
    ):
        if path is None or not path.exists():
            print(f"skip {label}: missing {path}")
            continue
        try:
            mlmodel = fn()
            source = f"{label}:{path}"
            print(f"converted via {source}")
            break
        except Exception as exc:  # conversion of INT8 ONNX is the expected miss
            last_err = exc
            print(f"{label} failed: {type(exc).__name__}: {exc}")
    if mlmodel is None:
        raise RuntimeError(f"all conversion paths failed; last error: {last_err}")

    try:
        mlmodel = _quantize(mlmodel)
        source = f"{source}+int8-weights"
    except Exception as exc:
        print(f"quantization failed, keeping fp32: {type(exc).__name__}: {exc}")

    dest = out / "CommitIntent.mlpackage"
    if dest.exists():
        shutil.rmtree(dest)
    out.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(dest))
    _copy_sidecar(checkpoint, package, out, seq, source)
    size = sum(p.stat().st_size for p in dest.rglob("*") if p.is_file())
    print(json.dumps({"out": str(out), "source": source, "bytes": size, "mb": round(size / 1e6, 2)}))
    return dest


def main():
    ap = argparse.ArgumentParser()
    # INT8 ONNX first (shipping-size file). coremltools often cannot lower
    # onnxruntime MatMulInteger graphs, in which case we convert the matching
    # FP32 graph / checkpoint and quantize weights with coremltools instead.
    # Prefer the LLM-teacher artifacts when present — that is the model the
    # experiment showed is worth bundling — and still try model.int8.onnx.
    ap.add_argument("--onnx-int8", default=str(MODEL_ROOT / "model/model-llm.int8.onnx"))
    ap.add_argument("--onnx-fp32", default=str(MODEL_ROOT / "model/model-llm.onnx"))
    ap.add_argument("--checkpoint", default=str(MODEL_ROOT / "model/checkpoint-llm"))
    ap.add_argument("--package", default=str(MODEL_ROOT / "model/gittrees-commit-model"))
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--seq", type=int, default=256)
    args = ap.parse_args()
    convert(
        Path(args.onnx_int8),
        Path(args.onnx_fp32),
        Path(args.checkpoint),
        Path(args.package),
        Path(args.out),
        args.seq,
    )


if __name__ == "__main__":
    main()
