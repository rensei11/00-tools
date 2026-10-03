# Cezar司令センター ローカル保存場所

更新日: 2026-10-03

## Windows

- `%LOCALAPPDATA%\RenseiCezarCommand\extension`
  - 用途: Cezar司令センター専用Chrome拡張
  - 分類: 再生成可能
  - 正本: `rensei11/00-tools/cezar-command/commander_extension/`
  - AI音声ツールの拡張とは別物
  - 削除すると同一チャットへの自動返却が使えなくなるが、GitHubから再生成可能

## WSL

- `/home/rensei/cezar-command-center/00-tools`
  - 用途: public `00-tools` の管理clone
  - 分類: 再生成可能

- `/home/rensei/cezar-command-center/runtime`
  - 用途: Cezar 0.13.0、専用Node.js、PID、自己検査結果、実行状態
  - 分類: 再生成可能

- `/home/rensei/cezar-command-center/projects`
  - 用途: 実案件ごとの管理clone
  - 分類: 再生成可能なGit作業コピー
  - ユーザーデータの正本として扱わない

## 原則

- AI音声ツール本体の保存領域へ置かない
- `05-AI-voice` のCezar試験領域を新司令センターの実行基盤として使わない
- 旧8080番ChatGPT Bridgeへ依存しない
- 同一チャット返却は専用Chrome拡張で登録したChatGPT会話へ直接送る
