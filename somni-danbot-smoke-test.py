from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REQUEST_ID = "ai-6c28ab58-2e9e-4fae-9ca2-dd02a03a64a9"
PROMPT_ID = "266e1dd0-42cc-438d-a01a-8c7d7aab498b"
MODEL_ID = "dartags/DanbotNL-2408-260M"

JP_RE = re.compile(r"[\u3040-\u30ff\u3400-\u9fff]")
CONCEPTS = [
    "40\u6b73",
    "\u80a5\u6e80",
    "\u88f8",
    "\u6c57",
    "\u6e6f\u6c17",
    "\u5e3d\u5b50",
    "\u30d9\u30c3\u30c9",
    "\u30b7\u30fc\u30e1\u30fc\u30eb",
    "\u80f8",
    "\u8107",
    "\u6b63\u9762",
]

def read_text_file(path: Path):
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if len(raw) > 10 * 1024 * 1024:
        return None
    for enc in ("utf-8-sig", "utf-8", "cp932"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            pass
    return None

def score_text(text: str, label: str) -> int:
    if not isinstance(text, str):
        return -999
    text = text.strip()
    if len(text) < 10 or not JP_RE.search(text):
        return -999
    score = 0
    low = label.lower()
    if any(k in low for k in ("prompt", "input", "message", "text", "user", "original", "request")):
        score += 25
    if any(k in low for k in ("negative", "output", "response", "translation", "tag", "english")):
        score -= 20
    hits = sum(1 for c in CONCEPTS if c in text)
    score += hits * 10
    if 40 <= len(text) <= 2500:
        score += 10
    if REQUEST_ID in text or PROMPT_ID in text:
        score += 10
    return score

def collect_json(obj, label="root"):
    out = []
    if isinstance(obj, dict):
        for key, value in obj.items():
            out.extend(collect_json(value, label + "." + str(key)))
    elif isinstance(obj, list):
        for index, value in enumerate(obj):
            out.extend(collect_json(value, label + "[" + str(index) + "]"))
    elif isinstance(obj, str):
        score = score_text(obj, label)
        if score > -999:
            out.append((score, label, obj.strip()))
    return out

def extract_prompt(evidence: Path, report_dir: Path) -> str:
    candidates = []
    suffixes = {".json", ".txt", ".log", ".md", ".yaml", ".yml", ".csv"}

    for path in evidence.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in suffixes:
            continue

        text = read_text_file(path)
        if text is None:
            continue

        rel = str(path.relative_to(evidence))

        if path.suffix.lower() == ".json":
            try:
                obj = json.loads(text)
                candidates.extend(collect_json(obj, rel))
            except Exception:
                pass

        paragraphs = re.split(r"\n\s*\n|\r\n\s*\r\n", text)
        for index, paragraph in enumerate(paragraphs):
            paragraph = paragraph.strip()
            score = score_text(paragraph, rel + "#paragraph" + str(index))
            if score > -999:
                candidates.append((score, rel + "#paragraph" + str(index), paragraph))

    if not candidates:
        raise RuntimeError("No Japanese prompt candidate was found in the saved evidence.")

    candidates.sort(key=lambda item: (item[0], len(item[2])), reverse=True)

    dedup = []
    seen = set()
    for item in candidates:
        value = item[2].strip()
        if value in seen:
            continue
        seen.add(value)
        dedup.append(item)
        if len(dedup) >= 20:
            break

    with (report_dir / "prompt_candidates.txt").open("w", encoding="utf-8-sig") as handle:
        for rank, (score, label, value) in enumerate(dedup, 1):
            handle.write("=== CANDIDATE %d score=%d source=%s ===\n" % (rank, score, label))
            handle.write(value + "\n\n")

    best_score, best_label, best = dedup[0]
    hits = [c for c in CONCEPTS if c in best]

    if best_score < 40 or len(hits) < 3:
        raise RuntimeError(
            "The original prompt could not be identified safely. "
            "Candidates were saved to prompt_candidates.txt. "
            "No guessed prompt was sent to DanbotNL."
        )

    return best

def main() -> int:
    somni = Path(sys.argv[1])
    report_dir = Path(sys.argv[2])

    evidence = somni.parent / "Somni-backup" / "generation-evidence" / "somni_00040"
    if not evidence.is_dir():
        raise RuntimeError("Saved generation evidence folder somni_00040 was not found.")

    report_dir.mkdir(parents=True, exist_ok=True)

    prompt = extract_prompt(evidence, report_dir)
    (report_dir / "source_prompt.txt").write_text(prompt, encoding="utf-8-sig")

    import torch
    from transformers import AutoModelForPreTraining, AutoProcessor

    processor = AutoProcessor.from_pretrained(
        MODEL_ID,
        trust_remote_code=True,
    )
    model = AutoModelForPreTraining.from_pretrained(
        MODEL_ID,
        trust_remote_code=True,
        torch_dtype=torch.float32,
    )

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model.to(device)
    model.eval()

    decoder_text = processor.decoder_tokenizer.apply_chat_template(
        {
            "aspect_ratio": "tall",
            "rating": "explicit",
            "length": "very_long",
            "translate_mode": "exact",
        },
        tokenize=False,
    )

    inputs = processor(
        encoder_text=prompt,
        decoder_text=decoder_text,
        return_tensors="pt",
    )

    with torch.inference_mode():
        outputs = model.generate(
            **inputs.to(model.device),
            do_sample=False,
            eos_token_id=processor.decoder_tokenizer.convert_tokens_to_ids("</translation>"),
        )

    tags = ", ".join(
        tag
        for tag in processor.batch_decode(
            outputs[0, len(inputs.input_ids[0]):],
            skip_special_tokens=True,
        )
        if tag.strip() != ""
    )

    result = (
        "DanbotNL standalone smoke test: SUCCESS\n\n"
        "Model: " + MODEL_ID + "\n"
        "Mode: exact\n"
        "Rating: explicit\n"
        "Aspect ratio: tall\n"
        "Device: " + device + "\n\n"
        "SOURCE PROMPT\n"
        "=============\n"
        + prompt
        + "\n\nDANBOORU TAGS\n"
        "=============\n"
        + tags
        + "\n"
    )

    result_path = report_dir / "result.txt"
    result_path.write_text(result, encoding="utf-8-sig")

    print(result)
    print("RESULT_FILE=" + str(result_path))
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("DANBOT_TEST_FAILED: " + repr(exc), file=sys.stderr)
        raise
