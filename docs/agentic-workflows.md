# Agentic Workflows: Copilot Demo Automation

> How the repository turns newly shipped GitHub Copilot features into demo-site guides
> automatically — and the hard-won rules for building **GitHub Agentic Workflows (gh-aw)** that
> collaborate with the Copilot coding agent without a human clicking "Approve and run".

Use this as the reference when creating or changing any agentic workflow in this repo.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Workflow Inventory](#workflow-inventory)
- [End-to-End Flow](#end-to-end-flow)
- [The Approval-Gate Problem (read this first)](#the-approval-gate-problem-read-this-first)
- [Key Mechanisms & Gotchas](#key-mechanisms--gotchas)
- [Design Decisions & Trade-offs](#design-decisions--trade-offs)
- [Setup / Reproduction Checklist](#setup--reproduction-checklist)
- [Troubleshooting](#troubleshooting)
- [Files & Where Things Live](#files--where-things-live)
- [Lessons for Future Agentic Workflows](#lessons-for-future-agentic-workflows)

---

## Overview

Every Wednesday a scheduled agent scans the GitHub Changelog `copilot` tag, decides which newly
shipped features are worth a **hands-on demo**, and delegates building each one to the **Copilot
coding agent**. From there everything is trigger-based and hands-off up to human review: the demo PR
is auto-labeled, un-drafted the moment the agent finishes, assigned to the maintainer, and reviewed
by Copilot code review. The maintainer just reviews and merges.

**What it deliberately does _not_ do:** there is no automated review→fix loop. GitHub gates any
workflow that reacts to a pull-request _review_ on a coding-agent PR (see
[the gate problem](#the-approval-gate-problem-read-this-first)), so we hand the reviewed PR to a
human instead of trying to auto-fix.

---

## Architecture

```mermaid
flowchart LR
  A["Scout<br/>gh-aw · cron Wed 08:00 UTC"] -->|"create-issue<br/>assignees: copilot"| B["Coding agent<br/>copilot-swe-agent"]
  B -->|"builds demo + prettier<br/>opens DRAFT PR, pushes"| C{"Autopilot labeler<br/>plain Actions · on agent push"}
  C -->|"label · wait for copilot_work_finished<br/>· un-draft (PAT) · assign edinc"| D["Copilot code review<br/>(automatic)"]
  D --> E["👤 Maintainer<br/>reviews & merges"]

  classDef ok fill:#eaffea,stroke:#2a2;
  class A,B,C,D ok;
```

The single most important property: **only the coding agent's _pushes_ trigger workflows without an
approval gate.** Everything in the automated path is reachable from a push; anything that would have
to react to a _review_ is not (and was removed).

---

## Workflow Inventory

| Workflow | File | Kind | Trigger | Purpose |
|---|---|---|---|---|
| **Demo Scout** | `.github/workflows/copilot-demo-scout.md` (+`.lock.yml`) | gh-aw (engine `copilot`, model `claude-sonnet-4.5`) | `schedule: "0 8 * * 3"` + `workflow_dispatch` | Scan changelog, judge demo-fit, file a build brief per feature and delegate to the coding agent. |
| **Demo PR Autopilot** | `.github/workflows/copilot-demo-label.yml` | plain GitHub Actions | `pull_request` `[opened, reopened, edited, synchronize, review_requested]` | Label the PR, wait for the agent to finish, un-draft it, and assign the maintainer. |

> A third workflow, `copilot-demo-review-loop.md` (event-triggered on `pull_request_review`), was
> **removed** — it was permanently gated (`action_required`). See below.

---

## End-to-End Flow

1. **Scout runs** (Wednesday, or `gh workflow run copilot-demo-scout.lock.yml`). It fetches the
   changelog RSS (`https://github.blog/changelog/label/copilot/feed/`), keeps items from the last 14
   days, judges which are demoable, and emits `create-issue` safe-outputs (`max: 3`,
   `deduplicate-by-title`) labeled `demo-candidate, automated-demo` and **assigned to `copilot`**.
   The brief instructs the agent to add `demo-site/src/content/docs/demos/NN-slug.mdx`, follow the
   existing demo conventions, **run Prettier**, and put `Fixes #<issue>` in the PR body.
2. **The coding agent builds** the demo on a `copilot/…` branch and opens a **draft** PR. While
   working it fires a `copilot_work_started` timeline event; when done it fires
   `copilot_work_finished` and drops the `[WIP]` title.
3. **The autopilot labeler fires on the agent's push** (ungated). It confirms the PR is authored by
   the coding agent, adds the `automated-demo` label, then **polls the PR timeline** until the newest
   `copilot_work_*` event is `copilot_work_finished`.
4. **It un-drafts the PR** (`gh pr ready`, using the user PAT) and **assigns `edinc`**.
5. **Copilot code review runs automatically** on the now-ready PR (repo ruleset auto-requests it).
6. **The maintainer is notified** as the PR assignee when the review posts, and reviews / merges (or
   re-runs the coding agent to address feedback).

---

## The Approval-Gate Problem (read this first)

By default, **GitHub holds every Actions workflow triggered by a Copilot coding-agent pull request
for manual approval** ("Approve and run", status `action_required`). This is the biggest obstacle to
a hands-off pipeline and is **not** the same as the fork / first-time-contributor gate.

### The setting that removes it

**Repository** → Settings → Code & automation → **Copilot → Cloud agent → "Actions workflow
approval"** → turn **OFF** "Require approval for workflow runs". Also keep **"Allow automations" ON**.

- This is a **repo-level** setting and requires repo admin.
- It is _separate_ from Settings → Actions → General and from org Policies "Restrict actors" — those
  do **not** fix this gate.
- Set it on the **canonical** repo (`codecurrent-sandbox/octo-eshop-demo`); the `edinc/…` remote is a
  redirect and settings writes don't follow redirects.

### The critical limitation (why there's no fix loop)

GitHub's own wording: *"workflows run automatically when Copilot **pushes**, except when the push
comes from an automation."* Consequences we verified live:

- ✅ **Push-triggered** workflows on the agent's PR now run automatically (the autopilot labeler on
  `synchronize`/`opened`, and CI).
- ❌ **Review-triggered** workflows (`pull_request_review`) stay **gated** — a review is not a push.
  There is **no un-gated event** that fires _after_ Copilot code review. Reacting to a review is
  therefore only possible via a **scheduled poller** or a **manual approval click**.
- ⚠️ A commit **pushed by one of our workflows** counts as "an automation" and will _not_ itself
  trigger further workflow runs.

This is why the review→fix loop and a "review is done" hand-off comment were dropped: both would have
to react to the review event, which cannot be a no-click trigger.

---

## Key Mechanisms & Gotchas

| Topic | What to know |
|---|---|
| **Delegating to the coding agent** | Assign an issue/PR to the bot `copilot-swe-agent` (node id `BOT_kgDOC9w8XQ`). gh-aw does this with `create-issue { assignees: [copilot] }`; to do it by hand use the GraphQL `replaceActorsForAssignable` mutation. |
| **You need a user PAT, not `GITHUB_TOKEN`** | The default Actions `GITHUB_TOKEN` **cannot trigger the coding agent** and **cannot `markPullRequestReadyForReview`** ("Resource not accessible by integration"). Store a user PAT as the secret **`GH_AW_AGENT_TOKEN`** and use it for delegation _and_ for `gh pr ready`. |
| **"Agent is done" signal** | The PR timeline carries `copilot_work_started` / `copilot_work_finished` events. The agent is finished when the **newest** `copilot_work_*` event is `copilot_work_finished`. Don't rely on the `[WIP]` title alone. |
| **The done-event can lag the push** | `copilot_work_finished` can be recorded a few seconds after the push/rename that triggers your workflow. The autopilot **polls** the timeline briefly (and also triggers on `review_requested`, which fires at finish) so it never un-drafts mid-build. |
| **`pull_request` uses the PR _head_ branch's workflow** | A `pull_request`-triggered workflow runs the version of the workflow file on the **PR branch**, not `main`. Commit workflow changes to `main` **before** the agent branches a new PR, or they won't apply to in-flight PRs. |
| **CI gates tests behind lint** | `ci.yml`'s `Build & Test` job has `needs: lint`. The `Lint & Format` job runs `prettier --check .`. If the agent emits an unformatted file, lint fails → **all test jobs are skipped** → the summary shows "Total tests: 0". Fix: the scout brief **requires the agent to `prettier --write`** its output. |
| **Canonical repo & redirects** | The repo is org-owned as `codecurrent-sandbox/octo-eshop-demo`; `edinc/octo-eshop-demo` redirects. `GET` follows redirects, but **`POST`/`PUT`/`gh workflow run` do not** — always pass `-R codecurrent-sandbox/octo-eshop-demo` for writes. |
| **gh-aw compile model** | The markdown **body is read from the `.md` at runtime**; the compiled `.lock.yml` stores content hashes (a `frontmatter_hash` + `body_hash`) in its metadata header, not the body text. After editing a `.md`, run `gh aw compile <name>` and **commit both** the `.md` and `.lock.yml` (an "activation" step checks the lock matches). |
| **Concurrency cancellations are normal** | With `cancel-in-progress: false`, when several PR events queue in the same concurrency group GitHub keeps the in-progress run + the latest pending one and **cancels intermediate pending runs**. Those `cancelled` entries are expected; the completing run still does the work (steps are idempotent). |
| **Bot login is inconsistent** | The agent's author appears as `app/copilot-swe-agent` via the API but differently in raw webhook payloads. Scope by resolving the author with `gh pr view --json author` and matching loosely (`*copilot*`/`*swe-agent*`) rather than an exact `if:` on `pull_request.user.login`. |
| **Draft PRs aren't reviewed** | The ruleset has `review_draft_pull_requests: false`, so Copilot won't review a draft. Un-drafting is what kicks off review — hence the autopilot's core job. |

---

## Design Decisions & Trade-offs

- **No automated fix loop.** Reacting to Copilot's review is gated (see above). The coding agent also
  self-reviews during its build (repo "validation tools" setting), so demos arrive fairly clean. We
  hand the reviewed PR to a human instead.
- **Hand-off = assignment, not a comment.** Assigning `edinc` at un-draft time makes GitHub notify
  them of PR activity — including when the review posts — so the "findings are in" signal arrives with
  the findings, no gated review-trigger required. (A review-timed _comment_ would need a scheduled
  poster or a click.)
- **Scout is the only schedule.** Everything after it is trigger-based. A review-timed action is the
  one thing that fundamentally cannot be a no-click trigger — it's schedule-or-click by nature.
- **Engine model pinned to `claude-sonnet-4.5`.** The default/other models 400'd on this
  subscription. Copilot Opus 4.8 is not available to any GitHub cloud agent (coding-agent picker caps
  at Opus 4.7).

---

## Setup / Reproduction Checklist

Repo admin, one-time:

- [ ] **Secret `GH_AW_AGENT_TOKEN`** — a user PAT (Copilot-licensed) with `repo` scope. Used to
      delegate to the coding agent and to un-draft PRs.
- [ ] **Copilot → Cloud agent → "Require approval for workflow runs" = OFF**, **"Allow automations" =
      ON** (repo Settings, on the canonical repo).
- [ ] **Copilot coding agent** enabled; **Copilot code review** auto-requested via a branch ruleset on
      the default branch (with `review_draft_pull_requests` left `false`).
- [ ] **Labels** `demo-candidate` and `automated-demo` exist (the labeler force-creates
      `automated-demo` if missing).
- [ ] **Actions** permitted to create PRs / run.
- [ ] Local tooling: `gh extension install github/gh-aw`; `gh auth refresh -s read:org`.

Author / change a workflow:

- [ ] Edit the `.md`, run `gh aw compile <name>`, commit **both** `.md` and `.lock.yml`.
- [ ] For `pull_request`-triggered plain-Actions workflows, remember the PR-head-branch rule.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| CI comment: **"Some tests failed / Total tests: 0"** | `Lint & Format` (Prettier) failed on an agent file; `Build & Test` (`needs: lint`) was **skipped**. | Ensure the agent formats its output (`prettier --write`). Confirm in the run: `Build & Test` shows `skipped`, `Lint & Format` shows `failure`. |
| Workflow stuck at **`action_required`** | The Copilot approval gate. | Turn OFF "Require approval for workflow runs" (repo → Copilot → Cloud agent). Note review-triggered workflows stay gated regardless. |
| PR built but **never un-drafts** | Either `gh pr ready` used `GITHUB_TOKEN` (403 `markPullRequestReadyForReview`), or the done-signal wasn't seen. | Use `GH_AW_AGENT_TOKEN`; confirm the timeline shows `copilot_work_finished`. |
| Scout runs but **creates no issues** | `deduplicate-by-title` matched an existing (even closed) issue, or nothing in the 14-day window was demoable (a `[aw] No-Op Runs` issue is filed). | Expected steady-state; seed a demo manually by creating an issue and assigning `copilot-swe-agent` if you need to test downstream. |
| `gh workflow run` / API write hits the wrong repo | Redirect from `edinc/…` isn't followed for writes. | Always `-R codecurrent-sandbox/octo-eshop-demo`. |
| Workflow change didn't take effect on an existing PR | `pull_request` uses the PR-branch copy of the workflow. | Land the change on `main` before new PRs branch; or update the existing PR's branch. |

---

## Files & Where Things Live

```
.github/workflows/
  copilot-demo-scout.md        # gh-aw scout (source of truth)
  copilot-demo-scout.lock.yml  # compiled — commit alongside the .md
  copilot-demo-label.yml       # plain-Actions "Demo PR autopilot"
.github/aw/
  actions-lock.json            # gh-aw action pins (tracked)
  logs/                        # gh-aw run logs (gitignored)
docs/
  agentic-workflows.md         # this document
```

---

## Lessons for Future Agentic Workflows

1. **Classify your trigger.** On a coding-agent PR, ask "does this react to a _push_ or to a
   _review_?" Push-triggered can be no-click; review-triggered cannot.
2. **Prefer plain deterministic Actions** for mechanical steps (labeling, un-drafting, assigning).
   Reserve the AI engine (gh-aw) for genuine judgement (the scout's demo-fit decision).
3. **Use the timeline, not titles, for lifecycle state** (`copilot_work_finished`).
4. **Give the workflow the right token.** The Actions `GITHUB_TOKEN` can't trigger the agent or
   un-draft; a user PAT can.
5. **Make the agent satisfy your CI**, don't fight it downstream — e.g. tell it to run the formatter,
   rather than reformatting after the fact.
6. **A review-completion action is schedule-or-click.** Decide up front whether that's worth a poller,
   a click, or (as here) leaning on GitHub's native assignee notifications.
