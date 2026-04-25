---
name: close-with-verification
description: |
  Discipline for closing Linear tickets I (Claude) implemented myself,
  especially `infra`-labeled tickets that the Codex agent can't act on.
  Document the verification approach in a comment before transitioning to
  Done — empty close = no traceability.
---

# Closing tickets with verification

When I implement a Linear ticket myself (Codex couldn't act on it — typically `infra`-labeled work in `symphony-harness`, Render config, Vercel/Neon dashboards), the close-out is incomplete without a comment that documents how the work was verified. Empty close = no traceability for future me, the user, or another agent picking up adjacent work.

## What to put in the comment

Three sections, in order:

1. **What I did.** Concrete bullet list with file paths, key commits, and configs touched. Be specific enough that someone reconstructing the change six months later can find the diff.
2. **How I verified it works.** For infra changes, the strongest signal is a server-side-verifiable artifact — uploaded screenshot + psql/curl output, like NTHPMV-49 produced for NTHPMV-36; or the Playwright proof in NTHPMV-41. Reference the verification ticket if I filed one. For non-infra work I rarely close myself, but if I do, link the test output or the PR's CI green.
3. **What's still on the user / human side.** Any dashboard tweaks, secret rotations, or follow-ups that aren't done yet.

## When to file a paired dogfood ticket

For `infra`-labeled tickets that are load-bearing (a primary system depends on them working end-to-end), file a separate dogfood ticket in the same shape as NTHPMV-41 (Playwright) / NTHPMV-49 (Postgres):

- **Required procedure** spelled out so the agent can execute deterministically
- **Server-side-verifiable proof** — file uploads with magic bytes, dimensions, byte counts; query results with row counts and content hashes
- **Guardrails** that prevent fabrication (e.g. "do not use the in-memory fallback to fake the test")

That gives Codex a way to produce evidence I can verify, which is stronger than my own boot-time diagnostic alone — it exercises the same code path the user-facing flow does.

## Example

NTHPMV-36 (local Postgres harness) was closed with [this comment](https://linear.app/surge/issue/NTHPMV-36) referencing NTHPMV-49 as the dogfood proof — the agent uploaded a 1280×2229 PNG of the local dev server's market page (proves the chain) and a TXT file with the verbatim `psql` query showing 819 ticks in `market_history_cache` (proves the write path actually wrote).
