---
name: Copilot Demo Scout
description: >-
  Weekly scan of the GitHub Changelog (copilot tag). Demo-worthy features become
  demo-site guides, built by the Copilot coding agent.
on:
  schedule:
    - cron: "0 8 * * 3" # Wednesdays 08:00 UTC
  workflow_dispatch:

engine: copilot

permissions:
  contents: read
  issues: read
  copilot-requests: write

timeout-minutes: 20

network:
  allowed:
    - defaults
    - github
    - github.blog

tools:
  web-fetch: {}
  github:
    mode: gh-proxy
    toolsets: [issues]

safe-outputs:
  create-issue:
    title-prefix: "[demo-candidate] "
    labels: [demo-candidate, automated-demo]
    assignees: [copilot]
    max: 3
    deduplicate-by-title: true
---

# Copilot Demo Scout

You find newly shipped **Copilot** features in the GitHub Changelog and turn the
demo-worthy ones into new demos on the octo-eshop **demo site**. You do not write the
demo yourself — you file a precise build brief and let the Copilot coding agent build it
(each issue you create is auto-assigned to `copilot`).

## 1. Fetch the changelog

Use the `web-fetch` tool to retrieve the Copilot-tagged changelog RSS feed:

`https://github.blog/changelog/label/copilot/feed/`

Parse the `<item>` entries. For each, capture `title`, `link`, `pubDate`, and the
`description` / `content:encoded` summary.

## 2. Keep only what's new

Consider **only** items whose `pubDate` is within the **last 7 days** (this workflow runs
weekly, so that window is the fresh set). Ignore everything older.

## 3. Judge demo-fit

The demo site (`demo-site/`) is a set of **hands-on Copilot demo guides** set in a bicycle
e-commerce microservices app. Existing demos live in
`demo-site/src/content/docs/demos/` (currently `01`–`08`: plan agent, agents HQ, coding
agent, review agent, custom agents, custom skills, Copilot CLI, code quality).

A changelog item is a **good candidate** only if it introduces a **user-facing,
demonstrable Copilot capability** a presenter could show live (a new agent, a review or
chat capability, a CLI feature, a skill, etc.).

**Skip** items that are not demoable: GA/enterprise-billing/admin/pricing announcements,
deprecations, pure backend/infra changes, or anything without a hands-on story. Also skip
anything that clearly duplicates an existing demo above. If nothing qualifies, create no
issues and stop.

## 4. File a build brief per good candidate (max 3)

For each good candidate, emit a `create-issue`. The issue is a **build brief for the
Copilot coding agent**, so it must be detailed and self-contained. Use:

- **Title:** `Demo: <feature name>` — concise and unique (used for de-duplication).
- **Body:** instruct the agent to:
  - Add a new demo page `demo-site/src/content/docs/demos/NN-slug.mdx`, where `NN` is the
    next unused two-digit order (existing demos end at `08`; use `09`, then `10`, …) and
    `slug` is a short kebab-case name.
  - **Copy the conventions** of an existing demo — point them at
    `demo-site/src/content/docs/demos/04-review-agent.mdx` as the template.
  - Use the frontmatter schema from `demo-site/src/content.config.ts`: `title`,
    `description`, `category: Demos`, `order: <NN>`, `capability`, `duration` (e.g.
    `"2 min"`), `difficulty` (`Starter` | `Core` | `Intermediate` | `Advanced`), `icon` (a
    lucide icon name), `summary`.
  - Mirror the body structure of the other demos: `## What This Demonstrates`,
    `## Prerequisites`, `## Prompts` (a `Prompt A`, optionally `Prompt B`, each in a
    ```text``` fence), one or more `<Aside type="tip" title="…">…</Aside>` callouts, and a
    `**What to look for:**` list.
  - Ground every prompt in this repo's e-commerce microservices context (the `services/`
    and `demo-site/` code) so the demo is concrete, not generic.
  - If `demo-site/src/components/home/DemoGrid.astro` hardcodes a demo count in its heading
    (e.g. "Eight demos"), update it to the new total.
  - Keep the change scoped to `demo-site/**` only.
  - **Acceptance criteria:** `cd demo-site && npm ci && npm run build` succeeds, and the new
    demo shows up in the home grid and the left navigation.
  - Include the source changelog link: `<link>`, and a one-line summary of the feature.

Write a genuinely useful, feature-specific brief — not a generic template restatement.
