---
name: agent-shell-orchestrator
description: Coordinate native Emacs agent-shell sessions when asked to create workers, communicate with existing shells, or inspect progress.
---

Any ordinary shell can coordinate others and continue its own work. Use the [API reference](references/api.md) for function calls.

## Scope and ownership

- Select the requested project or exact shells. Checking progress does not authorize assigning work, creating workers, or clearing queues. Listing sessions does not make them messaging targets.
- Inspect existing work before changing assignments. Reuse a suitable worker when appropriate; do not create extra controllers or worker trees by default.
- Assign a coherent outcome to each worker and one owner for shared files. Issue claims alone do not prevent overlapping work. Keep shared setup and integration with the coordinator unless delegated.

## Communication

- Search the listed `:transcript-file` with `rg` and inspect pending prompts before messaging. Send only information or actions the recipient needs; avoid broadcasts, duplicate reminders, and routine status prompts.
- With shared issues, send the issue ID, scope, acceptance criteria, and missing context. Otherwise, provide enough context to work independently. Use the project's tracker; do not introduce another task store.
- Queue by default. Steer when ongoing work needs to change; steering can interrupt it. Delivery is not acknowledgement, and idle is not completion. Verify output and results.
- Remove only messages covered by the requested cleanup, using the current queue. Quiet or blocked sessions do not justify silently restarting or reassigning work.

## Status checks

For a one-time check, inspect transcripts and project state; report progress, completion evidence, blockers, and needed decisions. Ask workers only about material gaps.

Periodic polling is outside this package’s scope. Do not start timers, polling loops, or queued self-reminders. Report permission or budget blockers without bypassing them.

The package handles session operations. This skill guides coordination; the user and project instructions define authority and task ownership. Persistent identity, supervision records, and restart recovery are not implemented.
