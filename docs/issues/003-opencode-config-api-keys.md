# 003: The host opencode config with API keys is in every container

Priority: high. Status: open.

## Problem

The launcher mounts the host `~/.config/opencode` read-only in every container, also in Claude containers. `opencode.json` holds two API keys in plain text. Every agent can read them. The launcher sanitizes the Claude config, but not the opencode config.

## Proposed fix

1. Rotate the two keys. This is necessary in all cases.
2. Stage a copy of the opencode config in `.staging/<container>/opencode/`, as the launcher does for Claude. Replace each key with an `{env:NAME}` reference.
3. Mount the staged copy and not the host folder. Pass the keys as environment variables only to opencode containers.
4. Better: keep the keys out of `opencode.json` on the host too. Use `{env:NAME}` there, and set the variables from Windows Credential Manager.

## Verify

1. In a Claude container, no file and no environment variable holds the keys.
2. opencode in a container can still call the providers that use the keys.
