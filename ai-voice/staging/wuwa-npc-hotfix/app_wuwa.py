from __future__ import annotations

import json
import os

import gradio as gr

import app as base


def _list_wuwa_npcs():
    try:
        from sources.wuwa_local import list_characters

        characters = list_characters()
        choices = []
        for item in characters:
            state = "取得済み" if bool(item.get("acquired")) else "未取得"
            ids = ",".join(str(value) for value in item.get("speaker_ids", []))
            label = f"{item['name']}（{state}）"
            if ids:
                label += f" [{ids}]"
            choices.append((label, json.dumps(item, ensure_ascii=False)))
        return (
            f"鳴潮NPC {len(choices)}体を確認しました。取得するNPCを選択してください。",
            gr.Dropdown(choices=choices, value=choices[0][1] if choices else None),
        )
    except Exception as exc:
        return f"鳴潮NPC一覧を取得できませんでした: {exc}", gr.Dropdown(choices=[], value=None)


def _collect_wuwa_npc(character_json: str, max_events: int):
    try:
        from sources.wuwa_local import collect_character

        selected = json.loads(str(character_json or "{}"))
        name = str(selected.get("name") or "")
        records, _payload = collect_character(name, max_events=int(max_events))
        rows = [[
            bool(record.get("selected")),
            str(record.get("label", "")),
            str(record.get("transcript", "")),
            str(record.get("filename", "")),
            str(record.get("duration", "")),
            str(record.get("reason", "")),
            json.dumps(record, ensure_ascii=False),
        ] for record in records]
        return f"{name}: {len(rows)}件を確認しました。取り込む音声を選択してください。", rows
    except Exception as exc:
        return f"鳴潮NPC音声を取得できませんでした: {exc}", []


def _import_wuwa_npc(character_json: str, rows):
    try:
        from sources.wuwa_local import import_selected

        selected = json.loads(str(character_json or "{}"))
        name = str(selected.get("name") or "")
        return import_selected(name, rows)
    except Exception as exc:
        return f"鳴潮NPC音声を正式領域へ取り込めませんでした: {exc}", rows


with base.demo:
    with gr.Accordion("キャラクター取得・登録（鳴潮 NPC）", open=False):
        gr.Markdown(
            "ゲーム内の日本語音声資産から、取得経路を確認済みの鳴潮NPCを扱います。"
            "正式に取り込んだ音声は `参照音声/鳴潮/NPC/<名前>` に分離保存します。"
        )
        with gr.Row():
            wuwa_character = gr.Dropdown(label="NPC", choices=[], value=None)
            wuwa_list_button = gr.Button("鳴潮NPC一覧を取得")
            wuwa_max_events = gr.Slider(1, 200, value=20, step=1, label="取得音声上限")
        wuwa_status = gr.Markdown()
        wuwa_rows = gr.Dataframe(
            headers=["取得", "項目名", "台詞", "ファイル", "秒数", "確認事項", "取得情報"],
            datatype=["bool", "str", "str", "str", "str", "str", "str"],
            row_count=(0, "dynamic"),
            column_count=(7, "fixed"),
            interactive=True,
            wrap=True,
        )
        with gr.Row():
            wuwa_collect_button = gr.Button("選択NPCの音声を取得")
            wuwa_import_button = gr.Button("選択音声を正式領域へ取り込む", variant="primary")

    wuwa_list_button.click(
        _list_wuwa_npcs,
        outputs=[wuwa_status, wuwa_character],
    )
    wuwa_collect_button.click(
        _collect_wuwa_npc,
        inputs=[wuwa_character, wuwa_max_events],
        outputs=[wuwa_status, wuwa_rows],
    )
    wuwa_import_button.click(
        _import_wuwa_npc,
        inputs=[wuwa_character, wuwa_rows],
        outputs=[wuwa_status, wuwa_rows],
    )


if __name__ == "__main__":
    base.demo.queue(default_concurrency_limit=1).launch(
        server_name="127.0.0.1",
        server_port=int(os.environ.get("AI_VOICE_SERVER_PORT", "7862")),
        allowed_paths=[str(base.AI_ROOT)],
    )
