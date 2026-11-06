# API

Install this skill directory, including `references`, separately from the Emacs package. Requires Emacs 29.1 and agent-shell 0.87.10+.

Call the Emacs server hosting the sessions:

```sh
emacsclient --eval '(require (quote agent-shell-orchestrator))'
```

If loading fails, install the package or add it to that Emacs instance's `load-path`. For current details, query `(documentation 'agent-shell-orchestrator-send)` or `(help-function-arglist 'agent-shell-orchestrator-send t)` through `emacsclient --eval`.

Use exact buffer names or buffer objects as targets. Pass absolute project directories; Emacs's current directory may differ from yours.

All names below have the prefix `agent-shell-orchestrator-`. Results are plists unless stated otherwise.

| Function | Arguments | Result |
| --- | --- | --- |
| `list` | `&key project buffers` | Sessions: `:buffer`, `:name`, `:directory`, `:status`, `:queued`, `:transcript-file`. No filters lists all; both filters intersect. |
| `create` | `directory &key name prompt config` | New buffer, without selecting it. Name must be unused; prompt waits for startup. Config defaults to the preferred native agent. |
| `send` | `target message &key (delivery 'queue)` | `:buffer`, `:delivery` (`submitted`, `queued`, `steered`), `:queued`. Busy steering requires native support; starting shells cannot be steered. |
| `queue` | `target` | Pending prompts in order. |
| `remove-queued` | `target index` | Removed prompt; index is zero-based in the current queue. |

Pass these Elisp forms to `emacsclient --eval`:

```elisp
(agent-shell-orchestrator-list :project "/absolute/project/")
(agent-shell-orchestrator-queue "worker")
(agent-shell-orchestrator-send "worker" "Issue proj-123: own the importer.")

```

Search each session's `:transcript-file` with `rg` or `tail` for its subject and progress. A nil path means no transcript is available; a non-nil path may not exist until the first entry is written. Listing sessions does not create transcript files.

Native queue merging applies. Busy queue delivery in 0.87.10 trims surrounding draft whitespace. Queue indexes can change between calls. Delivery results do not establish ownership or acknowledgement.
