# Operating rules when Claude Code runs in this dir

## Do not write implementation code for the target project

The target project (`~/code/nth-prediction-market-viewer`) is maintained by
Symphony + Codex through the Linear workflow. Claude Code's job in this
harness repo, and when helping operate Symphony, is **orchestration only**:

- Manage Linear tickets (create, update scope, set blocks, close, transition).
- Manage the harness itself (`.devcontainer/`, `start.sh`, Dockerfile, etc.).
- Merge PRs, verify runtime, diagnose blockers, restart the harness.
- Read the target repo to understand state, but do **not** edit app code,
  product copy, tests, or configuration there.

If a gap is found in the target project (missing tests, copy polish, feature
work, bug fix, refactor), file or refine a Linear ticket describing it and
let Symphony route it to a Codex agent. Do not "just fix it" in-line.

Exceptions are narrow and always confirm first:
- `WORKFLOW.md` and `.codex/skills/*` in the target repo are Symphony-facing
  config, not product code — editing them to change orchestration behavior is
  fair game.
- Urgent unblockers the user explicitly asks Claude Code to patch (e.g.,
  "open this PR for me", "commit this spec file I pasted").

## When creating Linear tickets

Every ticket Claude Code files must stand alone as a reviewer artifact, not
just an agent prompt. Always include:

- Exact URL(s) and step-by-step repro under a `### How to reproduce` heading.
- A mirror-image `### How to verify the fix` section — the reviewer and the
  agent must be looking at the same target behavior.
- An inline screenshot (uploaded via Linear's `fileUpload` mutation and
  embedded as `![caption](assetUrl)`) for any visual bug. The file-upload
  quirk — `Content-Type` must be sent on the PUT even though Linear's
  response headers omit it — is documented in the `linear` SKILL.md in the
  target repo. Reuse that flow.

The same rule applies to follow-up tickets Codex files from inside a session;
it's codified in the `linear` skill so future agents inherit the pattern.
