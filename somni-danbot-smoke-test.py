from __future__ import annotations

import sys
from pathlib import Path

MODEL_ID = "dartags/DanbotNL-2408-260M"

TEST_PROMPT = (
    "\u6210\u4eba\u306e\u30b7\u30fc\u30e1\u30fc\u30eb\u300240\u6b73\u3067\u80a5\u6e80\u4f53\u578b\u3002"
    "\u90e8\u5c4b\u306e\u30d9\u30c3\u30c9\u306b\u5ea7\u308a\u3001\u7247\u624b\u3092\u982d\u306e\u5f8c\u308d\u306b\u56de\u3057\u3001"
    "\u8107\u3092\u898b\u305b\u3064\u3051\u3066\u3044\u308b\u3002"
    "\u3082\u30461\u3064\u306e\u624b\u3067\u3064\u307e\u3093\u3067\u4f38\u3070\u3057\u3066\u3044\u308b\u3002"
    "\u6b63\u9762\u304b\u3089\u3053\u3061\u3089\u3092\u898b\u3064\u3081\u308b\u3002"
    "\u88f8\u3067\u3001\u6c57\u3067\u3073\u3063\u3057\u3087\u308a\u6fe1\u308c\u3001\u4f53\u304c\u71b1\u304f\u3001"
    "\u6e6f\u6c17\u304c\u7acb\u3061\u4e0a\u3063\u3066\u3044\u308b\u3002\u5e3d\u5b50\u3092\u304b\u3076\u3063\u3066\u3044\u308b\u3002"
    "\u767a\u60c5\u3057\u3066\u304a\u308a\u3001\u6311\u767a\u7684\u3067\u3001\u4f55\u304b\u3092\u6c42\u3081\u3066\u3044\u308b\u3002"
)

ABC_ROWS = [
    ("\u30b7\u30fc\u30e1\u30fc\u30eb", "semeil"),
    ("\u30d9\u30c3\u30c9\u306b\u5ea7\u308a", "sitting on bed"),
    ("\u7247\u624b\u3092\u982d\u306e\u5f8c\u308d\u306b\u56de\u3057", "hand behind head"),
    ("\u8107\u3092\u898b\u305b\u3064\u3051\u3066\u3044\u308b", "showing side"),
    ("\u3082\u30461\u3064\u306e\u624b\u3067\u3064\u307e\u3093\u3067\u4f38\u3070\u3057\u3066\u3044\u308b", "pinching and stretching with other hand"),
    ("\u6b63\u9762\u304b\u3089\u3053\u3061\u3089\u3092\u898b\u3064\u3081\u308b", "looking at viewer"),
    ("40\u6b73", "40 years old"),
    ("\u80a5\u6e80\u4f53\u578b", "fat body"),
    ("\u88f8", "nude"),
    ("\u6c57\u3067\u3073\u3063\u3057\u3087\u308a\u6fe1\u308c", "soaked in sweat"),
    ("\u71b1\u3044\u4f53", "heat body"),
    ("\u6e6f\u6c17\u304c\u7acb\u3061\u4e0a\u3063\u3066\u3044\u308b", "steam rising"),
    ("\u5e3d\u5b50", "hat"),
    ("\u90e8\u5c4b", "room"),
    ("\u767a\u60c5\u3057\u3066\u3044\u308b", "lustful"),
    ("\u6311\u767a\u7684", "provocative"),
    ("\u4f55\u304b\u3092\u6c42\u3081\u3066\u304a\u308a", "seeking something"),
]

def main() -> int:
    report_dir = Path(sys.argv[2])
    report_dir.mkdir(parents=True, exist_ok=True)

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
        encoder_text=TEST_PROMPT,
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

    lines = []
    lines.append("DanbotNL vs current Somni ABC: SUCCESS")
    lines.append("")
    lines.append("MODEL")
    lines.append("=====")
    lines.append(MODEL_ID)
    lines.append("Device: " + device)
    lines.append("")
    lines.append("TEST INPUT")
    lines.append("==========")
    lines.append(TEST_PROMPT)
    lines.append("")
    lines.append("CURRENT SOMNI ABC OUTPUT")
    lines.append("========================")
    for source, abc in ABC_ROWS:
        lines.append(source + " -> " + abc)
    lines.append("")
    lines.append("DANBOTNL OUTPUT")
    lines.append("================")
    lines.append(tags)
    lines.append("")
    lines.append("NOTE")
    lines.append("====")
    lines.append("This compares the same 17 adult-only conditions.")
    lines.append("The previous minor-related condition is excluded from this comparison.")
    lines.append("Judge whether DanbotNL preserves the requested attributes better than the current ABC output.")

    result = "\n".join(lines) + "\n"
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
