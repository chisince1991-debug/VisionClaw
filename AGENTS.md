# Agent Coordination

- GitHub issues and pull requests are the source of truth for task state.
- Use Koi only for durable project summaries, preferences, and handoff context.
- Use branch prefixes `codex/*` and `claude/*` to show which agent is acting.
- Label ownership with `agent:codex` or `agent:claude`; use `blocked:louis` when Louis must decide.
- Do not start implementation until the issue has acceptance criteria or a clear PR checklist.
- Keep implementation PRs small enough for the other agent to review.
- After major progress, add a short status note to the coordination issue.
