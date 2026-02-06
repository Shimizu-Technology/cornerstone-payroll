# AI Development Workflow

A guide to building software with AI agents — the philosophy, patterns, and practical techniques for directing agents as a builder, not just a coder.

*Inspired by Peter Steinberger's approach to building with AI agents.*

---

## Table of Contents
1. [The Builder Role](#1-the-builder-role)
2. [Closing the Feedback Loop](#2-closing-the-feedback-loop)
3. [The Gate: One Command to Verify Everything](#3-the-gate-one-command-to-verify-everything)
4. [Parallel Agent Management](#4-parallel-agent-management)
5. [Prompt Design as a Skill](#5-prompt-design-as-a-skill)
6. [When to Intervene vs Let Agents Cook](#6-when-to-intervene-vs-let-agents-cook)
7. [Iterative Forward-Building](#7-iterative-forward-building)
8. [Designing Agent-Friendly Codebases](#8-designing-agent-friendly-codebases)
9. [Practical Templates](#9-practical-templates)
10. [Lessons Learned](#10-lessons-learned)

---

## 1. The Builder Role

### What Changes with AI Agents

You're no longer the person who types every line of code. You're the **architect, director, and quality gatekeeper** — the builder who shapes the product while agents handle implementation.

This is a fundamental shift:

| Traditional Dev | Builder with Agents |
|----------------|-------------------|
| Write code line by line | Describe what you want built |
| Debug by reading stack traces | Direct agents to investigate and fix |
| Context-switch between files | Coordinate multiple agents in parallel |
| Manually verify every change | Design systems that verify themselves |
| Quality = your typing skill | Quality = your architectural taste |

### What Builders Actually Do

1. **Architect systems** — Make decisions about structure, patterns, and data flow
2. **Direct agents** — Give clear context, review output, iterate
3. **Care about product feel** — The UX, the polish, the "does this feel right?"
4. **Design for verifiability** — Build codebases where agents can prove their work
5. **Make taste decisions** — When something is technically correct but doesn't feel right
6. **Maintain the vision** — Keep 10 agents pointed at the same north star

### The Mindset Shift

Stop thinking "how do I code this?" Start thinking:
- "How do I describe this so an agent builds it right?"
- "How do I structure this project so agents can verify their own work?"
- "What does 'done' look like, and how will I know when we're there?"

> **The Shimizu Way:** The best builders aren't the fastest coders — they're the clearest thinkers. If you can articulate what you want and design systems that verify it, the implementation speed is almost unlimited.

---

## 2. Closing the Feedback Loop

### THE Key Principle

If there's one idea in this entire guide, it's this: **close the feedback loop**.

An agent that writes code without verifying it creates work for you. An agent that writes code, tests it, verifies it, and reports results with evidence — that's the goal. The difference is whether the loop is open (agent → human must verify) or closed (agent → self-verify → human reviews verified work).

```
❌ Open Loop (slow, frustrating):
  Agent codes → "Here's the code!" → Human tests → Bugs found →
  Human reports bugs → Agent fixes → "Here's the fix!" → Human tests again → ...

✅ Closed Loop (fast, reliable):
  Agent codes → Agent runs gate → Gate fails → Agent fixes →
  Agent runs gate → Gate passes → Agent does visual QA →
  "Gate green, screenshots attached. Ready for review." →
  Human reviews verified work → Approve/iterate
```

### Why It's THE Principle

Everything else in this guide flows from closing the loop:

| Principle | How It Connects to the Loop |
|-----------|---------------------------|
| Gate scripts | The automated verification step that closes the loop |
| Visual QA | The visual verification step that catches what tests miss |
| Agent-friendly codebases | Easier to verify = easier to close the loop |
| Parallel agents | Each agent closes its own loop independently |
| Prompt design | Good prompts define what "verified" means |
| Forward-building | Iteration works because each step is verified |

### The Three Layers

```
Layer 1: Agent Gate (automated, seconds)
  ├── Tests pass (rspec, vitest)
  ├── Lint clean (rubocop, eslint)
  ├── Types check (tsc --noEmit)
  └── Build succeeds (npm run build)

Layer 2: Visual QA (real browser, minutes)
  ├── Pages load correctly
  ├── User flows work end-to-end
  ├── Mobile viewport looks right
  └── Screenshots captured for PR

Layer 3: Human Review (taste, minutes)
  ├── Does this match the vision?
  ├── Is the UX right?
  ├── Any architectural concerns?
  └── Ship it or iterate?
```

**The human's role shifts from "does this work?" to "is this what I want?"** That's a much more productive use of human time.

---

## 3. The Gate: One Command to Verify Everything

### Why Every Project Needs a Gate

The gate script is the simplest, most impactful thing you can add to any project. One command. Runs everything. Pass = ready for review. Fail = keep working.

```bash
./scripts/gate.sh
```

No arguments. No options. No "which tests should I run?" Just run it. If it's green, you're good.

### Gate Script Template

```bash
#!/bin/bash
# scripts/gate.sh — The single source of truth for "is this code ready?"
set -e
echo "🔒 Running full gate..."

# Backend (Rails)
echo "=== Backend ==="
cd backend/
bundle exec rubocop --no-color
bundle exec rspec
cd ..

# Frontend (React)
echo "=== Frontend ==="
cd frontend/
npm run lint
npx tsc --noEmit
npm run build
npm test -- --run
cd ..

# Security / hygiene
echo "=== Hygiene ==="
grep -rn "console\.log\|debugger\|binding\.pry\|byebug" \
  --include="*.ts" --include="*.tsx" --include="*.rb" \
  --exclude-dir=node_modules --exclude-dir=vendor \
  --exclude-dir=tmp --exclude-dir=log || true

echo "✅ Gate passed!"
```

### Gate Rules

| Rule | Why |
|------|-----|
| **One command** | No decisions to make — just run it |
| **Fast** (< 60 seconds ideal) | Agents run it on every change |
| **Comprehensive** | Tests + lint + types + build |
| **Zero tolerance** | If it fails, fix it. No "it's just a warning" |
| **In version control** | `scripts/gate.sh`, committed, everyone uses it |

### Variations by Project Type

See the [Testing Guide](TESTING_GUIDE.md#2-the-closed-loop-principle) for detailed gate templates for frontend-only, backend-only, and monorepo projects.

---

## 4. Parallel Agent Management

### The Chess Grandmaster Analogy

A chess grandmaster playing simultaneous games doesn't stare at one board for 30 minutes. They make a move, move to the next board, come back when it's their turn. AI agent management works the same way:

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  Agent 1      │  │  Agent 2      │  │  Agent 3      │
│  Feature A    │  │  Bug Fix B    │  │  Feature C    │
│  🔄 Coding... │  │  ✅ Gate green │  │  🔄 Running   │
│               │  │  Ready for QA │  │     gate...   │
└──────────────┘  └──────────────┘  └──────────────┘
       │                 │                 │
       └────────┬────────┘                 │
                ▼                          │
        ┌──────────────┐                   │
        │  Coordinator  │◄─────────────────┘
        │  (you/main)   │
        │               │
        │  • Review QA  │
        │  • Create PRs │
        │  • Direct     │
        └──────────────┘
```

### How to Coordinate

**1. Spawn agents with clear, self-contained tasks:**
```
"Fix the cart total calculation bug (HTZ-42).
 Branch from staging. Run gate when done.
 Report back with gate results."
```

**2. Each agent is self-verifying:**
- They don't ask you "does this look right?"
- They run the gate themselves
- They report pass/fail with evidence

**3. You do visual QA and coordination:**
- Review gate results
- Open browser for visual verification
- Create PRs with screenshots
- Update tickets on Plane

### What Agents Handle vs What You Handle

| Task | Agent | Coordinator (You) |
|------|-------|--------------------|
| Code the feature | ✅ | |
| Write tests | ✅ | |
| Run gate script | ✅ | |
| Fix gate failures | ✅ | |
| Visual QA (browser) | | ✅ |
| Create PR | | ✅ |
| Update tickets | | ✅ |
| Architecture decisions | | ✅ |
| Resolve merge conflicts | | ✅ (or direct agent) |

### Practical Tips

- **Start with 2 agents**, scale to 3-4 as you get comfortable
- **Give each agent a separate branch** — avoid merge conflicts
- **Don't micro-manage** — if the gate passes, the code is probably fine
- **Batch visual QA** — do all browser checks in one session
- **Kill stalled agents** — if no progress in 20 minutes, respawn with clearer instructions

---

## 5. Prompt Design as a Skill

### The Art of Asking the Right Questions

Prompt design isn't about writing perfect instructions. It's about knowing **what level of detail** an agent needs and **what questions to ask** to shape the output.

### The Prompting Spectrum

```
Under-prompt ◄──────────────────────────────► Over-prompt
"Fix the bug"                                  "In file X, line 42,
                                                change the variable
                                                from Y to Z, then
                                                update the test..."
     │                                              │
     │  Sweet spot: describe WHAT and WHY,          │
     │  let agent figure out HOW                    │
     │         ▼                                    │
     │  "The cart total is wrong when items          │
     │   have modifiers. The modifier price          │
     │   should add to the base price, not           │
     │   replace it. Check the Order model           │
     │   calculation. Write a test first."           │
```

### When to Under-Prompt

| Situation | Why Under-Prompting Works |
|-----------|--------------------------|
| Agent knows the codebase well | Context is already loaded |
| Exploratory tasks | "Investigate why X is slow" |
| Well-tested codebases | Gate catches mistakes |
| Experienced agents | They'll ask if unclear |

### When to Over-Prompt

| Situation | Why Detail Helps |
|-----------|-----------------|
| New project (no AGENTS.md yet) | Agent has no context |
| Tricky architectural decisions | You need a specific approach |
| Cross-cutting changes | Multiple files need coordination |
| Past failures | Agent got it wrong before — be specific |

### Prompt Patterns That Work

**The "Test First" prompt:**
```
"Write a failing test for: when a user adds a modifier to an item,
the order total should include the modifier price. Then make it pass."
```

**The "Investigate and Fix" prompt:**
```
"Users report the menu page is slow. Check the API response time,
look for N+1 queries, and fix what you find. Run gate when done."
```

**The "Builder Conversation" prompt:**
```
"We need fundraiser ordering. Users browse active fundraisers,
see what items are available, and order. What's the best way
to structure this given our existing menu/order system?"
```

**The "Specific Fix" prompt:**
```
"The admin dashboard shows 'NaN' for order totals when modifiers
are present. The issue is in OrderSummary.tsx — it's not parsing
the modifier_adjustments as numbers. Fix and add a test."
```

### What NOT to Do

| Anti-Pattern | Problem |
|-------------|---------|
| "Make it work" | What does "work" mean? |
| "Fix all the bugs" | Too vague, agent will hallucinate bugs |
| "Rewrite this file" | Why? What's wrong with it? |
| Step-by-step instructions | You're just coding through the agent |
| No success criteria | Agent doesn't know when to stop |

---

## 6. When to Intervene vs Let Agents Cook

### The Decision Framework

```
Agent is working on a task...

Is the gate passing?
├── YES → Let it cook. Check back later.
├── NO, but making progress → Give it one more iteration.
└── NO, same error 3+ times → Intervene.

Is the approach fundamentally wrong?
├── YES → Stop. Redirect with new context.
└── NO → Let it iterate. The gate will catch issues.

Is it taking too long?
├── > 20 minutes, no progress → Kill and respawn with better prompt.
├── > 20 minutes, making progress → Let it finish.
└── < 20 minutes → Too early to judge.
```

### Signs to Let It Cook 🍳

- Gate is passing (even if code isn't perfect)
- Agent is making incremental progress
- The approach matches what you'd do
- Tests are being written alongside code

### Signs to Intervene 🛑

- Same error appearing 3+ times in a loop
- Agent is going down a fundamentally wrong path
- Massive file rewrites when a small fix would work
- Creating unnecessary complexity
- Ignoring existing patterns in the codebase

### How to Intervene Effectively

**Don't:** "This is wrong. Start over."

**Do:** "The approach of X isn't going to work because Y. Instead, try Z. Look at how we handle similar cases in [file]."

Give agents the *why* behind the correction. They learn from context, not commands.

### The 80/20 Rule

~80% of tasks should complete without intervention. If you're intervening more than 20% of the time:
- Your prompts need more context
- Your codebase needs better documentation (AGENTS.md)
- Your gate script might be missing checks
- You might need to break tasks into smaller pieces

---

## 7. Iterative Forward-Building

### Shape Like a Sculptor

Don't plan everything upfront and build in one shot. Instead, build iteratively — each layer adds functionality, and each layer is verified before the next:

```
Iteration 1: Basic structure
  → Gate green ✅ → Visual QA ✅

Iteration 2: Core functionality
  → Gate green ✅ → Visual QA ✅

Iteration 3: Edge cases + polish
  → Gate green ✅ → Visual QA ✅

Iteration 4: Final review
  → Gate green ✅ → Visual QA ✅ → PR created
```

### Why Forward-Building Works

| Principle | Explanation |
|-----------|-------------|
| **Each step is verified** | Gate + visual QA after every iteration |
| **Easy to course-correct** | Catch wrong direction early |
| **Agents work best incrementally** | Small, focused tasks > big rewrites |
| **Rarely need to revert** | Each iteration builds on verified work |
| **Progress is visible** | Screenshots at each stage show evolution |

### When to Revert (Rare)

Revert when:
- The fundamental approach is wrong (not just implementation details)
- The agent introduced a regression that's hard to untangle
- You realize the feature shouldn't exist at all

Don't revert when:
- The code works but isn't styled perfectly → iterate
- There's a minor bug → fix forward
- You'd do it differently → if it passes the gate, it's fine

### Practical Example: Building a Feature

```
Step 1: "Create the fundraiser model and API endpoints.
         Just CRUD for now. Run gate."
         → Agent delivers. Gate green. ✅

Step 2: "Add the browsing UI. Grid of fundraiser cards
         with name, goal, progress. Route: /fundraisers"
         → Agent delivers. Gate green. Visual QA: looks good. ✅

Step 3: "Add the detail page. Show fundraiser info + available items.
         Users should be able to add items to cart from here."
         → Agent delivers. Gate green. Visual QA: cart integration works. ✅

Step 4: "Polish: add progress bar to cards, better mobile layout,
         empty state when no fundraisers are active."
         → Agent delivers. Gate green. Visual QA: looks polished. ✅
         → Create PR with all screenshots.
```

Each step is small enough to verify, big enough to make progress.

---

## 8. Designing Agent-Friendly Codebases

### Why Codebase Design Matters

Agents navigate codebases by reading — file names, function names, comments, structure. A well-organized codebase is like a well-organized kitchen: anyone can find what they need without asking.

### Naming Conventions

| Pattern | Good | Bad |
|---------|------|-----|
| **Files** | `OrderSummary.tsx`, `calculate_total.rb` | `Summary.tsx`, `utils.rb` |
| **Functions** | `calculateOrderTotal()` | `calc()`, `doStuff()` |
| **Variables** | `modifierPrice`, `isAvailable` | `mp`, `flag` |
| **Directories** | `components/orders/`, `services/` | `misc/`, `stuff/` |

**The rule:** If an agent can't guess what a file/function does from its name, rename it.

### File Structure That Agents Love

```
# Good: Predictable, domain-organized
frontend/src/
├── components/
│   ├── orders/
│   │   ├── OrderCard.tsx
│   │   ├── OrderSummary.tsx
│   │   └── OrderFilters.tsx
│   ├── menu/
│   │   ├── MenuGrid.tsx
│   │   ├── MenuItem.tsx
│   │   └── ModifierSelector.tsx
│   └── ui/              ← Reusable primitives
│       ├── Button.tsx
│       ├── Modal.tsx
│       └── LoadingSpinner.tsx
├── shared/
│   ├── api/              ← API service files
│   ├── hooks/            ← Custom hooks
│   └── utils/            ← Pure utility functions
└── pages/                ← Route-level components
```

```
# Bad: Flat, ambiguous
frontend/src/
├── components/
│   ├── Card.tsx          ← Which card?
│   ├── Summary.tsx       ← Summary of what?
│   ├── Grid.tsx          ← Grid of what?
│   ├── Modal.tsx
│   ├── Button.tsx
│   └── ... 50 more files
```

### Documentation That Agents Read

| File | Purpose | Who Reads It |
|------|---------|-------------|
| `AGENTS.md` | Project context, patterns, conventions | Every AI tool |
| `README.md` | Setup instructions, architecture overview | Humans + agents |
| `scripts/gate.sh` | What "verified" means | Agents (run it) |
| Code comments | Why, not what | Agents + humans |
| Type definitions | Data shapes and contracts | Agents + TypeScript |

### Architecture Choices for Verifiability

**Clear API contracts:**
```ruby
# Good: Request spec makes the contract explicit
RSpec.describe "POST /api/v1/orders" do
  it "creates order with items and modifiers" do
    post "/api/v1/orders", params: { items: [...] }
    expect(response).to have_http_status(:created)
    expect(json["total"]).to eq("25.50")
  end
end
```

**Separation of concerns:**
```ruby
# Good: Pure calculation, easily testable
class OrderCalculator
  def self.calculate_total(items)
    items.sum { |i| i.base_price + i.modifier_total }
  end
end

# Bad: Tangled with controller logic, hard to test
class OrdersController < ApplicationController
  def create
    total = 0
    params[:items].each { |i| total += ... } # buried logic
  end
end
```

**Small, focused components:**
```tsx
// Good: 30 lines, one job, easy to verify
function OrderTotal({ items }: { items: OrderItem[] }) {
  const total = items.reduce((sum, item) => sum + item.price, 0);
  return <div className="text-xl font-bold">${total.toFixed(2)}</div>;
}

// Bad: 300 lines, does everything, impossible to verify quickly
function OrderPage() {
  // ... fetching, state, calculations, rendering, side effects...
}
```

> **Peter Steinberger's insight:** "Using agentic coding makes you a better coder because you have to think harder about architecture so it's easier to verify." The constraint of agent-verifiability pushes you toward genuinely better software design.

---

## 9. Practical Templates

### Sub-Agent Task Template

When spawning a sub-agent for a coding task:

```
Task: [TICKET-ID] — [Brief description]

Context:
- Project: [repo name]
- Working directory: ~/work/[project]/
- Branch from: staging
- Branch name: feature/[TICKET-ID]-[description]

What to do:
1. [Specific task description]
2. [Additional requirements]
3. Write tests for your changes
4. Run ./scripts/gate.sh — must pass
5. Report back with gate results

Key files:
- [relevant file 1]
- [relevant file 2]

Don'ts:
- Don't modify [protected file/area]
- Don't skip the gate
```

### PR Description Template

```markdown
## [TICKET-ID]: [Title]

### What Changed
- [Change 1]
- [Change 2]

### Why
[Brief explanation of the motivation]

### Gate Results
✅ RSpec: XX examples, 0 failures
✅ Rubocop: no offenses
✅ ESLint: clean
✅ TypeScript: no errors
✅ Build: successful
✅ Vitest: XX tests passed

### Visual QA
| View | Screenshot |
|------|-----------|
| Desktop | [screenshot] |
| Mobile | [screenshot] |
| Key flow | [screenshot] |

### Testing Notes
- Tested: [what was manually verified]
- Edge cases: [what edge cases were checked]
```

### AGENTS.md Template

```markdown
# AGENTS.md — [Project Name]

## Overview
[What this project does, who it's for]

## Tech Stack
- Frontend: [framework, language, build tool, CSS]
- Backend: [framework, language, database]
- Auth: [provider]
- Hosting: [where it runs]

## Development
- Gate script: `./scripts/gate.sh`
- All PRs target: `staging` branch
- Branch naming: `feature/TICKET-ID-description`
- Commit format: `TICKET-ID: Description`

## Project Structure
[Key directories and what goes where]

## Conventions
[Naming, patterns, common gotchas]

## Testing
[What to test, how to run tests, test credentials]
```

### Gate Script Checklist

When creating a gate for a new project:

```
□ Tests run (rspec / vitest / jest / pytest)
□ Linter runs (rubocop / eslint / flake8)
□ Type checker runs (tsc --noEmit / mypy)
□ Build succeeds (npm run build / cargo build)
□ No debug statements (console.log, debugger, binding.pry)
□ Script is executable (chmod +x scripts/gate.sh)
□ Script is committed to version control
□ Script uses `set -e` (fail on first error)
□ Script runs in < 60 seconds
□ README mentions the gate script
```

---

## 10. Lessons Learned

### What Works

| Practice | Why It Works |
|----------|-------------|
| Gate scripts | One command = no ambiguity about "ready" |
| AGENTS.md in every project | Agents start with context, not guessing |
| Small tasks over big ones | 5 small verified steps > 1 big unverified step |
| Screenshots in every UI PR | Visual proof = fast human review |
| Forward-building over reverting | Iteration is faster than perfection |
| Under-prompting experienced agents | Let them propose solutions, then iterate |

### What Doesn't Work

| Anti-Pattern | Why It Fails |
|-------------|-------------|
| "Just make it work" prompts | No success criteria = no verification |
| Skipping the gate "just this once" | Broken windows theory — quality erodes fast |
| Agents creating PRs directly | No visual QA step = visual bugs slip through |
| Over-specifying implementation | You're just coding through the agent, slower |
| Massive tasks without checkpoints | Too much can go wrong without verification |
| Ignoring CodeRabbit comments | Technical debt accumulates silently |

### The Evolution

Most teams evolve through these stages:

```
Stage 1: "AI writes code, I review everything"
  → Slow, human is the bottleneck

Stage 2: "AI writes code + tests, I verify in browser"
  → Better, but human still does most verification

Stage 3: "AI writes code + tests + runs gate, I do visual QA"
  → Good. Human reviews verified work.

Stage 4: "AI writes code + tests + runs gate + does visual QA, I review PRs"
  → Great. Human is the taste/direction arbiter.

Stage 5: "Multiple agents in parallel, each self-verifying, I coordinate"
  → Optimal. Human is the architect/builder.
```

> **The Shimizu Way:** You don't have to start at Stage 5. Start at Stage 2, add a gate script (Stage 3), add visual QA tooling (Stage 4), then scale to parallel agents (Stage 5). Each stage builds on the last.

---

## Quick Reference

### Commands You'll Use Daily

```bash
# Run the gate
./scripts/gate.sh

# Spawn a sub-agent (example — tool-specific)
# In OpenClaw: create a new sub-agent session
# In Cursor: open a new composer with task context
# In Claude Code: use subagent spawn

# Create a PR targeting staging
gh pr create --base staging --title "TICKET-ID: Description"

# Visual QA (browser tool)
browser → open http://localhost:5174
browser → snapshot
browser → screenshot
```

### The Workflow in 30 Seconds

```
1. Pick up ticket → move to In Progress
2. Spawn sub-agent with task + context
3. Agent codes → runs gate → reports results
4. You do visual QA in real browser
5. Create PR with gate results + screenshots
6. Human reviews → approve → merge to staging
7. Move ticket to Done
```

### Key Files in Every Project

| File | Purpose |
|------|---------|
| `AGENTS.md` | AI context for all tools |
| `scripts/gate.sh` | One-command verification |
| `.cursor/rules/project.mdc` | Cursor-specific context |
| `README.md` | Human setup + architecture |

---

*Last updated: February 2026*
