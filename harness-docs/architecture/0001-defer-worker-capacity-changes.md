# Defer worker-capacity changes

**Decided:** 2026-04-25.
**Status:** Not pursuing any of the options below for now. Manual plan resizing on Render is the chosen path when more or less capacity is needed.

## Context

Symphony runs as a single Render web service with a persistent disk holding Postgres, agent workspaces, codex auth, and a token-totals file. Concurrency is bounded by what one Render box can handle (currently `pro_plus` / 8 GB / 4 CPU; OOMs above 5 concurrent codex sessions on smaller plans). Two motivations were considered for changing this:

1. Add a laptop as an opportunistic extra worker when it happens to be online.
2. Adapt to a bursty workload that needs high parallelism sometimes and almost nothing overnight.

After working through the options, neither motivation justified the complexity any of the candidate solutions would add. Manually changing the Render plan size when a burst is expected — and reverting later — is sufficient. The simplicity of "one box, in-memory state, Linear is the source of truth" is Symphony's largest reliability asset and is not being traded away without a forcing reason.

## Options considered

### Laptop as opportunistic worker

Three sub-variants were evaluated. All shared a common drawback: the laptop is opportunistic by design ("bonus when present"), so the extra capacity it provides is unreliable. That tradeoff would be fine if the implementation were free, but every variant carried real ongoing cost.

**A. SSH push from Render to laptop, with Tailscale (or similar) for reachability.**
Reuses the existing `worker.ssh_hosts` machinery, which is designed for stable always-on workers (e.g., dedicated build hosts on a private network), not for a laptop that comes and goes. To work for a sometimes-online host, it needs a small liveness check (~20 LOC) so dispatch doesn't waste retries on an offline laptop. Smallest code change of any variant. Operational cost: enable macOS Remote Login, run a tunnel daemon (Tailscale, Cloudflare Tunnel, etc.). Security cost: a Render compromise gives the attacker a direct shell on the laptop.

**B. HTTP `/sync` polling: laptop initiates, Render assigns work in the response.**
Laptop runs Symphony in a new `--worker` mode, polls a single HTTP endpoint every ~10s, runs `AgentRunner` locally for any new assignments, and writes progress directly to Linear. No Tailscale or sshd. Larger architectural deviation: introduces "remote workers" as a top-level Symphony concept with its own state shape and lease tracking, which Symphony does not have today. A Render compromise could still reach the laptop via malicious assignment payloads, but the codex sandbox + devcontainer mounts bound the blast radius compared to direct SSH.

**C. WebSocket / Phoenix Channels.**
Same idea as `/sync` but with a persistent connection. No meaningful benefit over HTTP polling for ticket-level work, since `AgentRunner` already writes events to Linear and the orchestrator does not need real-time event streaming back from the laptop. Strictly more code than B.

### Autoscaling on Render

**D. Scheduled vertical resize.**
A small script calls Render's API to change the plan size on a schedule (e.g., bump up at 9 AM, drop at 6 PM). Architecture unchanged. Plan change triggers a service restart (~60-90s) and kills in-flight agents — they re-dispatch from Linear after restart, which is the same behavior as any deploy. Bounded savings (maybe 30-40% over running the larger plan 24/7). The user's call is that the savings do not justify the additional moving piece.

**E. Reactive resize based on Linear queue depth.**
Same as D, but driven by queue size rather than the clock. Marginally more complex. Useful only if bursts are unpredictable rather than diurnal — same conclusion as D, plus extra logic.

**F. Real horizontal autoscaling.**
Move Postgres to managed (Neon or Render Postgres), make workspaces ephemeral, drop the persistent disk, then enable Render's instance-count autoscaling. Substantial refactor: introduces multi-orchestrator state coordination (which instance claims a ticket?), ticket-claim races, workspace re-clone overhead per dispatch, and a new managed Postgres dependency. Right answer for a fleet; overkill for one operator.

### Off-Render compute

**G. Per-agent ephemeral compute** (Modal, Vercel Sandbox, Fly Machines, etc.).
Theoretically the cleanest fit for bursty workloads with pay-per-use pricing. Not pursued because of the integration work required to dispatch agents across a different runtime.

## Why none of these were chosen

- **Cost savings** (D, E) do not justify a new automated piece in the system, even a small one. Manual plan changes are good enough.
- **Laptop capacity** (A, B, C) is fundamentally unreliable, and every variant either adds an ops dependency (tunnel daemon, sshd) or a new architectural concept (remote workers, leases, reconnection logic). The expected value of the extra capacity does not clear that bar.
- **Real autoscaling** (F) requires giving up the single-orchestrator model that keeps the rest of the system simple. The same simplicity properties that make Symphony reliable today would have to be re-earned through distributed coordination logic.
- **Off-Render compute** (G) is a meaningful refactor that would only pay off at scales Symphony does not currently operate at.

## How to handle bursts in the meantime

Use the Render dashboard (or `render` CLI / API) to bump the service's plan size up before an expected burst, then bump it back down. Plan changes restart the service, but the orchestrator cleanly re-dispatches from Linear on boot, so in-flight tickets resume with at most one wasted codex turn each.

## Triggers to revisit this decision

Pick one of the deferred options back up if any of the following become true:

- **The single instance becomes unreliable** (frequent OOMs the larger plan cannot absorb, crash loops, hung state that restarts cannot recover): real horizontal autoscaling (F) becomes worth the refactor.
- **Costs become meaningful relative to value**: scheduled vertical resize (D) is the cheapest first step.
- **A second person regularly contributes parallel capacity** from their own machine: HTTP `/sync` (B) is the right starting point — works on any network without VPN setup, and the codex-sandbox-plus-bounded-credentials security model is friendlier than SSH push (A).
- **Tickets routinely need a machine larger than Render economically provides**: a dedicated worker box, laptop or otherwise, makes sense — start from B for the same security reason.

## Status of `worker.ssh_hosts`

The config field exists and works, but it is designed for stable, always-on SSH workers (e.g., dedicated build hosts on a private network). It is not appropriate for sometimes-online laptops without the additional liveness check described in option A. Leave it as-is for the use case it was built for.
