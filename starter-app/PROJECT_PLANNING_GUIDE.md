# Project Planning Guide

A guide for planning software projects before writing code. Covers creating a PRD (Product Requirements Document) and BUILD_PLAN to ensure smooth development.

---

## Table of Contents
1. [Why Plan First?](#1-why-plan-first)
2. [The Two Documents](#2-the-two-documents)
3. [PRD Structure](#3-prd-structure)
4. [BUILD_PLAN Structure](#4-build_plan-structure)
5. [The Planning Process](#5-the-planning-process)
6. [Templates](#6-templates)
7. [Tips & Best Practices](#7-tips--best-practices)

---

## 1. Why Plan First?

### The Problem Without Planning
- "Just start coding" leads to rework
- Scope creep because requirements weren't defined
- Technical debt from ad-hoc decisions
- Missed requirements discovered late
- No shared understanding between developer and client

### Benefits of Planning First

| Benefit | Why It Matters |
|---------|---------------|
| **Clarity** | Everyone agrees on what's being built |
| **Scope control** | Clear boundaries prevent feature creep |
| **Better estimates** | Breaking down work reveals true complexity |
| **Fewer surprises** | Questions answered before coding starts |
| **Reference document** | Something to point to when decisions are questioned |
| **Progress tracking** | Checkboxes show actual progress |

### Time Investment

| Project Size | Planning Time | Build Time Saved |
|--------------|---------------|-----------------|
| Small (1-2 weeks) | 2-4 hours | 20-30% |
| Medium (1-2 months) | 1-2 days | 30-40% |
| Large (3+ months) | 3-5 days | 40-50% |

The rule: **Spend 10-15% of project time on planning.** It pays back 2-3x in smoother development.

---

## 2. The Two Documents

### PRD (Product Requirements Document)
**Purpose:** Define WHAT you're building and WHY

Contains:
- Business context and goals
- User roles and permissions
- Feature specifications
- Technical architecture
- Database schema
- Open questions

**Audience:** Client, stakeholders, developers

### BUILD_PLAN
**Purpose:** Define HOW and WHEN you're building it

Contains:
- Phased breakdown of work
- Specific tasks with checkboxes
- Current status tracking
- Timeline estimates

**Audience:** Developers, project managers

### How They Work Together

```
PRD.md                          BUILD_PLAN.md
────────                        ─────────────
"We need user auth"      →      Phase 1: Auth Setup
                                - [ ] Install Clerk SDK
                                - [ ] Add ClerkProvider
                                - [ ] Create users table
                                - [ ] Set up JWT verification

"Clients submit forms"   →      Phase 2: Intake Form
                                - [ ] Create form wizard
                                - [ ] Build 8 sections
                                - [ ] Add validation
                                - [ ] Add kiosk mode
```

---

## 3. PRD Structure

### Essential Sections

#### 1. Guiding Principles
The rules that guide ALL decisions. Define these first.

```markdown
## Guiding Principles

### 1. Mobile-First, Responsive Always
Every feature must work on mobile from day one.

### 2. Ease of Use Over Feature Richness
If users need instructions, we've failed.

### 3. Do It Right, Not Quick
Build for the long run, not just "make it work now."
```

**Why this matters:** When you're stuck on a decision, principles guide you.

#### 2. Executive Summary
One paragraph explaining the project.

```markdown
## Executive Summary

[Client Name] needs a platform to:
1. [Primary goal]
2. [Secondary goal]
3. [Tertiary goal]
```

#### 3. Business Information
Everything about the client/business.

```markdown
## Business Information

### Company Details
| Field | Value |
|-------|-------|
| Company Name | |
| Address | |
| Phone | |
| Email | |

### Branding
| Element | Notes |
|---------|-------|
| Logo | [Status] |
| Colors | [Primary, Secondary, Accent] |
| Style | [Professional, Playful, etc.] |

### Domain
- Status: [Purchased / Needs purchase]
- URL: example.com
```

#### 4. Technical Architecture
The tech stack and how things connect.

```markdown
## Technical Architecture

### Overview
[ASCII diagram showing frontend → backend → database]

### Tech Stack
| Layer | Technology | Purpose |
|-------|------------|---------|
| Frontend | React + Vite | UI |
| Backend | Rails API | Business logic |
| Database | PostgreSQL | Data storage |
| Auth | Clerk | User management |
| Hosting | Netlify + Render | Deployment |
```

#### 5. User Roles & Permissions
Who uses the system and what they can do.

```markdown
## User Roles

| Role | Description |
|------|-------------|
| Admin | Full access |
| Employee | Operational access |
| Client | View own data |

### Permission Matrix
| Feature | Admin | Employee | Client |
|---------|-------|----------|--------|
| View all records | ✅ | ✅ | ❌ |
| Create records | ✅ | ✅ | ❌ |
| Manage users | ✅ | ❌ | ❌ |
```

#### 6. Feature Specifications
Detailed breakdown of each feature.

```markdown
## Feature Specifications

### 1. [Feature Name]

**Purpose:** Why this feature exists

**Fields:**
| Field | Type | Required | Notes |
|-------|------|----------|-------|
| Name | Text | ✅ | |
| Email | Email | ✅ | For notifications |

**User Flow:**
1. User clicks "Create"
2. Form opens
3. User fills fields
4. User submits
5. System validates
6. Success message shown

**Edge Cases:**
- What if email already exists?
- What if required field is missing?
```

#### 7. Database Schema
Tables and relationships.

```markdown
## Database Schema

### Tables

#### users
| Column | Type | Notes |
|--------|------|-------|
| id | SERIAL | Primary key |
| email | VARCHAR | Unique |
| role | VARCHAR | admin, employee, client |
| created_at | TIMESTAMP | |

### Relationships
- users → has many projects
- projects → belongs to user
```

#### 8. Phase Roadmap
High-level timeline (details go in BUILD_PLAN).

```markdown
## Phase Roadmap

| Phase | Focus | Timeline |
|-------|-------|----------|
| 1 | Foundation | Week 1 |
| 2 | Core Features | Week 2-3 |
| 3 | Advanced Features | Week 4-5 |
| 4 | Polish & Deploy | Week 6 |
```

#### 9. Questions / Open Items
Things that need client input.

```markdown
## Questions for Client

| Item | Status | Decision |
|------|--------|----------|
| Logo | ⏳ Waiting | Will get from client |
| Business hours | ✅ Resolved | 8am-5pm M-F |
| SMS provider | ⏳ Pending | Need to decide |
```

---

## 4. BUILD_PLAN Structure

### Current Status Section
Quick reference at the top.

```markdown
## Current Status

**Last Updated:** [Date]

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1 | ✅ Complete | |
| Phase 2 | 🔄 In Progress | Working on auth |
| Phase 3 | ⬜ Not Started | |

### URLs
- **Production:** https://app.example.com
- **Staging:** https://staging.example.com
- **Local:** http://localhost:3000
```

### Phase Breakdown
Each phase gets its own section with checkboxes.

```markdown
## Phase 1: Foundation

### 1.1 Project Setup
- [x] Initialize frontend (React + Vite)
- [x] Initialize backend (Rails API)
- [x] Set up database
- [x] Configure CORS
- [ ] Create .env.example files

### 1.2 Authentication
- [ ] Install Clerk SDK
- [ ] Add ClerkProvider
- [ ] Create users table
- [ ] Set up JWT verification
- [ ] Implement protected routes
```

### Task Granularity
Tasks should be:
- **Completable in 1-4 hours** (not too big)
- **Specific and actionable** (not vague)
- **Verifiable** (you know when it's done)

```markdown
# Too vague
- [ ] Set up authentication

# Too granular
- [ ] Import ClerkProvider
- [ ] Add ClerkProvider to main.tsx
- [ ] Pass publishableKey prop

# Just right
- [ ] Install Clerk SDK and add ClerkProvider to app
- [ ] Create JWT verification service in backend
- [ ] Implement protected routes with role checking
```

### Timeline Summary
At the end, summarize the phases.

```markdown
## Timeline Summary

| Phase | Focus | Duration |
|-------|-------|----------|
| 1 | Foundation | Week 1 |
| 2 | Core Features | Week 2-3 |
| 3 | Polish & Deploy | Week 4 |

**Total:** 4 weeks
```

---

## 5. The Planning Process

### Step 1: Discovery Call (1-2 hours)
Gather information from the client.

**Questions to ask:**
- What problem are you solving?
- Who are the users?
- What does success look like?
- What's the timeline/budget?
- What existing systems need integration?
- Do you have branding/design assets?

### Step 2: Draft PRD (2-4 hours)
Write the first version based on discovery.

**Don't worry about:**
- Perfect wording
- Every edge case
- Final technical decisions

**Do include:**
- All major features mentioned
- User roles
- Key workflows
- Open questions

### Step 3: Review with Client (1 hour)
Walk through the PRD together.

**Goals:**
- Confirm understanding
- Clarify ambiguities
- Get answers to open questions
- Agree on scope

### Step 4: Create BUILD_PLAN (1-2 hours)
Break the PRD into phases and tasks.

**Process:**
1. Group related features into phases
2. Order phases by dependency (foundation first)
3. Break each phase into specific tasks
4. Estimate timeline for each phase

### Step 5: Final Review
Confirm with client that the plan matches expectations.

### Step 6: Start Building
Now you can code with confidence!

---

## 6. Templates

### Minimal PRD Template

```markdown
# [Project Name]
## Product Requirements Document

**Version:** 1.0  
**Date:** [Date]

---

## Executive Summary

[One paragraph: What is this project and why?]

---

## Guiding Principles

1. **[Principle 1]**: [Explanation]
2. **[Principle 2]**: [Explanation]
3. **[Principle 3]**: [Explanation]

---

## Business Information

| Field | Value |
|-------|-------|
| Company | |
| Contact | |
| Domain | |

---

## Tech Stack

| Layer | Technology |
|-------|------------|
| Frontend | |
| Backend | |
| Database | |
| Auth | |
| Hosting | |

---

## User Roles

| Role | Description | Permissions |
|------|-------------|-------------|
| Admin | | Full access |
| User | | Limited access |

---

## Features

### Feature 1: [Name]
**Purpose:** [Why]

**Requirements:**
- 
- 

### Feature 2: [Name]
**Purpose:** [Why]

**Requirements:**
- 
- 

---

## Database Schema

### [table_name]
| Column | Type | Notes |
|--------|------|-------|
| id | SERIAL | PK |
| | | |

---

## Phase Roadmap

| Phase | Focus | Timeline |
|-------|-------|----------|
| 1 | | Week 1 |
| 2 | | Week 2-3 |

---

## Open Questions

| Question | Status | Answer |
|----------|--------|--------|
| | ⏳ | |

---
```

### Minimal BUILD_PLAN Template

```markdown
# [Project Name] - Build Plan

## Current Status

**Last Updated:** [Date]

| Phase | Status |
|-------|--------|
| 1 | ⬜ Not Started |
| 2 | ⬜ Not Started |

---

## Phase 1: Foundation

### 1.1 Project Setup
- [ ] Initialize frontend
- [ ] Initialize backend
- [ ] Set up database
- [ ] Configure environment

### 1.2 [Next Section]
- [ ] Task 1
- [ ] Task 2

---

## Phase 2: Core Features

### 2.1 [Feature Area]
- [ ] Task 1
- [ ] Task 2

---

## Timeline

| Phase | Duration |
|-------|----------|
| 1 | Week 1 |
| 2 | Week 2-3 |

**Total:** X weeks
```

---

## 7. Tips & Best Practices

### PRD Tips

**Be specific, not vague:**
```markdown
# Vague
Users can manage their profile.

# Specific
Users can update their name, email, and profile photo.
Profile photos are stored in S3.
Email changes require verification.
```

**Use tables for structured info:**
```markdown
# Hard to scan
The user form has fields for first name (required), last name (required), 
email (required, must be valid format), phone (optional), and notes (optional).

# Easy to scan
| Field | Required | Validation |
|-------|----------|------------|
| First Name | ✅ | |
| Last Name | ✅ | |
| Email | ✅ | Valid format |
| Phone | | |
| Notes | | |
```

**Include edge cases:**
```markdown
### Edge Cases
- What if user tries to delete their own admin account?
- What happens to assigned tasks when an employee is deleted?
- What if two people edit the same record simultaneously?
```

### BUILD_PLAN Tips

**Update status regularly:**
Keep the "Current Status" section at the top accurate. It's your quick reference.

**Check off tasks as you complete them:**
The satisfaction of `- [x]` is real. It also shows progress.

**Add notes when things change:**
```markdown
### 2.3 Notifications
- [x] Set up Resend email
- [ ] Set up ClickSend SMS ← Deferred to Phase 4 (client decision)
```

**Don't over-plan future phases:**
Phases 1-2 should be detailed. Phases 3+ can be rougher until you get there.

### Process Tips

**Start with the happy path:**
Document the normal flow first, then add error handling and edge cases.

**Get client sign-off:**
Before starting development, have the client confirm the PRD is correct. This prevents "that's not what I meant" later.

**The PRD is a living document:**
Update it when requirements change. Add a version number and changelog if needed.

**Time-box planning:**
Don't spend weeks planning. Set a limit (e.g., 2 days for a medium project) and stick to it. You can refine as you build.

---

## 8. Testing in the Planning Process

Testing should be planned, not an afterthought. Include testing requirements in both documents.

### PRD Testing Section

Add this section to your PRD:

```markdown
## Testing Requirements

### Critical User Flows (E2E Coverage)

| Flow | Priority | Notes |
|------|----------|-------|
| User registration/login | P0 | Auth must always work |
| Main form submission | P0 | Core functionality |
| Payment processing | P0 | Revenue-critical |
| Admin CRUD operations | P1 | Business operations |

### Test Accounts

| Email | Role | Purpose |
|-------|------|---------|
| test-admin@example.com | Admin | Full access testing |
| test-user@example.com | User | Standard user testing |

### Test Data Requirements

- Seed data for X test records
- Sample files for upload tests
- Edge case scenarios
```

### BUILD_PLAN Testing Tasks

Add testing tasks to each phase:

```markdown
## Phase 2: User Authentication

### 2.1 Build
- [ ] Install auth provider
- [ ] Create login/signup pages
- [ ] Implement protected routes

### 2.2 Testing
- [ ] E2E: Complete signup flow
- [ ] E2E: Login with valid credentials
- [ ] E2E: Login with invalid credentials
- [ ] E2E: Password reset flow
- [ ] AI: Mobile layout verification
```

### Pre-Deploy Checklist

Add to the end of your BUILD_PLAN:

```markdown
## Pre-Deploy Testing Checklist

### Automated Tests
- [ ] All E2E tests passing (`npm test`)
- [ ] No console errors in dev tools

### AI Verification
- [ ] Critical pages load on mobile
- [ ] Forms submit successfully
- [ ] Navigation works

### Manual QA
- [ ] Stakeholder walkthrough
- [ ] Edge cases tested
- [ ] Performance acceptable
```

### What to Test (Priority Guide)

| Priority | What | Why | Test Type |
|----------|------|-----|-----------|
| **P0** | Auth flows | Broken = no access | E2E |
| **P0** | Main user journey | Core value | E2E |
| **P1** | Form validation | UX critical | E2E |
| **P1** | Error handling | User confidence | E2E |
| **P2** | Edge cases | Prevent bugs | Unit/E2E |
| **P3** | Visual regression | Polish | Snapshot |

See the [Testing Guide](./TESTING_GUIDE.md) for full setup instructions.

---

## Quick Reference

### When to Create Each Document

| Situation | PRD | BUILD_PLAN |
|-----------|-----|------------|
| New client project | ✅ | ✅ |
| Personal side project | Optional | ✅ |
| Small feature addition | ❌ | Optional |
| Major refactor | ❌ | ✅ |
| Bug fixes | ❌ | ❌ |

### Status Emoji Key

| Emoji | Meaning |
|-------|---------|
| ✅ | Complete |
| 🔄 | In Progress |
| ⬜ | Not Started |
| ⏳ | Waiting/Pending |
| ❌ | Cancelled/Won't Do |

### Checkbox Syntax

```markdown
- [ ] Not done
- [x] Done
```

---

*Last updated: January 2026*
