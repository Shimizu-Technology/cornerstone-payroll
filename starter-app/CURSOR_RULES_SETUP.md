# Cursor Rules Setup Guide

A guide for creating `.cursor/rules/` files that give AI context about your project.

---

## Table of Contents
1. [What Are Cursor Rules?](#1-what-are-cursor-rules)
2. [File Structure](#2-file-structure)
3. [Rule File Format](#3-rule-file-format)
4. [Glob Pattern Format](#4-glob-pattern-format)
5. [Rule Types & When They Apply](#5-rule-types--when-they-apply)
6. [Recommended Rules Structure](#6-recommended-rules-structure)
7. [Templates by Project Type](#7-templates-by-project-type)
8. [What to Include](#8-what-to-include)
9. [Troubleshooting](#9-troubleshooting)
10. [Tips & Best Practices](#10-tips--best-practices)

---

## 1. What Are Cursor Rules?

Cursor rules are markdown files (`.mdc`) that provide context to the AI about your project. They help the AI:

- Understand your tech stack and conventions
- Follow your coding standards
- Know your project structure
- Make consistent decisions

**Without rules**: AI might suggest React class components, wrong file locations, or patterns you don't use.

**With rules**: AI suggests code that fits YOUR project's style.

---

## 2. File Structure

```
your-project/
├── .cursor/
│   └── rules/
│       ├── project.mdc      # Core project context (always applied)
│       ├── testing.mdc      # AI testing rules (always applied)
│       ├── frontend.mdc     # Frontend-specific rules
│       ├── backend.mdc      # Backend-specific rules
│       └── database.mdc     # Database conventions
├── frontend/
├── backend/
└── ...
```

### File Naming
- Use `.mdc` extension (Markdown for Cursor)
- Name by area: `project`, `frontend`, `backend`, `database`, `testing`, etc.
- Keep names simple and descriptive

---

## 3. Rule File Format

Each `.mdc` file has a YAML frontmatter header followed by Markdown content.

### Frontmatter Options

```yaml
---
description: Brief description of what this rule file covers
globs:                          # Optional - file patterns to auto-attach
  - "src/**/*.tsx"
  - "src/**/*.ts"
alwaysApply: false              # true = always in context, false = conditional
---
```

| Field | Purpose | When to Use |
|-------|---------|-------------|
| `description` | Explains the rule file | Always include |
| `alwaysApply` | Load for every conversation | Use for core project rules |
| `globs` | Load when matching file is @mentioned | Use for area-specific rules |

---

## 4. Glob Pattern Format

**This is important!** Incorrect glob format causes "glob pattern doesn't match" errors.

### ✅ Correct Format - YAML Array

Multi-line (recommended):
```yaml
globs: 
  - "frontend/**/*.tsx"
  - "frontend/**/*.ts"
  - "frontend/**/*.css"
```

Single-line YAML array:
```yaml
globs: ["frontend/**/*.tsx", "frontend/**/*.ts"]
```

### ❌ Incorrect Format

```yaml
# DON'T DO THIS - causes errors
globs: ["frontend/**/*"]    # JSON-style in quotes on same line as globs:
```

### Pattern Examples

| Pattern | Matches |
|---------|---------|
| `"frontend/**/*.tsx"` | All .tsx files in frontend folder |
| `"backend/**/*.rb"` | All .rb files in backend folder |
| `"**/db/**/*"` | Any db folder anywhere in project |
| `"**/*.test.ts"` | All .test.ts files anywhere |
| `"backend/app/models/**/*.rb"` | All Ruby files in models folder |

---

## 5. Rule Types & When They Apply

| Type | Configuration | Behavior |
|------|--------------|----------|
| **Always** | `alwaysApply: true` | Always in AI context (globs ignored) |
| **Auto Attached** | `alwaysApply: false` + `globs` defined | Attached when matching file is @mentioned |
| **Agent Requested** | Has description, no globs, `alwaysApply: false` | AI can include when relevant |
| **Manual** | No description or globs | Only via explicit `@ruleName` mention |

### Cursor 2.0+ Behavior (Important!)

In Cursor 2.0+, rules with `alwaysApply: false` and globs:
- **DO NOT** auto-load just by opening a matching file
- **DO** load when the file is referenced via `@mention` in chat
- For rules you want ALWAYS active, use `alwaysApply: true`

### Recommended Approach

| Rule File | Setting | Why |
|-----------|---------|-----|
| `project.mdc` | `alwaysApply: true` | Core context always needed |
| `testing.mdc` | `alwaysApply: true` | AI should always verify its work |
| `frontend.mdc` | `globs` + `alwaysApply: false` | Only when working on frontend |
| `backend.mdc` | `globs` + `alwaysApply: false` | Only when working on backend |
| `database.mdc` | `globs` + `alwaysApply: false` | Only when working on DB |

---

## 6. Recommended Rules Structure

### For Full-Stack Projects (React + Rails/Node)

```
.cursor/rules/
├── project.mdc      # alwaysApply: true
├── testing.mdc      # alwaysApply: true
├── frontend.mdc     # globs: ["frontend/**/*.tsx", "frontend/**/*.ts"]
├── backend.mdc      # globs: ["backend/**/*.rb"]
└── database.mdc     # globs: ["backend/db/**/*", "backend/app/models/**/*"]
```

### For Frontend-Only Projects

```
.cursor/rules/
├── project.mdc      # alwaysApply: true
├── testing.mdc      # alwaysApply: true
└── components.mdc   # Optional: specific component patterns
```

### For Backend-Only Projects

```
.cursor/rules/
├── project.mdc      # alwaysApply: true
├── testing.mdc      # alwaysApply: true
├── api.mdc          # API design patterns
└── database.mdc     # Database conventions
```

---

## 7. Templates by Project Type

### 7.1 Core Project Rules (Always Include)

This is your `project.mdc` - the foundation. Always set `alwaysApply: true`.

```yaml
---
description: Core project context and guiding principles
alwaysApply: true
---

# Project Name

## What This Project Is
Brief description of what you're building and for whom.

## Tech Stack
- **Frontend**: React, TypeScript, Vite, Tailwind CSS
- **Backend**: Rails API / FastAPI
- **Database**: PostgreSQL
- **Auth**: Clerk / Auth0
- **Hosting**: Netlify + Render

## Guiding Principles

### 1. Mobile-First
Every feature must work on mobile AND desktop.

### 2. Ease of Use
If users need instructions, we've failed.

### 3. Do It Right
Prefer proper solutions over bandaid fixes.

## User Roles
- **Admin**: Full access
- **User**: Standard access

## Current Status
- ✅ Completed feature
- 🔜 Upcoming feature
```

### 7.2 Testing Rules (Always Applied)

```yaml
---
description: AI self-testing and verification rules
alwaysApply: true
---

# AI Testing Rules

## Core Principle
Always verify changes before declaring done.

## Backend Testing
- Test API endpoints with curl
- Verify database state with console/runner

## Frontend Testing
- Use browser tools to navigate and verify
- Take screenshots for visual changes

## Reporting
- Show evidence (curl output, screenshots)
- Report pass/fail status
```

### 7.3 Frontend Rules (Auto-Attached)

```yaml
---
description: Frontend development rules for React/TypeScript
globs: 
  - "frontend/**/*.tsx"
  - "frontend/**/*.ts"
  - "frontend/**/*.css"
alwaysApply: false
---

# Frontend Rules

## Tech
- React with Vite
- Tailwind CSS
- TypeScript required

## Component Patterns
- Functional components only
- Keep components small and focused
- Extract reusable components to `components/ui/`

## Styling
- Mobile-first approach
- Minimum touch targets: 44x44px
```

### 7.4 Backend Rules (Auto-Attached)

```yaml
---
description: Backend development rules for Rails API
globs: 
  - "backend/**/*.rb"
  - "backend/**/*.yml"
alwaysApply: false
---

# Backend Rules

## General
- Rails 7+ in API mode
- PostgreSQL database

## API Structure
- Namespace under `Api::V1`
- RESTful routes
- JSON responses

## Controllers
- Keep controllers thin
- Complex logic in service objects
```

### 7.5 Database Rules (Auto-Attached)

```yaml
---
description: Database schema and conventions
globs: 
  - "backend/db/**/*"
  - "backend/app/models/**/*.rb"
alwaysApply: false
---

# Database Rules

## Naming
- Tables: plural, snake_case
- Columns: snake_case
- Foreign keys: `{table_singular}_id`

## Required Columns
- `id` (primary key)
- `created_at`
- `updated_at`

## Indexes
- Always index foreign keys
- Index columns used in WHERE clauses
```

---

## 8. What to Include

### Always Include ✅

| Topic | Why |
|-------|-----|
| Tech stack | AI needs to know what frameworks/libraries |
| File structure | Where to put new files |
| Naming conventions | Consistent code style |
| Key patterns | How you do auth, API calls, etc. |
| Domain concepts | Business terms AI should understand |

### Good to Include 👍

| Topic | Why |
|-------|-----|
| Branding/styling | Color palette, design system |
| Common gotchas | Things that frequently cause issues |
| Testing patterns | How you write tests |
| Deployment info | Where things run |

### Skip ❌

| Topic | Why |
|-------|-----|
| Detailed API docs | Too verbose, changes often |
| Every environment variable | Reference .env.example instead |
| Step-by-step tutorials | This is context, not documentation |
| Code snippets for everything | Only include key patterns |

---

## 9. Troubleshooting

### "Glob pattern doesn't match any files"

1. **Check format** - Use YAML array format, not JSON string
   ```yaml
   # ✅ Correct
   globs: 
     - "frontend/**/*.tsx"
   
   # ❌ Wrong
   globs: ["frontend/**/*"]
   ```
2. **Check paths** - Globs are relative to workspace root
3. **Check file exists** - Make sure matching files actually exist
4. **Restart Cursor** - Sometimes UI needs refresh

### Rules not loading

1. **Check `alwaysApply`** - Set to `true` for critical rules
2. **@mention files** - For auto-attached rules, reference matching files in chat
3. **Check description** - Rules without description become manual-only

### Diff view showing in Cursor

When Cursor shows old vs new content with strikethrough:
- This is a **diff view** showing changes
- Click "Keep File" to accept changes
- Or close the diff - files are already saved

---

## 10. Tips & Best Practices

### Keep It Concise
- Aim for 50-150 lines per file
- Use bullet points, not paragraphs
- Tables are great for reference info

### Update Regularly
- Update when you add new patterns
- Update when conventions change
- Remove outdated info

### Use Code Blocks Sparingly
Only include code examples for:
- Key patterns the AI should follow
- Things that are frequently done wrong
- Complex configurations

### Be Specific About Preferences

❌ Vague:
> Use good naming conventions.

✅ Specific:
> - Components: PascalCase (`UserProfile.tsx`)
> - Hooks: camelCase with `use` prefix (`useAuth`)
> - Utils: camelCase (`formatDate`)

### Include "Don't Do" Rules

```markdown
## Don'ts
- Don't use class components (use functional with hooks)
- Don't use `any` type in TypeScript
- Don't put business logic in controllers
```

---

## Quick Reference

```yaml
# Always active - use for core project context
---
description: Core rules
alwaysApply: true
---

# Auto-attach to specific files (loads on @mention)
---
description: Frontend rules
globs: 
  - "src/**/*.tsx"
  - "src/**/*.ts"
alwaysApply: false
---

# Available to AI when relevant (no globs)
---
description: Deployment guidelines
alwaysApply: false
---
```

---

## Resources

- [Cursor Rules Documentation](https://docs.cursor.com/context/rules)
- [Glob Pattern Syntax](https://github.com/isaacs/minimatch)

---

*Last updated: January 2026*
