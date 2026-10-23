# 006: opencode gets the container note only through the host config

Priority: low. Status: open.

## Problem

The entrypoint adds `container-instructions.md` to `~/.claude/CLAUDE.md`. opencode reads that file only because the host `opencode.json` lists `~/.claude/CLAUDE.md` in `instructions`. If that line is removed, opencode in a container does not know it runs in a container, and nothing shows an error.

## Proposed fix

Do this together with 003. When the launcher stages its own copy of the opencode config, it adds `/etc/agent-box/container-instructions.md` to `instructions` only if `~/.claude/CLAUDE.md` is not in the list. Then opencode reads the note once, in all cases.

## Verify

`opencode debug config` in a container lists the note exactly one time, with and without the `CLAUDE.md` entry in the host config.
