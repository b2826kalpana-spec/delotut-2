# FINKE PC REMOTE

A lightweight Windows command bridge for this user's ChatGPT workflow.

## Architecture

`ChatGPT -> private GitHub issue -> Windows agent -> PowerShell / SSH -> Cloud.ru`

The private GitHub issue is the command bus. The public repository contains code only; it contains no private SSH keys or tokens.

## One-command install

Run in Windows PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/b2826kalpana-spec/delotut-2/main/install.ps1' | iex"
```

The installer:

1. installs GitHub CLI with `winget` if needed;
2. opens GitHub web authorization if needed;
3. verifies access to the private command-bus issue;
4. verifies the existing local SSH key;
5. downloads the agent to `%LOCALAPPDATA%\FinkePcRemote`;
6. creates desktop Start / Stop / Status launchers;
7. enables user-level autostart;
8. starts the agent;
9. tests SSH to Cloud.ru.

## Local safety

- Commands are accepted only from the configured GitHub account and private issue.
- High-risk / secret-extraction patterns are blocked by default.
- High-risk commands require both `dangerous:true` in the command envelope and local `allowDangerous:true` in `config.json`.
- Private SSH keys remain local on Windows.
- Create `%LOCALAPPDATA%\FinkePcRemote\STOP` or run the desktop STOP launcher to stop the agent.
- Logs are stored in `%LOCALAPPDATA%\FinkePcRemote\agent.log`.

## Command protocol

A command issue comment is:

```text
FINKE_CMD_V1
<base64-encoded UTF-8 JSON>
```

JSON fields:

```json
{
  "id": "uuid",
  "target": "pc",
  "command": "hostname; whoami",
  "timeoutSeconds": 60,
  "dangerous": false
}
```

`target` can be `pc` or `server`. Server commands are executed through the already-configured local SSH key.

The agent posts `FINKE_RESULT_V1` comments with exit code, duration, status and bounded stdout/stderr.