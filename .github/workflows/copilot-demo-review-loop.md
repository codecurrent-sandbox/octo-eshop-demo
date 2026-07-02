---
name: Copilot Demo Review Loop
description: >-
  When Copilot code review comments on an automated demo PR, apply the fixes and loop
  until the review is clean, then hand the PR to the maintainer.
on:
  pull_request_review:
    types: [submitted]

# Cheap native gate: only run for a Copilot code review, and never once this PR has been
# marked exhausted (the mechanical stop for the fix loop). The "is this an automated demo
# PR?" decision is made at runtime (below) so it can't be defeated by label-timing races.
if: >-
  ${{ github.event.review.user.login == 'copilot-pull-request-reviewer[bot]'
      && !contains(github.event.pull_request.labels.*.name, 'demo-review-exhausted') }}

engine: copilot

permissions:
  contents: read
  pull-requests: read
  issues: read
  copilot-requests: write

timeout-minutes: 20

# Work on top of the PR head so edits + the pushed patch are correct.
checkout:
  ref: ${{ github.event.pull_request.head.ref }}
  fetch-depth: 0

tools:
  github:
    mode: gh-proxy
    toolsets: [default]
  edit: {}

safe-outputs:
  # Note: the compiled lock wires an OPTIONAL `GH_AW_CI_TRIGGER_TOKEN` secret into the push
  # job (gh-aw's "extra empty commit" mechanism to trigger CI on pushed commits). We leave it
  # UNSET on purpose — Copilot re-review after a fix push is handled by the branch ruleset's
  # "Review new pushes", not by a workflow, so no CI-trigger token is required. If unset, gh-aw
  # simply skips that step and pushes via GH_AW_GITHUB_TOKEN || GITHUB_TOKEN.
  push-to-pull-request-branch:
    target: "triggering"
    if-no-changes: "ignore"
    allowed-files:
      - "demo-site/**"
  add-labels:
    allowed: [automated-demo, demo-review-exhausted]
    max: 2
    target: "triggering"
  assign-to-user:
    allowed: [edinc]
    target: "triggering"
  add-comment:
    target: "triggering"
    max: 1
---

# Copilot Demo Review Loop

A **Copilot code review** was just submitted on a pull request. If (and only if) that PR is
one of the **automated demo PRs**, resolve the reviewer's feedback so the PR converges, then
hand it to the maintainer when it's clean.

## Step 1 — Confirm this is an automated demo PR (otherwise stop)

Do NOT assume it is. Establish it from evidence, using the GitHub tools:

- Find the issues this PR closes/links: check its `closingIssuesReferences`, and also scan
  the PR description for `Fixes #N` / `Closes #N` / `Resolves #N` references.
- Look up the labels on those linked issues.

Proceed **only if** a linked issue carries the `demo-candidate` label (the fingerprint of an
issue filed by the Copilot Demo Scout). As a secondary signal, the PR itself carrying the
`automated-demo` label also counts.

If none of that holds, this is not an automated demo PR: **do nothing at all** — no label,
no comment, no push — and stop.

Once confirmed, if the PR does not already carry the `automated-demo` label, add it (for
human visibility) via `add-labels`.

## Step 2 — Loop guard (mechanical stop)

Inspect the PR's commit history and this workflow's prior comments to count how many fix
rounds this automation has already pushed. If that count is **5 or more**:

- Add the `demo-review-exhausted` label via `add-labels` (this permanently stops this loop —
  future reviews on this PR are ignored by the workflow's trigger condition).
- Assign the PR to `edinc` and post one short comment explaining it needs human attention.
- Stop.

## Step 3 — Assess the review

Read the submitted review body, its inline comments, and the PR diff. Decide whether there
are **actionable change requests** — concrete problems to fix (a broken build, invalid MDX
or frontmatter, wrong demo conventions, factual errors, security/accessibility issues) — as
opposed to praise or purely informational notes.

## Step 4a — If there ARE actionable comments

- Make the **minimal** edits needed to address them, staying strictly within `demo-site/**`.
- Keep the demo consistent with existing conventions; ensure MDX and frontmatter stay valid
  and the site would still build.
- Push your edits with `push-to-pull-request-branch` (this triggers an automatic re-review,
  continuing the loop).
- Post one short comment summarizing what you changed.

## Step 4b — If there are NO actionable comments (review is clean)

- Assign the PR to `edinc` via `assign-to-user`.
- Post one short comment: the demo passed automated review and is ready for human review.
