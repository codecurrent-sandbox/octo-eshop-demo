---
name: Copilot Demo Review Loop
description: >-
  When Copilot code review comments on an automated demo PR, apply the fixes and loop
  until the review is clean, then hand the PR to the maintainer.
on:
  pull_request_review:
    types: [submitted]

# Only ever run for a Copilot code review on an automated-demo PR. Every other PR review
# in the repo is ignored before the agent even starts.
if: >-
  ${{ github.event.review.user.login == 'copilot-pull-request-reviewer[bot]'
      && contains(github.event.pull_request.labels.*.name, 'automated-demo') }}

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
  push-to-pull-request-branch:
    target: "triggering"
    if-no-changes: "ignore"
    allowed-files:
      - "demo-site/**"
  assign-to-user:
    allowed: [edinc]
    target: "triggering"
  add-comment:
    target: "triggering"
    max: 1
---

# Copilot Demo Review Loop

A **Copilot code review** was just submitted on an **automated demo pull request**. Resolve
the reviewer's feedback so the PR converges, then hand it to the maintainer when it's clean.

## Guard — confirm this is one of ours

Proceed only if BOTH hold:

- The review author is `copilot-pull-request-reviewer[bot]`.
- This PR is an automated demo PR: it carries the `automated-demo` label **and** its
  closing/linked issue carries the `demo-candidate` label (use the GitHub tools to inspect
  the PR's closing issue references).

If either is false, do nothing at all — no comment, no push.

## Loop guard

Inspect the PR's commit history and this workflow's prior comments. If fixes have already
been pushed in **5 or more prior rounds**, stop looping: post one short comment saying the
PR needs human attention, assign it to `edinc`, and finish.

## Assess the review

Read the submitted review body, its inline comments, and the PR diff. Decide whether there
are **actionable change requests** — concrete problems to fix (a broken build, invalid MDX
or frontmatter, wrong demo conventions, factual errors, security/accessibility issues) — as
opposed to praise or purely informational notes.

## If there ARE actionable comments

- Make the **minimal** edits needed to address them, staying strictly within `demo-site/**`.
- Keep the demo consistent with existing conventions; ensure MDX and frontmatter stay valid
  and the site would still build.
- Push your edits with `push-to-pull-request-branch` (this triggers an automatic re-review,
  continuing the loop).
- Post one short comment summarizing what you changed.

## If there are NO actionable comments (review is clean)

- Assign the PR to `edinc` via `assign-to-user`.
- Post one short comment: the demo passed automated review and is ready for human review.
