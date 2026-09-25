# Claude Code hook JSON, captured from a real session

These eight files are the JSON Claude Code sent on stdin to this plugin's hooks, saved from a real interactive session. The hook tests send these shapes instead of hand-written ones, so a test cannot pass on a field Claude Code never sends.

| File | Event | Tool |
|---|---|---|
| `bash-pre.json` | PreToolUse | Bash |
| `bash-post.json` | PostToolUse | Bash |
| `write-pre.json` | PreToolUse | Write |
| `write-post.json` | PostToolUse | Write |
| `edit-pre.json` | PreToolUse | Edit |
| `edit-post.json` | PostToolUse | Edit |
| `notebookedit-pre.json` | PreToolUse | NotebookEdit |
| `notebookedit-post.json` | PostToolUse | NotebookEdit |

## Provenance

- **Host:** Claude Code 2.1.273 (`claude --version`), macOS, interactive session driven through a pseudo-terminal, 2026-09-16.
- **Plugin:** this repository's working tree, loaded with `--plugin-dir`, on the branch that added these files. For the capture, `hooks/hooks.json` in a scratch copy pointed at a wrapper that saved stdin to a file and then ran the shipped `scripts/pre-tool-check.sh` / `scripts/post-tool-audit.sh` unmodified, replaying their stdout, stderr and exit code to Claude Code.
- **Prompt:** run `echo p1-allow-capture`, write `p1-note.txt` containing `p1-write-capture`, then edit it to `p1-edit-capture`.
- **The NotebookEdit pair** came from a second session the same day, set up the same way, with `--allowedTools Read NotebookEdit` and the prompt: use NotebookEdit on `p1-nb.ipynb` to replace the source of cell `c1` with `print('p1-notebook-capture')`. Both hooks exited 0 with nothing on stdout.
- **AxonFlow:** a local community AxonFlow v11.0.0 stack (`getaxonflow/axonflow` `dcd5f636d`), agent at `http://127.0.0.1:18080`. All the calls were allowed; both hooks exited 0 with nothing on stdout.

## The environment, and why the run could not reach production

- Claude Code ran with `--setting-sources project` from an empty scratch working directory (no user settings or user hooks loaded), `--settings '{"enabledPlugins":{"axonflow@axonflow":false}}'`, `--strict-mcp-config` (no MCP servers), `--permission-mode dontAsk` and `--allowedTools 'Bash(echo p1-*)' Write Edit`.
- **The hooks ran with a sandboxed environment; the host did not.** Each hook ran with `HOME`, `XDG_CACHE_HOME` and `AXONFLOW_CONFIG_DIR` set to scratch directories, `AXONFLOW_ENDPOINT=http://127.0.0.1:18080`, `AXONFLOW_AUTH` unset, `AXONFLOW_TELEMETRY=off` and `DO_NOT_TRACK=1`. Claude Code itself kept the real `HOME`, because a sandboxed `HOME` has no Claude Code login. The host's own AxonFlow registration file under its real `HOME` was never read: the hooks' `HOME` and `AXONFLOW_CONFIG_DIR` pointed elsewhere.
- With `AXONFLOW_ENDPOINT` set, the hooks run in self-hosted mode, and the Community SaaS registration is a no-op. The pre hook's canary on stderr read `[AxonFlow] Connected to AxonFlow at http://127.0.0.1:18080 (mode=self-hosted)`, and no `try-registration.json` was created anywhere under the sandbox.

## What was changed from the capture

Only local paths, so no machine or user name is published. The keys, their order, the value types and every other value are as captured (checked with `jq '[paths(scalars)], [.. | type]'` against the raw files).

- the session's working directory → `/home/user/project`
- the transcript directory → `/home/user/.claude/projects/-home-user-project`
- the session scratchpad → `/tmp/claude-1000/-home-user-project/SESSION/scratchpad`

## What the capture shows

- A Bash `tool_response` is an object, `{stdout, stderr, interrupted, isImage, noOutputExpected}`. It has **no `exitCode`** and no `success`. The post hook scans `.stdout` and `.stderr`, the fields Claude Code sends. It does not send `success` in its audit record for these tools, since the host did not say how the tool ended.
- A NotebookEdit `tool_input` is `{notebook_path, cell_id, new_source}`, and its `tool_response` repeats `new_source` beside `old_source` and the whole file before and after. The hooks read `new_source`; before this capture they read `cell_content` and `content`, which Claude Code does not send, so a notebook edit was never checked.
- A Write `tool_input` is `{file_path, content}`; an Edit `tool_input` is `{file_path, old_string, new_string, replace_all}`. The hooks read `content` and `new_string`.
- Every payload carries `session_id`, `transcript_path`, `cwd`, `scratchpad_dir`, `prompt_id`, `permission_mode`, `effort`, `hook_event_name`, `tool_name`, `tool_input` and `tool_use_id`; PostToolUse adds `tool_response`.

## What the user sees: systemMessage versus stderr

In the same kind of session, with the agent unreachable, the pre hook's `GOVERNANCE UNAVAILABLE` notice was shown on screen as `PreToolUse:Bash says: [AxonFlow] GOVERNANCE UNAVAILABLE: ...` when the hook put it in the hook JSON's `systemMessage`. With the same hook changed only to print the notice on stderr (exit 0), nothing appeared between the hook's progress line and the tool's output. That is why every notice in these hooks goes in `systemMessage`.
