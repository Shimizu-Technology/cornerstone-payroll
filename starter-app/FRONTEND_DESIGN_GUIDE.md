# Frontend Design & Animation Guide
## From "AI-Generated" to Exceptional — A Practical Guide for Shimizu Technology

> **For:** Leon Shimizu, Shimizu Technology dev team, Code School of Guam students
> **Stack:** React + TypeScript + Tailwind CSS + Framer Motion
> **Last Updated:** February 6, 2026 (Added: Design Thinking framework, AI workflow tips, explicit blacklist)

---

## ⚠️ Hard Rules (Non-Negotiable)

### No Emojis — SVGs Only
**Never use emoji characters in UI.** They render differently across devices/platforms and look unprofessional.

- ✅ **Use:** Inline SVGs from lucide-react, heroicons, or custom SVG icons
- ✅ **Use:** Icon components with controllable size, color, and animation
- ❌ **Never:** `<span>🍰</span>` or emoji in text content, headings, labels, buttons, or nav
- When inheriting a codebase with emojis, sweep them out and replace with SVGs
- This applies to **all** Shimizu Technology frontends — not just one project

**Priority order:** Inline SVG > Icon library component > Icon font > ~~Emoji~~ (never)

---

## 🎯 Design Thinking (Before You Code)

Before writing any frontend code, answer these four questions:

1. **Purpose:** What problem does this interface solve? Who uses it?
2. **Tone:** What aesthetic direction? Pick ONE and commit:
   - Brutally minimal, maximalist chaos, retro-futuristic, organic/natural
   - Luxury/refined, playful/toy-like, editorial/magazine, brutalist/raw
   - Art deco/geometric, soft/pastel, industrial/utilitarian
3. **Constraints:** Technical requirements (framework, performance, accessibility)
4. **Differentiation:** What makes this UNFORGETTABLE? What's the ONE thing someone will remember?

> **CRITICAL:** Bold maximalism and refined minimalism both work — **the key is intentionality, not intensity.** A mediocre design tries to be everything. A great design picks a direction and executes it with precision.

---

## 🤖 Working with AI Tools (Cursor, Claude Code, etc.)

When using AI to generate frontend designs:

### The "5 Variations" Technique
Ask for **5 unique designs in one prompt**. This forces creativity because the model knows about all 5 and deliberately makes each different:

> "Create 5 different hero section designs. Each should be creative and unique from all the others. They should be hosted on /1, /2, /3, /4, and /5 respectively."

### Iteration is Key
1. Generate variations
2. Pick the 1-2 you like
3. Tell the AI WHAT you liked about them
4. Ask for 5 more iterations based on that feedback

This works much better than rolling the dice repeatedly.

### AI Design Blacklist
**NEVER accept these from AI-generated code** — always override:
- ❌ `font-family: Inter, Roboto, Arial, system-ui` — generic, overused
- ❌ Purple-to-blue gradients on white backgrounds — the #1 AI slop signal
- ❌ The exact same layout: Hero → 3-column grid → testimonials → CTA
- ❌ Tailwind's default `blue-500` as the primary color
- ❌ `rounded-lg` on everything with no variation

If AI gives you these, push back and ask for something distinctive.

---

## Table of Contents

1. [Why Sites Look "AI-Generated"](#1-why-sites-look-ai-generated)
2. [Design Fundamentals](#2-design-fundamentals)
3. [Animation & Motion Design](#3-animation--motion-design)
4. [Code Examples](#4-code-examples-react--typescript--tailwind--framer-motion)
5. [Component Patterns: Generic vs Elevated](#5-component-patterns-elevated-vs-generic)
6. [Tools & Resources](#6-tools--resources)
7. [Quick Checklist](#7-quick-checklist-does-this-site-feel-custom)

---

## 1. Why Sites Look "AI-Generated"

### The Dead Giveaways

You know the look. You've built it. We all have. Here's what screams "template" or "AI-generated":

**Layout sins:**
- Hero → 3-column features → testimonials → CTA → footer. Every. Single. Time.
- Perfectly symmetrical everything. Real design has tension and hierarchy.
- Every section is the same height with the same padding
- Content centered in a max-w-7xl container with no variation

**Typography sins:**
- One font for everything (usually Inter or the system default)
- Every heading is the same size, just bold
- No real type scale — sizes feel random
- Line heights that are too tight or too loose
- Text blocks that are too wide (over 75 characters per line)

**Color sins:**
- Blue primary + gray everything else
- No accent color, no warmth, no personality
- Gradients that look like 2019 (blue-to-purple on everything)
- Dark mode that's just "invert the colors"

**Animation sins:**
- No animation at all (flat and lifeless)
- OR: everything bounces/fades at the same time
- AOS (Animate on Scroll) with default settings — the "fade-up" on everything look
- No micro-interactions on buttons, inputs, or cards

**Imagery sins:**
- Stock photos of people in meetings pointing at laptops
- Illustrations that are clearly from the same free pack
- No image treatment — raw photos dropped in with no thought
- Icons that don't match (mixing icon libraries)

### 🚫 The Explicit Blacklist

**NEVER use these** — they instantly signal "AI-generated" or "template":

| Category | Blacklisted | Use Instead |
|----------|-------------|-------------|
| **Fonts** | Inter, Roboto, Arial, system-ui | Satoshi, Cabinet Grotesk, Geist, or any from our font list |
| **Colors** | Purple-to-blue gradient on white | Intentional palette with accent color |
| **Colors** | Tailwind's default `blue-500` as primary | Custom brand color with full scale |
| **Layouts** | Hero → 3-col features → testimonials → CTA | Bento grid, asymmetric, editorial, or custom |
| **Radius** | `rounded-lg` on literally everything | Vary: `rounded-xl` cards, `rounded-full` buttons, sharp edges for contrast |
| **Shadows** | Default Tailwind shadows unchanged | Custom shadows with color tint, or none |

When you see these in generated code or templates, **always override them**.

### What Makes a Site Feel Custom

The sites you admire — Stripe, Linear, Vercel, Apple — share these qualities:

1. **Intentionality over intensity.** They pick a direction and commit. Bold OR minimal — never wishy-washy in between.
2. **Intentional restraint.** They don't use every trick. They pick a few things and do them exceptionally well.
3. **Unique typography.** Not just "a nice font" — a deliberate type system with clear hierarchy.
4. **Considered color.** Colors that feel like they belong together, with unexpected accents.
5. **Purposeful whitespace.** Sections breathe. Content doesn't feel crammed.
6. **Motion with meaning.** Things move for a reason — to guide attention, show relationships, or add delight.
7. **Visual consistency.** Every element feels like it belongs to the same family.
8. **One "wow" moment.** A hero animation, an interaction, a visual treatment that makes you pause.

**The rule:** A custom site makes one strong opinion per page. A template site makes zero opinions and hedges everything.

---

## 2. Design Fundamentals

### Typography

Typography is 90% of design. Get this right and you can ship a site with zero images that still looks incredible.

#### Choosing Fonts

**Display / Heading fonts** — High personality, used large:
| Font | Vibe | Source |
|------|------|--------|
| Cabinet Grotesk | Modern, geometric, confident | Fontshare (free) |
| Satoshi | Clean, versatile, contemporary | Fontshare (free) |
| Clash Display | Bold, editorial, distinctive | Fontshare (free) |
| Plus Jakarta Sans | Friendly, rounded, warm | Google Fonts |
| Space Grotesk | Technical, futuristic, sharp | Google Fonts |
| Sora | Geometric, open, modern | Google Fonts |
| General Sans | Versatile, professional | Fontshare (free) |
| Instrument Serif | Elegant, editorial, contrast | Google Fonts |

**Body fonts** — Optimized for readability at 14–18px:
| Font | Vibe | Source |
|------|------|--------|
| Inter | Neutral, safe, ubiquitous (use sparingly) | Google Fonts |
| DM Sans | Geometric, slightly warm | Google Fonts |
| Outfit | Clean, modern, geometric | Google Fonts |
| Source Sans 3 | Professional, readable | Google Fonts |
| Geist | Vercel's font, very clean | Vercel (free) |
| IBM Plex Sans | Technical, authoritative | Google Fonts |

**Paid fonts worth the investment ($25–$100):**
- **Söhne** (Klim Type) — Used by OpenAI, Stripe. The "I'm serious" font.
- **Neue Montreal** (Pangram Pangram) — Used everywhere in modern design.
- **GT Walsheim** — Friendly but professional. Great for SaaS.
- **Roobert** (Displaay) — Modern, slightly quirky. Used by Figma.

#### Type Scale

Don't pick random sizes. Use a scale. Here's the one we recommend:

```css
/* Type scale based on 1.250 ratio (Major Third) */
--text-xs: 0.75rem;    /* 12px */
--text-sm: 0.875rem;   /* 14px */
--text-base: 1rem;     /* 16px — body */
--text-lg: 1.125rem;   /* 18px */
--text-xl: 1.25rem;    /* 20px */
--text-2xl: 1.5rem;    /* 24px */
--text-3xl: 1.875rem;  /* 30px */
--text-4xl: 2.25rem;   /* 36px */
--text-5xl: 3rem;      /* 48px */
--text-6xl: 3.75rem;   /* 60px */
--text-7xl: 4.5rem;    /* 72px */
--text-8xl: 6rem;      /* 96px */
```

**Tailwind already has this built in.** Just use the default scale consistently.

#### Pairing Rules

1. **Contrast is king.** Pair a serif with a sans-serif, or a geometric with a humanist.
2. **Two fonts max.** One for headings, one for body. Three is almost always too many.
3. **Same family works.** A bold weight for headings + regular for body (e.g., Inter Bold + Inter Regular) is clean and safe.
4. **Test at actual sizes.** A font that looks great at 48px might be unreadable at 14px.

**Great pairings:**
- Clash Display + DM Sans (bold + clean)
- Instrument Serif + Inter (editorial + neutral)
- Cabinet Grotesk + Source Sans 3 (modern + readable)
- Space Grotesk + IBM Plex Sans (technical + technical)
- Sora + Outfit (geometric harmony)

#### Where to Find Fonts

| Source | Type | Notes |
|--------|------|-------|
| [Fontshare](https://fontshare.com) | Free, high quality | Best free fonts on the internet. Start here. |
| [Google Fonts](https://fonts.google.com) | Free | Huge selection, variable quality. Stick to the popular ones. |
| [Pangram Pangram](https://pangrampangram.com) | Paid ($) | Neue Montreal, Editorial New. Worth it. |
| [Klim Type](https://klim.co.nz) | Paid ($$) | Söhne, Untitled Sans. Premium quality. |
| [Atipo Foundry](https://www.atipofoundry.com) | Free + Paid | Beautiful display fonts. |
| [Displaay](https://displaay.net) | Paid ($) | Roobert, MD System. Modern. |
| [fonts.bunny.net](https://fonts.bunny.net) | Free | Privacy-friendly Google Fonts alternative |

---

### Color

#### Building a Real Palette

Stop using "blue + gray." Here's how to build a palette that feels intentional:

**Step 1: Pick your brand color.** One color that represents the personality.

**Step 2: Build the full scale.** For your brand color, generate shades from 50 to 950:

```ts
// tailwind.config.ts
const colors = {
  brand: {
    50:  '#f0f5ff',
    100: '#e0ebff',
    200: '#b8d4ff',
    300: '#85b8ff',
    400: '#4d94ff',
    500: '#1a6eff', // ← Your base brand color
    600: '#0052e0',
    700: '#003db8',
    800: '#002d8a',
    900: '#001f5c',
    950: '#00132e',
  },
}
```

**Step 3: Add a neutral that's NOT pure gray.** Warm or cool it slightly:

```ts
// Instead of zinc/gray, use a tinted neutral
neutral: {
  50:  '#fafaf9', // Slightly warm
  100: '#f5f5f4',
  200: '#e7e5e4',
  300: '#d6d3d1',
  400: '#a8a29e',
  500: '#78716c',
  600: '#57534e',
  700: '#44403c',
  800: '#292524',
  900: '#1c1917',
  950: '#0c0a09',
}
```

**Step 4: Add an accent color.** This is the secret weapon. It's used sparingly — on CTAs, highlights, badges:

```ts
accent: {
  // If your brand is blue, try amber/orange as accent
  400: '#fbbf24',
  500: '#f59e0b',
  600: '#d97706',
}
```

**Step 5: Add semantic colors** (success, warning, error, info). Don't overthink these.

#### Gradient Rules

**Do:**
- Subtle gradients on backgrounds (nearly invisible, 2-3% opacity difference)
- Gradient text on headlines (sparingly)
- Mesh gradients for hero backgrounds
- Gradient borders using `border-image` or pseudo-elements

**Don't:**
- Blue-to-purple on buttons (2019 called)
- Gradient backgrounds behind white text cards
- Rainbow gradients unless you're a pride event

```css
/* Subtle background gradient — barely noticeable, adds depth */
.hero-bg {
  background: linear-gradient(
    135deg,
    hsl(220 60% 3%) 0%,
    hsl(240 40% 5%) 50%,
    hsl(260 50% 4%) 100%
  );
}

/* Gradient text — use on ONE heading per page max */
.gradient-text {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
}
```

#### Dark Mode Done Right

Dark mode isn't inverting colors. It's a separate design system:

```ts
// tailwind.config.ts — define dark-specific colors
module.exports = {
  theme: {
    extend: {
      colors: {
        surface: {
          DEFAULT: '#ffffff',    // Light mode
          dark: '#0a0a0b',      // Dark mode — NOT pure black
        },
        'surface-elevated': {
          DEFAULT: '#f8f8f8',
          dark: '#141416',       // Slightly lighter than surface
        },
        'surface-overlay': {
          DEFAULT: '#ffffff',
          dark: '#1e1e22',       // Cards, modals
        },
        border: {
          DEFAULT: '#e5e5e5',
          dark: '#2a2a2e',       // Subtle borders
        },
        'text-primary': {
          DEFAULT: '#171717',
          dark: '#ececec',       // NOT pure white — too harsh
        },
        'text-secondary': {
          DEFAULT: '#737373',
          dark: '#8b8b8b',
        },
      },
    },
  },
}
```

**Dark mode rules:**
1. Background: never pure `#000000`. Use `#0a0a0b` or `#09090b` (very dark gray with slight tint)
2. Text: never pure `#ffffff`. Use `#ececec` or `#e5e5e5`
3. Borders: subtle, around `#2a2a2e` or 10-15% white opacity
4. Elevation = lighter (opposite of light mode where shadows create depth)
5. Reduce contrast on images slightly (`brightness-90` in Tailwind)
6. Colored elements: desaturate slightly for dark backgrounds

---

### Spacing & Rhythm

#### The 8px Grid

Every spacing value should be a multiple of 8 (or 4 for fine details):

```
4px  — tiny gaps, icon padding
8px  — small gaps, inline spacing
12px — compact padding  
16px — default padding, gaps
24px — section inner padding
32px — between related elements
48px — between sections
64px — major section breaks
96px — hero padding, large breaks
128px — dramatic breathing room
```

**In Tailwind:**
```
p-1 = 4px    gap-1 = 4px
p-2 = 8px    gap-2 = 8px
p-3 = 12px   gap-3 = 12px
p-4 = 16px   gap-4 = 16px
p-6 = 24px   gap-6 = 24px
p-8 = 32px   gap-8 = 32px
p-12 = 48px  gap-12 = 48px
p-16 = 64px  gap-16 = 64px
p-24 = 96px  gap-24 = 96px
```

#### Vertical Rhythm

The vertical rhythm of your page is what separates "professional" from "thrown together":

```tsx
{/* Bad — random spacing */}
<section className="py-10">...</section>
<section className="py-14">...</section>
<section className="py-8">...</section>

{/* Good — consistent rhythm */}
<section className="py-24 lg:py-32">...</section>
<section className="py-24 lg:py-32">...</section>
<section className="py-24 lg:py-32">...</section>
```

**The rule:** Pick ONE section padding and use it everywhere. `py-24` (96px) is a great default. `py-32` (128px) for more dramatic breathing room.

#### Breathing Room

The number one thing that makes designs look cheap is **not enough whitespace**.

When in doubt, add more space. Then add more. The first time you think "that's too much space," you're probably getting close to right.

```tsx
{/* Cramped — feels like a template */}
<div className="max-w-6xl mx-auto px-4">
  <h2 className="text-3xl font-bold mb-4">Features</h2>
  <p className="text-gray-600 mb-8">Here's what we offer</p>
  <div className="grid grid-cols-3 gap-4">...</div>
</div>

{/* Breathes — feels intentional */}
<div className="max-w-5xl mx-auto px-6 lg:px-8">
  <h2 className="text-4xl lg:text-5xl font-bold tracking-tight mb-6">Features</h2>
  <p className="text-lg text-neutral-500 max-w-2xl mb-16">Here's what we offer</p>
  <div className="grid grid-cols-3 gap-8 lg:gap-12">...</div>
</div>
```

Key differences:
- Slightly narrower `max-w` (content doesn't need to fill the screen)
- Larger heading with `tracking-tight`
- Constrained paragraph width (`max-w-2xl`)
- Much more margin below the intro text (`mb-16` vs `mb-8`)
- Larger grid gaps

---

### Layout: Breaking the Grid

#### Stop Building the Same Page

The "AI layout" is: Hero → 3-column grid → alternating left-right sections → testimonials → CTA → footer.

Here are alternatives:

**1. Bento Grid Layout**
```tsx
<div className="grid grid-cols-4 grid-rows-3 gap-4 p-4">
  <div className="col-span-2 row-span-2 bg-neutral-900 rounded-3xl p-8">
    {/* Large feature */}
  </div>
  <div className="col-span-1 bg-neutral-800 rounded-3xl p-6">
    {/* Small feature */}
  </div>
  <div className="col-span-1 row-span-2 bg-neutral-800 rounded-3xl p-6">
    {/* Tall feature */}
  </div>
  <div className="col-span-1 bg-neutral-800 rounded-3xl p-6">
    {/* Small feature */}
  </div>
  <div className="col-span-2 bg-neutral-800 rounded-3xl p-6">
    {/* Wide feature */}
  </div>
  <div className="col-span-2 bg-neutral-800 rounded-3xl p-6">
    {/* Wide feature */}
  </div>
</div>
```

**2. Asymmetric Split**
```tsx
<div className="grid grid-cols-12 gap-8 items-center">
  <div className="col-span-5">
    <span className="text-sm font-medium text-brand-500 mb-4 block">About Us</span>
    <h2 className="text-5xl font-bold tracking-tight mb-6">
      We build software that matters
    </h2>
    <p className="text-lg text-neutral-500 leading-relaxed">
      Description text here...
    </p>
  </div>
  <div className="col-span-6 col-start-7">
    {/* Image or visual that's offset */}
    <div className="aspect-[4/3] rounded-2xl overflow-hidden">
      <img src="..." className="w-full h-full object-cover" />
    </div>
  </div>
</div>
```

**3. Editorial / Magazine Layout**
```tsx
<div className="max-w-7xl mx-auto">
  {/* Full-width hero image */}
  <div className="aspect-[21/9] rounded-2xl overflow-hidden mb-16">
    <img src="..." className="w-full h-full object-cover" />
  </div>
  
  {/* Two-column text with dropped cap */}
  <div className="grid grid-cols-12 gap-12">
    <div className="col-span-4">
      <h2 className="text-3xl font-bold sticky top-24">Our Story</h2>
    </div>
    <div className="col-span-7 col-start-6 prose prose-lg">
      <p className="first-letter:text-6xl first-letter:font-bold first-letter:float-left first-letter:mr-3">
        Long form content here...
      </p>
    </div>
  </div>
</div>
```

**4. Overlapping Elements**
```tsx
<div className="relative">
  <div className="bg-brand-500 rounded-3xl p-12 text-white">
    <h2 className="text-4xl font-bold">Main content</h2>
  </div>
  {/* Overlapping card */}
  <div className="absolute -bottom-12 right-12 bg-white rounded-2xl shadow-2xl p-8 w-96">
    <p className="text-neutral-600">This card breaks the grid and adds visual interest</p>
  </div>
</div>
```

---

### Photography & Imagery

#### Real vs Stock

**Always prefer:**
- Real photography of your actual product/team/space
- Custom illustrations that match your brand style
- Screenshots with thoughtful framing and device mockups
- Abstract/geometric backgrounds you create

**When you must use stock:**
- [Unsplash](https://unsplash.com) — Best free photos
- [Pexels](https://pexels.com) — Good alternative
- **Edit them.** Don't use stock photos raw. Apply treatments:

```css
/* Duotone treatment — makes any stock photo feel on-brand */
.duotone {
  filter: grayscale(100%) contrast(1.1);
  mix-blend-mode: multiply;
}
.duotone-wrapper {
  background-color: #1a6eff; /* Your brand color */
  position: relative;
}

/* Subtle grain overlay — adds texture and removes the "stock" feel */
.grain::after {
  content: '';
  position: absolute;
  inset: 0;
  background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)' opacity='0.04'/%3E%3C/svg%3E");
  pointer-events: none;
}
```

#### Illustration Styles That Work

- **Linear illustrations** — Simple line art in brand colors
- **Isometric** — 3D but flat (good for product features)
- **Abstract shapes** — Blobs, gradients, geometric patterns
- **Hand-drawn** — Adds warmth, especially for friendly brands

**Sources:**
- [unDraw](https://undraw.co) — Free customizable illustrations
- [Storyset](https://storyset.com) — Animated illustrations
- [Humaaans](https://humaaans.com) — Mix-and-match people illustrations
- [Blush](https://blush.design) — Collections from various artists

---

## 3. Animation & Motion Design

### Principles of Good Motion

#### The Three Rules

1. **Every animation needs a reason.** "It looks cool" isn't enough. Does it guide attention? Show a relationship? Provide feedback? Add delight at a moment that matters?

2. **Fast is better than slow.** Most animations should be 200-400ms. Longer feels sluggish. Exception: large movements (page transitions) can be 500-800ms.

3. **Easing is everything.** Linear animation looks robotic. Always use easing:

```ts
// Good easing curves for web
const easings = {
  // Default for most animations — smooth deceleration
  easeOut: [0, 0, 0.2, 1],
  
  // Enters and exits — feels natural
  easeInOut: [0.4, 0, 0.2, 1],
  
  // Snappy, modern feel — great for UI elements
  snappy: [0.16, 1, 0.3, 1],
  
  // Spring-like — for playful interactions
  spring: { type: "spring", stiffness: 300, damping: 30 },
  
  // Dramatic entrance — for hero elements
  dramatic: [0.22, 1, 0.36, 1],
}
```

#### Duration Guide

| Element | Duration | Easing |
|---------|----------|--------|
| Hover states | 150-200ms | ease-out |
| Tooltips | 150ms | ease-out |
| Button feedback | 100-150ms | ease-out |
| Dropdown open | 200-250ms | ease-out |
| Modal open | 250-350ms | ease-in-out |
| Page transition | 400-600ms | ease-in-out |
| Scroll reveal | 500-800ms | ease-out |
| Stagger delay | 50-100ms between items | — |

---

### Micro-Interactions

These are the small animations that make a UI feel alive. They're subtle but critical.

#### Button Hovers

```tsx
// Basic elevated button with hover
const Button = ({ children, ...props }: ButtonProps) => (
  <button
    className="
      relative px-6 py-3 bg-brand-500 text-white rounded-xl font-medium
      transition-all duration-200
      hover:bg-brand-600 hover:shadow-lg hover:shadow-brand-500/25
      hover:-translate-y-0.5
      active:translate-y-0 active:shadow-md
      focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2
    "
    {...props}
  >
    {children}
  </button>
);

// Button with animated arrow
const ArrowButton = ({ children }: { children: React.ReactNode }) => (
  <button className="group flex items-center gap-2 px-6 py-3 bg-brand-500 text-white rounded-xl font-medium transition-all duration-200 hover:bg-brand-600">
    {children}
    <svg
      className="w-4 h-4 transition-transform duration-200 group-hover:translate-x-1"
      fill="none" viewBox="0 0 24 24" stroke="currentColor"
    >
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 8l4 4m0 0l-4 4m4-4H3" />
    </svg>
  </button>
);

// Magnetic button (follows cursor slightly)
import { motion, useMotionValue, useSpring } from 'framer-motion';

const MagneticButton = ({ children }: { children: React.ReactNode }) => {
  const x = useMotionValue(0);
  const y = useMotionValue(0);
  const springX = useSpring(x, { stiffness: 300, damping: 20 });
  const springY = useSpring(y, { stiffness: 300, damping: 20 });

  const handleMouse = (e: React.MouseEvent<HTMLButtonElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    x.set((e.clientX - rect.left - rect.width / 2) * 0.15);
    y.set((e.clientY - rect.top - rect.height / 2) * 0.15);
  };

  return (
    <motion.button
      style={{ x: springX, y: springY }}
      onMouseMove={handleMouse}
      onMouseLeave={() => { x.set(0); y.set(0); }}
      className="px-8 py-4 bg-white text-black rounded-full font-medium text-lg"
    >
      {children}
    </motion.button>
  );
};
```

#### Form Feedback

```tsx
// Input with animated label (floating label pattern)
const FloatingInput = ({ label, ...props }: { label: string } & React.InputHTMLAttributes<HTMLInputElement>) => (
  <div className="relative">
    <input
      {...props}
      placeholder=" "
      className="
        peer w-full px-4 pt-6 pb-2 bg-neutral-50 dark:bg-neutral-900
        border border-neutral-200 dark:border-neutral-800 rounded-xl
        text-neutral-900 dark:text-neutral-100
        transition-colors duration-200
        focus:border-brand-500 focus:ring-1 focus:ring-brand-500
        focus:outline-none
      "
    />
    <label className="
      absolute left-4 top-4 text-neutral-400
      transition-all duration-200 pointer-events-none
      peer-focus:top-2 peer-focus:text-xs peer-focus:text-brand-500
      peer-[:not(:placeholder-shown)]:top-2 peer-[:not(:placeholder-shown)]:text-xs
    ">
      {label}
    </label>
  </div>
);

// Animated checkbox
const Checkbox = ({ checked, onChange }: { checked: boolean; onChange: () => void }) => (
  <button
    role="checkbox"
    aria-checked={checked}
    onClick={onChange}
    className={`
      w-5 h-5 rounded-md border-2 transition-all duration-200
      flex items-center justify-center
      ${checked
        ? 'bg-brand-500 border-brand-500 scale-100'
        : 'border-neutral-300 hover:border-brand-400 scale-100'
      }
    `}
  >
    <svg
      className={`w-3 h-3 text-white transition-all duration-200 ${
        checked ? 'opacity-100 scale-100' : 'opacity-0 scale-75'
      }`}
      fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}
    >
      <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
    </svg>
  </button>
);
```

#### Toggle States

```tsx
import { motion } from 'framer-motion';

const Toggle = ({ enabled, onToggle }: { enabled: boolean; onToggle: () => void }) => (
  <button
    onClick={onToggle}
    className={`
      relative w-12 h-7 rounded-full transition-colors duration-300
      ${enabled ? 'bg-brand-500' : 'bg-neutral-300 dark:bg-neutral-700'}
    `}
  >
    <motion.div
      className="absolute top-0.5 left-0.5 w-6 h-6 bg-white rounded-full shadow-md"
      animate={{ x: enabled ? 20 : 0 }}
      transition={{ type: "spring", stiffness: 500, damping: 30 }}
    />
  </button>
);
```

#### Tooltips

```tsx
import { motion, AnimatePresence } from 'framer-motion';
import { useState } from 'react';

const Tooltip = ({ content, children }: { content: string; children: React.ReactNode }) => {
  const [show, setShow] = useState(false);

  return (
    <div className="relative inline-block" onMouseEnter={() => setShow(true)} onMouseLeave={() => setShow(false)}>
      {children}
      <AnimatePresence>
        {show && (
          <motion.div
            initial={{ opacity: 0, y: 4, scale: 0.95 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 4, scale: 0.95 }}
            transition={{ duration: 0.15 }}
            className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 px-3 py-1.5 bg-neutral-900 text-white text-sm rounded-lg whitespace-nowrap"
          >
            {content}
            <div className="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-neutral-900" />
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
};
```

---

### Scroll Animations

#### Reveal on Scroll

```tsx
import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';

// Simple fade-up on scroll
const FadeUp = ({ children, delay = 0 }: { children: React.ReactNode; delay?: number }) => {
  const ref = useRef(null);
  const isInView = useInView(ref, { once: true, margin: "-100px" });

  return (
    <motion.div
      ref={ref}
      initial={{ opacity: 0, y: 30 }}
      animate={isInView ? { opacity: 1, y: 0 } : { opacity: 0, y: 30 }}
      transition={{ duration: 0.6, delay, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  );
};

// Staggered children on scroll
const StaggerContainer = ({ children }: { children: React.ReactNode }) => {
  const ref = useRef(null);
  const isInView = useInView(ref, { once: true, margin: "-100px" });

  return (
    <motion.div
      ref={ref}
      initial="hidden"
      animate={isInView ? "visible" : "hidden"}
      variants={{
        hidden: {},
        visible: { transition: { staggerChildren: 0.08 } },
      }}
    >
      {children}
    </motion.div>
  );
};

const StaggerItem = ({ children }: { children: React.ReactNode }) => (
  <motion.div
    variants={{
      hidden: { opacity: 0, y: 20 },
      visible: { opacity: 1, y: 0, transition: { duration: 0.5, ease: [0.22, 1, 0.36, 1] } },
    }}
  >
    {children}
  </motion.div>
);

// Usage
<StaggerContainer>
  <StaggerItem><Card /></StaggerItem>
  <StaggerItem><Card /></StaggerItem>
  <StaggerItem><Card /></StaggerItem>
</StaggerContainer>
```

#### Parallax

```tsx
import { motion, useScroll, useTransform } from 'framer-motion';
import { useRef } from 'react';

const ParallaxImage = ({ src, alt }: { src: string; alt: string }) => {
  const ref = useRef(null);
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: ["start end", "end start"],
  });
  const y = useTransform(scrollYProgress, [0, 1], ["-10%", "10%"]);

  return (
    <div ref={ref} className="overflow-hidden rounded-2xl h-[400px]">
      <motion.img
        src={src}
        alt={alt}
        style={{ y }}
        className="w-full h-[120%] object-cover"
      />
    </div>
  );
};

// Parallax text + image section
const ParallaxSection = () => {
  const ref = useRef(null);
  const { scrollYProgress } = useScroll({
    target: ref,
    offset: ["start end", "end start"],
  });
  const textY = useTransform(scrollYProgress, [0, 1], ["0%", "-15%"]);
  const imageY = useTransform(scrollYProgress, [0, 1], ["0%", "10%"]);

  return (
    <div ref={ref} className="grid grid-cols-2 gap-16 items-center py-32">
      <motion.div style={{ y: textY }}>
        <h2 className="text-5xl font-bold tracking-tight">Moving at different speeds</h2>
        <p className="mt-6 text-lg text-neutral-500">This text moves slower than the image, creating depth.</p>
      </motion.div>
      <motion.div style={{ y: imageY }} className="rounded-2xl overflow-hidden">
        <img src="/feature.jpg" alt="" className="w-full" />
      </motion.div>
    </div>
  );
};
```

#### Sticky Elements

```tsx
// Sticky heading with scrolling content
const StickySection = () => (
  <div className="grid grid-cols-12 gap-16 py-32">
    <div className="col-span-5">
      <div className="sticky top-32">
        <span className="text-sm font-medium text-brand-500 mb-4 block uppercase tracking-wider">Features</span>
        <h2 className="text-5xl font-bold tracking-tight mb-6">
          Everything you need to build faster
        </h2>
        <p className="text-lg text-neutral-500">
          Our platform gives you the tools to ship better products in less time.
        </p>
      </div>
    </div>
    <div className="col-span-6 col-start-7 space-y-8">
      {features.map((feature) => (
        <div key={feature.title} className="p-8 rounded-2xl bg-neutral-50 dark:bg-neutral-900">
          <div className="w-12 h-12 rounded-xl bg-brand-100 dark:bg-brand-900/30 flex items-center justify-center mb-6">
            <feature.icon className="w-6 h-6 text-brand-500" />
          </div>
          <h3 className="text-xl font-semibold mb-3">{feature.title}</h3>
          <p className="text-neutral-500 leading-relaxed">{feature.description}</p>
        </div>
      ))}
    </div>
  </div>
);
```

#### Scroll Progress Indicator

```tsx
import { motion, useScroll } from 'framer-motion';

const ScrollProgress = () => {
  const { scrollYProgress } = useScroll();

  return (
    <motion.div
      className="fixed top-0 left-0 right-0 h-0.5 bg-brand-500 origin-left z-50"
      style={{ scaleX: scrollYProgress }}
    />
  );
};
```

---

### Page Transitions

```tsx
// app/template.tsx (Next.js App Router) or layout wrapper
import { motion, AnimatePresence } from 'framer-motion';

const PageTransition = ({ children }: { children: React.ReactNode }) => (
  <AnimatePresence mode="wait">
    <motion.div
      initial={{ opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -8 }}
      transition={{ duration: 0.3, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  </AnimatePresence>
);

// For React Router:
import { useLocation } from 'react-router-dom';

const App = () => {
  const location = useLocation();

  return (
    <AnimatePresence mode="wait">
      <motion.div
        key={location.pathname}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        transition={{ duration: 0.25 }}
      >
        <Routes location={location}>
          {/* routes */}
        </Routes>
      </motion.div>
    </AnimatePresence>
  );
};
```

---

### Loading States

#### Skeleton Screens

```tsx
const Skeleton = ({ className }: { className?: string }) => (
  <div className={`animate-pulse bg-neutral-200 dark:bg-neutral-800 rounded-lg ${className}`} />
);

// Card skeleton
const CardSkeleton = () => (
  <div className="p-6 rounded-2xl border border-neutral-200 dark:border-neutral-800">
    <Skeleton className="h-48 w-full rounded-xl mb-4" />
    <Skeleton className="h-5 w-3/4 mb-3" />
    <Skeleton className="h-4 w-full mb-2" />
    <Skeleton className="h-4 w-2/3" />
  </div>
);
```

#### Shimmer Effect

```tsx
const Shimmer = ({ className }: { className?: string }) => (
  <div className={`relative overflow-hidden bg-neutral-200 dark:bg-neutral-800 rounded-lg ${className}`}>
    <div className="absolute inset-0 -translate-x-full animate-[shimmer_2s_infinite] bg-gradient-to-r from-transparent via-white/20 to-transparent" />
  </div>
);

// Add to tailwind.config.ts:
// animation: { shimmer: 'shimmer 2s infinite' }
// keyframes: { shimmer: { '100%': { transform: 'translateX(100%)' } } }
```

#### Progressive Loading

```tsx
import { motion } from 'framer-motion';
import { useState } from 'react';

const ProgressiveImage = ({ src, alt, className }: { src: string; alt: string; className?: string }) => {
  const [loaded, setLoaded] = useState(false);

  return (
    <div className={`relative overflow-hidden ${className}`}>
      {/* Blur placeholder */}
      {!loaded && (
        <div className="absolute inset-0 bg-neutral-200 dark:bg-neutral-800 animate-pulse" />
      )}
      <motion.img
        src={src}
        alt={alt}
        onLoad={() => setLoaded(true)}
        initial={{ opacity: 0, scale: 1.05 }}
        animate={loaded ? { opacity: 1, scale: 1 } : {}}
        transition={{ duration: 0.6, ease: "easeOut" }}
        className="w-full h-full object-cover"
      />
    </div>
  );
};
```

---

### Hero Animations

#### Text Reveal

```tsx
import { motion } from 'framer-motion';

// Word-by-word reveal
const WordReveal = ({ text, className }: { text: string; className?: string }) => {
  const words = text.split(' ');

  return (
    <motion.h1
      className={className}
      initial="hidden"
      animate="visible"
      variants={{ visible: { transition: { staggerChildren: 0.06 } } }}
    >
      {words.map((word, i) => (
        <span key={i} className="inline-block overflow-hidden mr-[0.25em]">
          <motion.span
            className="inline-block"
            variants={{
              hidden: { y: '100%', opacity: 0 },
              visible: { y: 0, opacity: 1, transition: { duration: 0.5, ease: [0.22, 1, 0.36, 1] } },
            }}
          >
            {word}
          </motion.span>
        </span>
      ))}
    </motion.h1>
  );
};

// Character-by-character reveal
const CharReveal = ({ text, className }: { text: string; className?: string }) => (
  <motion.h1
    className={className}
    initial="hidden"
    animate="visible"
    variants={{ visible: { transition: { staggerChildren: 0.02 } } }}
  >
    {text.split('').map((char, i) => (
      <motion.span
        key={i}
        className="inline-block"
        variants={{
          hidden: { opacity: 0, y: 20 },
          visible: { opacity: 1, y: 0, transition: { duration: 0.4, ease: [0.22, 1, 0.36, 1] } },
        }}
      >
        {char === ' ' ? '\u00A0' : char}
      </motion.span>
    ))}
  </motion.h1>
);

// Line reveal (clip-path)
const LineReveal = ({ children, delay = 0 }: { children: React.ReactNode; delay?: number }) => (
  <div className="overflow-hidden">
    <motion.div
      initial={{ y: '100%' }}
      animate={{ y: 0 }}
      transition={{ duration: 0.8, delay, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  </div>
);
```

#### Staggered Hero Entrance

```tsx
const Hero = () => (
  <section className="min-h-screen flex items-center justify-center px-6">
    <div className="max-w-4xl text-center">
      <motion.div
        initial={{ opacity: 0, scale: 0.9 }}
        animate={{ opacity: 1, scale: 1 }}
        transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
      >
        <span className="inline-block px-4 py-1.5 bg-brand-50 dark:bg-brand-950 text-brand-600 dark:text-brand-400 text-sm font-medium rounded-full mb-8">
          Now in Beta
        </span>
      </motion.div>

      <motion.h1
        className="text-6xl lg:text-8xl font-bold tracking-tight mb-8"
        initial={{ opacity: 0, y: 30 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.8, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
      >
        Build something{' '}
        <span className="bg-gradient-to-r from-brand-400 to-purple-500 bg-clip-text text-transparent">
          beautiful
        </span>
      </motion.h1>

      <motion.p
        className="text-xl text-neutral-500 max-w-2xl mx-auto mb-12"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.6, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
      >
        The modern platform for building exceptional web experiences.
        Ship faster, look better.
      </motion.p>

      <motion.div
        className="flex items-center justify-center gap-4"
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.6, delay: 0.5, ease: [0.22, 1, 0.36, 1] }}
      >
        <button className="px-8 py-4 bg-brand-500 text-white rounded-xl font-medium text-lg hover:bg-brand-600 transition-colors">
          Get Started
        </button>
        <button className="px-8 py-4 bg-neutral-100 dark:bg-neutral-800 text-neutral-900 dark:text-white rounded-xl font-medium text-lg hover:bg-neutral-200 dark:hover:bg-neutral-700 transition-colors">
          View Demo
        </button>
      </motion.div>
    </div>
  </section>
);
```

#### Background Effects

```tsx
// Gradient orbs (like Linear/Vercel)
const GradientOrbs = () => (
  <div className="absolute inset-0 overflow-hidden pointer-events-none">
    <div className="absolute top-1/4 -left-1/4 w-96 h-96 bg-brand-500/20 rounded-full blur-3xl animate-pulse" />
    <div className="absolute top-1/3 -right-1/4 w-96 h-96 bg-purple-500/20 rounded-full blur-3xl animate-pulse [animation-delay:1s]" />
    <div className="absolute -bottom-1/4 left-1/3 w-96 h-96 bg-cyan-500/15 rounded-full blur-3xl animate-pulse [animation-delay:2s]" />
  </div>
);

// Grid background (like Vercel)
const GridBackground = () => (
  <div className="absolute inset-0 pointer-events-none">
    <div className="absolute inset-0 bg-[linear-gradient(to_right,#80808012_1px,transparent_1px),linear-gradient(to_bottom,#80808012_1px,transparent_1px)] bg-[size:24px_24px]" />
    <div className="absolute inset-0 bg-gradient-to-b from-transparent via-transparent to-white dark:to-neutral-950" />
  </div>
);

// Dot pattern background
const DotPattern = () => (
  <div className="absolute inset-0 pointer-events-none">
    <div className="absolute inset-0 bg-[radial-gradient(#80808020_1px,transparent_1px)] bg-[size:20px_20px]" />
  </div>
);

// Noise texture overlay
const NoiseOverlay = () => (
  <div 
    className="absolute inset-0 pointer-events-none opacity-[0.03]"
    style={{
      backgroundImage: `url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")`,
    }}
  />
);
```

---

## 4. Code Examples (React + TypeScript + Tailwind + Framer Motion)

### Framer Motion Recipes

#### Fade In

```tsx
import { motion } from 'framer-motion';

const FadeIn = ({ children, delay = 0 }: { children: React.ReactNode; delay?: number }) => (
  <motion.div
    initial={{ opacity: 0 }}
    animate={{ opacity: 1 }}
    transition={{ duration: 0.5, delay }}
  >
    {children}
  </motion.div>
);
```

#### Slide Up

```tsx
const SlideUp = ({ children, delay = 0 }: { children: React.ReactNode; delay?: number }) => (
  <motion.div
    initial={{ opacity: 0, y: 24 }}
    animate={{ opacity: 1, y: 0 }}
    transition={{ duration: 0.6, delay, ease: [0.22, 1, 0.36, 1] }}
  >
    {children}
  </motion.div>
);
```

#### Stagger Children

```tsx
const container = {
  hidden: { opacity: 0 },
  visible: {
    opacity: 1,
    transition: { staggerChildren: 0.08, delayChildren: 0.1 },
  },
};

const item = {
  hidden: { opacity: 0, y: 20 },
  visible: {
    opacity: 1,
    y: 0,
    transition: { duration: 0.5, ease: [0.22, 1, 0.36, 1] },
  },
};

const StaggerList = ({ items }: { items: string[] }) => (
  <motion.ul variants={container} initial="hidden" animate="visible">
    {items.map((text) => (
      <motion.li key={text} variants={item}>
        {text}
      </motion.li>
    ))}
  </motion.ul>
);
```

#### Scroll-Triggered

```tsx
import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';

const ScrollReveal = ({
  children,
  width = "100%",
}: {
  children: React.ReactNode;
  width?: string;
}) => {
  const ref = useRef(null);
  const isInView = useInView(ref, { once: true, margin: "-15%" });

  return (
    <div ref={ref} style={{ width }}>
      <motion.div
        initial={{ opacity: 0, y: 40, filter: "blur(4px)" }}
        animate={isInView ? { opacity: 1, y: 0, filter: "blur(0px)" } : {}}
        transition={{ duration: 0.7, ease: [0.22, 1, 0.36, 1] }}
      >
        {children}
      </motion.div>
    </div>
  );
};
```

#### Layout Animations

```tsx
import { motion, LayoutGroup } from 'framer-motion';
import { useState } from 'react';

// Animated tabs
const Tabs = ({ tabs }: { tabs: { id: string; label: string }[] }) => {
  const [active, setActive] = useState(tabs[0].id);

  return (
    <LayoutGroup>
      <div className="flex gap-1 bg-neutral-100 dark:bg-neutral-800 p-1 rounded-xl">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActive(tab.id)}
            className="relative px-4 py-2 text-sm font-medium rounded-lg transition-colors"
          >
            {active === tab.id && (
              <motion.div
                layoutId="activeTab"
                className="absolute inset-0 bg-white dark:bg-neutral-700 rounded-lg shadow-sm"
                transition={{ type: "spring", stiffness: 400, damping: 30 }}
              />
            )}
            <span className="relative z-10">{tab.label}</span>
          </button>
        ))}
      </div>
    </LayoutGroup>
  );
};

// Expandable card
const ExpandableCard = ({ title, content }: { title: string; content: string }) => {
  const [expanded, setExpanded] = useState(false);

  return (
    <motion.div
      layout
      onClick={() => setExpanded(!expanded)}
      className="p-6 rounded-2xl bg-white dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-800 cursor-pointer overflow-hidden"
      transition={{ layout: { duration: 0.3, ease: [0.22, 1, 0.36, 1] } }}
    >
      <motion.h3 layout="position" className="text-lg font-semibold">
        {title}
      </motion.h3>
      <AnimatePresence>
        {expanded && (
          <motion.p
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={{ opacity: 0, height: 0 }}
            className="text-neutral-500 mt-4"
          >
            {content}
          </motion.p>
        )}
      </AnimatePresence>
    </motion.div>
  );
};
```

---

### GSAP + ScrollTrigger

Install:
```bash
npm install gsap @gsap/react
```

#### Parallax Section

```tsx
import { useRef, useEffect } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

gsap.registerPlugin(ScrollTrigger);

const GSAPParallax = () => {
  const sectionRef = useRef<HTMLDivElement>(null);
  const bgRef = useRef<HTMLDivElement>(null);
  const textRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      gsap.to(bgRef.current, {
        yPercent: -20,
        ease: 'none',
        scrollTrigger: {
          trigger: sectionRef.current,
          start: 'top bottom',
          end: 'bottom top',
          scrub: true,
        },
      });

      gsap.from(textRef.current, {
        y: 60,
        opacity: 0,
        duration: 1,
        ease: 'power3.out',
        scrollTrigger: {
          trigger: sectionRef.current,
          start: 'top 70%',
        },
      });
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <div ref={sectionRef} className="relative h-screen overflow-hidden">
      <div ref={bgRef} className="absolute inset-0 scale-125">
        <img src="/hero-bg.jpg" className="w-full h-full object-cover" alt="" />
      </div>
      <div ref={textRef} className="relative z-10 flex items-center justify-center h-full">
        <h1 className="text-7xl font-bold text-white">Parallax Hero</h1>
      </div>
    </div>
  );
};
```

#### Pin Sections (Scroll-Locked Content)

```tsx
const PinSection = () => {
  const containerRef = useRef<HTMLDivElement>(null);
  const panelsRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      const panels = gsap.utils.toArray<HTMLElement>('.panel');

      gsap.to(panels, {
        xPercent: -100 * (panels.length - 1),
        ease: 'none',
        scrollTrigger: {
          trigger: containerRef.current,
          pin: true,
          scrub: 1,
          snap: 1 / (panels.length - 1),
          end: () => `+=${containerRef.current!.offsetWidth}`,
        },
      });
    }, containerRef);

    return () => ctx.revert();
  }, []);

  return (
    <div ref={containerRef} className="overflow-hidden">
      <div ref={panelsRef} className="flex w-[400vw] h-screen">
        <div className="panel w-screen h-full flex items-center justify-center bg-brand-500">
          <h2 className="text-6xl font-bold text-white">Section 1</h2>
        </div>
        <div className="panel w-screen h-full flex items-center justify-center bg-purple-500">
          <h2 className="text-6xl font-bold text-white">Section 2</h2>
        </div>
        <div className="panel w-screen h-full flex items-center justify-center bg-cyan-500">
          <h2 className="text-6xl font-bold text-white">Section 3</h2>
        </div>
        <div className="panel w-screen h-full flex items-center justify-center bg-amber-500">
          <h2 className="text-6xl font-bold text-white">Section 4</h2>
        </div>
      </div>
    </div>
  );
};
```

#### Text Split Animation

```tsx
const TextSplitReveal = () => {
  const textRef = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    if (!textRef.current) return;
    
    // Split text into spans
    const text = textRef.current.innerText;
    textRef.current.innerHTML = text
      .split('')
      .map((char) => `<span class="inline-block">${char === ' ' ? '&nbsp;' : char}</span>`)
      .join('');

    const chars = textRef.current.querySelectorAll('span');

    const ctx = gsap.context(() => {
      gsap.from(chars, {
        y: 80,
        opacity: 0,
        rotateX: -90,
        stagger: 0.02,
        duration: 0.8,
        ease: 'back.out(1.7)',
        scrollTrigger: {
          trigger: textRef.current,
          start: 'top 80%',
        },
      });
    });

    return () => ctx.revert();
  }, []);

  return (
    <h2 ref={textRef} className="text-6xl font-bold" style={{ perspective: '500px' }}>
      Words that come alive
    </h2>
  );
};
```

---

### CSS-Only Effects

#### Hover Effects

```css
/* Card hover with subtle lift */
.card-hover {
  transition: transform 0.2s ease, box-shadow 0.2s ease;
}
.card-hover:hover {
  transform: translateY(-4px);
  box-shadow: 0 20px 40px -12px rgba(0, 0, 0, 0.1);
}

/* Underline grow from center */
.link-underline {
  position: relative;
}
.link-underline::after {
  content: '';
  position: absolute;
  bottom: -2px;
  left: 50%;
  width: 0;
  height: 2px;
  background: currentColor;
  transition: width 0.3s ease, left 0.3s ease;
}
.link-underline:hover::after {
  width: 100%;
  left: 0;
}

/* Gradient border on hover */
.gradient-border {
  position: relative;
  background: white;
  border-radius: 16px;
  padding: 2px;
  transition: all 0.3s ease;
}
.gradient-border::before {
  content: '';
  position: absolute;
  inset: 0;
  border-radius: 16px;
  padding: 2px;
  background: linear-gradient(135deg, #667eea, #764ba2);
  -webkit-mask: linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0);
  -webkit-mask-composite: xor;
  mask-composite: exclude;
  opacity: 0;
  transition: opacity 0.3s ease;
}
.gradient-border:hover::before {
  opacity: 1;
}

/* Image zoom on hover */
.image-zoom {
  overflow: hidden;
  border-radius: 16px;
}
.image-zoom img {
  transition: transform 0.6s cubic-bezier(0.22, 1, 0.36, 1);
}
.image-zoom:hover img {
  transform: scale(1.05);
}

/* Glow effect on hover */
.glow-hover {
  transition: box-shadow 0.3s ease;
}
.glow-hover:hover {
  box-shadow: 0 0 30px rgba(59, 130, 246, 0.3);
}
```

#### Custom Properties for Theming

```css
:root {
  /* Colors */
  --color-brand: 220 90% 56%;
  --color-accent: 38 92% 50%;
  --color-surface: 0 0% 100%;
  --color-surface-elevated: 0 0% 97%;
  --color-text-primary: 0 0% 9%;
  --color-text-secondary: 0 0% 45%;
  --color-border: 0 0% 90%;
  
  /* Spacing */
  --section-padding: 6rem;
  --container-max: 72rem;
  --container-padding: 1.5rem;
  
  /* Animation */
  --ease-out: cubic-bezier(0.22, 1, 0.36, 1);
  --ease-spring: cubic-bezier(0.16, 1, 0.3, 1);
  --duration-fast: 150ms;
  --duration-normal: 300ms;
  --duration-slow: 500ms;
  
  /* Radius */
  --radius-sm: 0.5rem;
  --radius-md: 0.75rem;
  --radius-lg: 1rem;
  --radius-xl: 1.5rem;
  --radius-full: 9999px;
}

.dark {
  --color-surface: 240 6% 4%;
  --color-surface-elevated: 240 5% 8%;
  --color-text-primary: 0 0% 93%;
  --color-text-secondary: 0 0% 55%;
  --color-border: 240 5% 16%;
}
```

In Tailwind, use these via `theme.extend`:

```ts
// tailwind.config.ts
export default {
  theme: {
    extend: {
      colors: {
        brand: 'hsl(var(--color-brand) / <alpha-value>)',
        accent: 'hsl(var(--color-accent) / <alpha-value>)',
        surface: {
          DEFAULT: 'hsl(var(--color-surface) / <alpha-value>)',
          elevated: 'hsl(var(--color-surface-elevated) / <alpha-value>)',
        },
      },
      transitionTimingFunction: {
        'out-custom': 'cubic-bezier(0.22, 1, 0.36, 1)',
        'spring': 'cubic-bezier(0.16, 1, 0.3, 1)',
      },
    },
  },
};
```

---

### Lenis Smooth Scroll

```bash
npm install lenis
```

```tsx
// components/SmoothScroll.tsx
'use client';

import { useEffect } from 'react';
import Lenis from 'lenis';

const SmoothScroll = ({ children }: { children: React.ReactNode }) => {
  useEffect(() => {
    const lenis = new Lenis({
      duration: 1.2,
      easing: (t: number) => Math.min(1, 1.001 - Math.pow(2, -10 * t)),
      touchMultiplier: 2,
    });

    function raf(time: number) {
      lenis.raf(time);
      requestAnimationFrame(raf);
    }

    requestAnimationFrame(raf);

    return () => lenis.destroy();
  }, []);

  return <>{children}</>;
};

export default SmoothScroll;

// Usage in layout:
// <SmoothScroll><main>{children}</main></SmoothScroll>
```

**Lenis + GSAP ScrollTrigger integration:**
```tsx
useEffect(() => {
  const lenis = new Lenis();

  lenis.on('scroll', ScrollTrigger.update);

  gsap.ticker.add((time) => {
    lenis.raf(time * 1000);
  });

  gsap.ticker.lagSmoothing(0);

  return () => {
    lenis.destroy();
    gsap.ticker.remove(lenis.raf);
  };
}, []);
```

---

### Tailwind Tricks

#### Custom Animations in tailwind.config.ts

```ts
// tailwind.config.ts
export default {
  theme: {
    extend: {
      animation: {
        'fade-in': 'fadeIn 0.5s ease-out',
        'fade-up': 'fadeUp 0.6s cubic-bezier(0.22, 1, 0.36, 1)',
        'slide-in-right': 'slideInRight 0.4s cubic-bezier(0.22, 1, 0.36, 1)',
        'scale-in': 'scaleIn 0.3s cubic-bezier(0.22, 1, 0.36, 1)',
        'spin-slow': 'spin 3s linear infinite',
        'bounce-subtle': 'bounceSubtle 2s ease-in-out infinite',
        'shimmer': 'shimmer 2s linear infinite',
        'float': 'float 6s ease-in-out infinite',
        'gradient': 'gradient 8s ease infinite',
      },
      keyframes: {
        fadeIn: {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
        fadeUp: {
          '0%': { opacity: '0', transform: 'translateY(20px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
        slideInRight: {
          '0%': { opacity: '0', transform: 'translateX(-20px)' },
          '100%': { opacity: '1', transform: 'translateX(0)' },
        },
        scaleIn: {
          '0%': { opacity: '0', transform: 'scale(0.95)' },
          '100%': { opacity: '1', transform: 'scale(1)' },
        },
        bounceSubtle: {
          '0%, 100%': { transform: 'translateY(0)' },
          '50%': { transform: 'translateY(-6px)' },
        },
        shimmer: {
          '0%': { transform: 'translateX(-100%)' },
          '100%': { transform: 'translateX(100%)' },
        },
        float: {
          '0%, 100%': { transform: 'translateY(0)' },
          '50%': { transform: 'translateY(-20px)' },
        },
        gradient: {
          '0%, 100%': { backgroundPosition: '0% 50%' },
          '50%': { backgroundPosition: '100% 50%' },
        },
      },
    },
  },
};
```

#### Group-Hover Patterns

```tsx
{/* Card where hovering the card affects child elements */}
<div className="group relative p-8 rounded-2xl border border-neutral-200 dark:border-neutral-800 transition-all duration-300 hover:border-brand-500/50 hover:shadow-lg hover:shadow-brand-500/5">
  {/* Icon changes color on card hover */}
  <div className="w-12 h-12 rounded-xl bg-neutral-100 dark:bg-neutral-800 flex items-center justify-center mb-6 transition-colors group-hover:bg-brand-500 group-hover:text-white">
    <Icon className="w-6 h-6" />
  </div>
  
  {/* Title */}
  <h3 className="text-xl font-semibold mb-3 group-hover:text-brand-500 transition-colors">
    Feature Title
  </h3>
  
  {/* Arrow appears on hover */}
  <div className="absolute bottom-8 right-8 opacity-0 transform translate-x-2 transition-all duration-300 group-hover:opacity-100 group-hover:translate-x-0">
    <ArrowRight className="w-5 h-5 text-brand-500" />
  </div>
</div>
```

#### Animation Delays with Stagger

```tsx
{/* Stagger delay using Tailwind arbitrary values */}
{items.map((item, i) => (
  <div
    key={item.id}
    className="animate-fade-up opacity-0"
    style={{ animationDelay: `${i * 100}ms`, animationFillMode: 'forwards' }}
  >
    <Card {...item} />
  </div>
))}

{/* Or with CSS custom properties */}
{items.map((item, i) => (
  <div
    key={item.id}
    className="animate-fade-up opacity-0 [animation-fill-mode:forwards]"
    style={{ '--delay': `${i * 100}ms`, animationDelay: 'var(--delay)' } as React.CSSProperties}
  >
    <Card {...item} />
  </div>
))}
```

---

## 5. Component Patterns: Elevated vs Generic

For each component, I'll show the **generic** version (what AI/templates produce) and the **elevated** version (what ships on sites you admire).

### Hero Sections

#### ❌ Generic Hero

```tsx
const GenericHero = () => (
  <section className="bg-blue-600 text-white py-20">
    <div className="max-w-7xl mx-auto px-4 text-center">
      <h1 className="text-4xl font-bold mb-4">Welcome to Our Platform</h1>
      <p className="text-xl mb-8">The best solution for your business needs</p>
      <button className="bg-white text-blue-600 px-6 py-3 rounded-lg font-medium">
        Get Started
      </button>
    </div>
  </section>
);
```

**What's wrong:** Flat color background, centered text, generic copy, no animation, no visual interest, basic button.

#### ✅ Elevated Hero

```tsx
import { motion } from 'framer-motion';

const ElevatedHero = () => (
  <section className="relative min-h-[90vh] flex items-center overflow-hidden">
    {/* Background */}
    <div className="absolute inset-0">
      <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_top,_var(--tw-gradient-stops))] from-brand-900/20 via-neutral-950 to-neutral-950" />
      <div className="absolute inset-0 bg-[linear-gradient(to_right,#80808012_1px,transparent_1px),linear-gradient(to_bottom,#80808012_1px,transparent_1px)] bg-[size:32px_32px]" />
      <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[800px] h-[600px] bg-brand-500/10 rounded-full blur-[128px]" />
    </div>

    <div className="relative max-w-6xl mx-auto px-6 lg:px-8">
      <div className="max-w-3xl">
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5 }}
        >
          <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-white/5 border border-white/10 text-sm text-neutral-300 mb-8 backdrop-blur-sm">
            <span className="w-2 h-2 rounded-full bg-emerald-400 animate-pulse" />
            Now in public beta
          </div>
        </motion.div>

        <motion.h1
          className="text-5xl sm:text-6xl lg:text-7xl font-bold tracking-tight text-white mb-8 leading-[1.1]"
          initial={{ opacity: 0, y: 30 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, delay: 0.1, ease: [0.22, 1, 0.36, 1] }}
        >
          Ship products that{' '}
          <span className="bg-gradient-to-r from-brand-400 via-purple-400 to-brand-400 bg-clip-text text-transparent bg-[size:200%] animate-gradient">
            people love
          </span>
        </motion.h1>

        <motion.p
          className="text-lg sm:text-xl text-neutral-400 max-w-xl mb-12 leading-relaxed"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, delay: 0.3, ease: [0.22, 1, 0.36, 1] }}
        >
          The modern development platform that helps teams build, test, and deploy exceptional software — without the complexity.
        </motion.p>

        <motion.div
          className="flex flex-col sm:flex-row items-start gap-4"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, delay: 0.5, ease: [0.22, 1, 0.36, 1] }}
        >
          <button className="group px-8 py-4 bg-white text-neutral-900 rounded-xl font-medium text-lg transition-all duration-200 hover:shadow-lg hover:shadow-white/20 hover:-translate-y-0.5 flex items-center gap-2">
            Start Building
            <svg className="w-4 h-4 transition-transform group-hover:translate-x-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 8l4 4m0 0l-4 4m4-4H3" />
            </svg>
          </button>
          <button className="px-8 py-4 text-neutral-300 hover:text-white rounded-xl font-medium text-lg transition-colors duration-200 flex items-center gap-3">
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            Watch Demo
          </button>
        </motion.div>
      </div>
    </div>
  </section>
);
```

**What makes it better:**
- Layered background (gradient + grid + glow) instead of flat color
- Animated badge with live indicator
- Gradient text with animation
- Staggered entrance animations
- Left-aligned with constrained width (not centered in a huge container)
- Two distinct CTA styles (primary + ghost)
- Interactive hover states with arrow animation
- Proper responsive sizing
- `leading-[1.1]` for tight, impactful headline spacing

---

### Feature/Benefits Grids

#### ❌ Generic Features

```tsx
const GenericFeatures = () => (
  <section className="py-16 bg-gray-50">
    <div className="max-w-7xl mx-auto px-4 text-center">
      <h2 className="text-3xl font-bold mb-12">Our Features</h2>
      <div className="grid grid-cols-3 gap-8">
        {features.map((f) => (
          <div key={f.title} className="bg-white p-6 rounded-lg shadow">
            <div className="text-blue-500 text-4xl mb-4">{f.icon}</div>
            <h3 className="text-xl font-bold mb-2">{f.title}</h3>
            <p className="text-gray-600">{f.description}</p>
          </div>
        ))}
      </div>
    </div>
  </section>
);
```

#### ✅ Elevated Features (Bento Grid)

```tsx
import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';

const ElevatedFeatures = () => {
  const ref = useRef(null);
  const isInView = useInView(ref, { once: true, margin: "-10%" });

  return (
    <section className="py-24 lg:py-32">
      <div className="max-w-6xl mx-auto px-6 lg:px-8">
        {/* Section header — left aligned */}
        <div className="max-w-2xl mb-16 lg:mb-20">
          <motion.span
            className="text-sm font-medium text-brand-500 uppercase tracking-wider mb-4 block"
            initial={{ opacity: 0 }}
            animate={isInView ? { opacity: 1 } : {}}
            transition={{ duration: 0.5 }}
          >
            Features
          </motion.span>
          <motion.h2
            className="text-4xl lg:text-5xl font-bold tracking-tight mb-6"
            initial={{ opacity: 0, y: 20 }}
            animate={isInView ? { opacity: 1, y: 0 } : {}}
            transition={{ duration: 0.6, delay: 0.1 }}
          >
            Everything you need,{' '}
            <span className="text-neutral-400">nothing you don't</span>
          </motion.h2>
        </div>

        {/* Bento grid */}
        <motion.div
          ref={ref}
          className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
          initial="hidden"
          animate={isInView ? "visible" : "hidden"}
          variants={{ visible: { transition: { staggerChildren: 0.08 } } }}
        >
          {/* Large feature card */}
          <motion.div
            variants={{
              hidden: { opacity: 0, y: 20 },
              visible: { opacity: 1, y: 0, transition: { duration: 0.5, ease: [0.22, 1, 0.36, 1] } },
            }}
            className="lg:col-span-2 group relative p-8 lg:p-10 rounded-3xl bg-neutral-50 dark:bg-neutral-900 border border-neutral-200/50 dark:border-neutral-800 overflow-hidden"
          >
            <div className="absolute top-0 right-0 w-64 h-64 bg-brand-500/5 rounded-full blur-3xl group-hover:bg-brand-500/10 transition-colors duration-700" />
            <div className="relative">
              <div className="w-12 h-12 rounded-2xl bg-brand-500/10 dark:bg-brand-500/20 flex items-center justify-center mb-6">
                <svg className="w-6 h-6 text-brand-500" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M13 10V3L4 14h7v7l9-11h-7z" />
                </svg>
              </div>
              <h3 className="text-2xl font-semibold mb-3">Lightning Fast</h3>
              <p className="text-neutral-500 dark:text-neutral-400 leading-relaxed max-w-md">
                Built on edge infrastructure for sub-100ms response times globally. Your users never wait.
              </p>
              {/* Optional: visual/screenshot/demo */}
              <div className="mt-8 rounded-xl bg-neutral-100 dark:bg-neutral-800 h-48 overflow-hidden">
                {/* Feature demo or screenshot */}
              </div>
            </div>
          </motion.div>

          {/* Regular feature cards */}
          {smallFeatures.map((feature) => (
            <motion.div
              key={feature.title}
              variants={{
                hidden: { opacity: 0, y: 20 },
                visible: { opacity: 1, y: 0, transition: { duration: 0.5, ease: [0.22, 1, 0.36, 1] } },
              }}
              className="group p-8 rounded-3xl bg-neutral-50 dark:bg-neutral-900 border border-neutral-200/50 dark:border-neutral-800 hover:border-brand-500/30 transition-colors duration-300"
            >
              <div className="w-10 h-10 rounded-xl bg-neutral-200/50 dark:bg-neutral-800 flex items-center justify-center mb-5 group-hover:bg-brand-500/10 transition-colors">
                <feature.icon className="w-5 h-5 text-neutral-600 dark:text-neutral-400 group-hover:text-brand-500 transition-colors" />
              </div>
              <h3 className="text-lg font-semibold mb-2">{feature.title}</h3>
              <p className="text-neutral-500 dark:text-neutral-400 text-sm leading-relaxed">
                {feature.description}
              </p>
            </motion.div>
          ))}
        </motion.div>
      </div>
    </section>
  );
};
```

---

### Testimonial Sections

#### ❌ Generic Testimonials

```tsx
const GenericTestimonials = () => (
  <section className="py-16 bg-white">
    <div className="max-w-7xl mx-auto px-4 text-center">
      <h2 className="text-3xl font-bold mb-12">What Our Customers Say</h2>
      <div className="grid grid-cols-3 gap-8">
        {testimonials.map((t) => (
          <div key={t.name} className="bg-gray-50 p-6 rounded-lg">
            <p className="text-gray-600 mb-4">"{t.quote}"</p>
            <div className="flex items-center gap-3">
              <img src={t.avatar} className="w-10 h-10 rounded-full" />
              <div>
                <p className="font-bold">{t.name}</p>
                <p className="text-gray-500 text-sm">{t.role}</p>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  </section>
);
```

#### ✅ Elevated Testimonials

```tsx
const ElevatedTestimonials = () => (
  <section className="py-24 lg:py-32 overflow-hidden">
    <div className="max-w-6xl mx-auto px-6 lg:px-8">
      <div className="max-w-2xl mb-16">
        <h2 className="text-4xl lg:text-5xl font-bold tracking-tight mb-6">
          Loved by teams{' '}
          <span className="text-neutral-400">everywhere</span>
        </h2>
      </div>

      {/* Featured testimonial — large */}
      <div className="mb-16 relative">
        <div className="absolute -top-6 -left-4 text-8xl font-serif text-brand-500/10 select-none">"</div>
        <blockquote className="relative pl-8 border-l-2 border-brand-500">
          <p className="text-2xl lg:text-3xl font-medium leading-relaxed text-neutral-700 dark:text-neutral-200 mb-8">
            This completely transformed how our team works. We shipped our entire redesign in half the time we expected.
          </p>
          <footer className="flex items-center gap-4">
            <img
              src="/avatar-featured.jpg"
              alt=""
              className="w-14 h-14 rounded-full object-cover ring-2 ring-neutral-100 dark:ring-neutral-800"
            />
            <div>
              <p className="font-semibold text-lg">Sarah Chen</p>
              <p className="text-neutral-500">VP of Engineering, Acme Corp</p>
            </div>
            <img src="/acme-logo.svg" alt="Acme" className="h-8 ml-auto opacity-40" />
          </footer>
        </blockquote>
      </div>

      {/* Grid of smaller testimonials */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {testimonials.map((t, i) => (
          <motion.div
            key={t.name}
            initial={{ opacity: 0, y: 20 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-10%" }}
            transition={{ duration: 0.5, delay: i * 0.08 }}
            className="p-6 rounded-2xl bg-neutral-50 dark:bg-neutral-900 border border-neutral-200/50 dark:border-neutral-800"
          >
            {/* Star rating */}
            <div className="flex gap-1 mb-4">
              {[...Array(5)].map((_, j) => (
                <svg key={j} className="w-4 h-4 text-amber-400 fill-current" viewBox="0 0 20 20">
                  <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z" />
                </svg>
              ))}
            </div>
            <p className="text-neutral-600 dark:text-neutral-300 leading-relaxed mb-6 text-sm">
              {t.quote}
            </p>
            <div className="flex items-center gap-3">
              <img src={t.avatar} alt="" className="w-10 h-10 rounded-full object-cover" />
              <div>
                <p className="font-medium text-sm">{t.name}</p>
                <p className="text-neutral-500 text-xs">{t.role} · {t.company}</p>
              </div>
            </div>
          </motion.div>
        ))}
      </div>
    </div>
  </section>
);
```

---

### Pricing Cards

#### ❌ Generic Pricing

```tsx
const GenericPricing = () => (
  <section className="py-16">
    <div className="max-w-7xl mx-auto px-4 text-center">
      <h2 className="text-3xl font-bold mb-12">Pricing</h2>
      <div className="grid grid-cols-3 gap-8">
        {plans.map((plan) => (
          <div key={plan.name} className={`p-8 rounded-lg border ${plan.popular ? 'border-blue-500 bg-blue-50' : 'border-gray-200'}`}>
            <h3 className="text-xl font-bold">{plan.name}</h3>
            <p className="text-4xl font-bold mt-4">${plan.price}/mo</p>
            <ul className="mt-6 space-y-3">
              {plan.features.map((f) => <li key={f}>✓ {f}</li>)}
            </ul>
            <button className="mt-8 w-full py-3 bg-blue-600 text-white rounded-lg">
              Choose Plan
            </button>
          </div>
        ))}
      </div>
    </div>
  </section>
);
```

#### ✅ Elevated Pricing

```tsx
import { motion } from 'framer-motion';
import { useState } from 'react';

const ElevatedPricing = () => {
  const [annual, setAnnual] = useState(true);

  return (
    <section className="py-24 lg:py-32">
      <div className="max-w-5xl mx-auto px-6 lg:px-8">
        <div className="text-center max-w-2xl mx-auto mb-16">
          <h2 className="text-4xl lg:text-5xl font-bold tracking-tight mb-6">
            Simple, transparent pricing
          </h2>
          <p className="text-lg text-neutral-500 mb-8">
            No hidden fees. No surprises. Cancel anytime.
          </p>

          {/* Billing toggle */}
          <div className="inline-flex items-center gap-3 bg-neutral-100 dark:bg-neutral-800/50 p-1 rounded-full">
            <button
              onClick={() => setAnnual(false)}
              className={`px-5 py-2 rounded-full text-sm font-medium transition-all duration-200 ${
                !annual ? 'bg-white dark:bg-neutral-700 shadow-sm' : 'text-neutral-500'
              }`}
            >
              Monthly
            </button>
            <button
              onClick={() => setAnnual(true)}
              className={`px-5 py-2 rounded-full text-sm font-medium transition-all duration-200 ${
                annual ? 'bg-white dark:bg-neutral-700 shadow-sm' : 'text-neutral-500'
              }`}
            >
              Annual
              <span className="ml-2 text-xs text-emerald-500 font-medium">Save 20%</span>
            </button>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 items-start">
          {plans.map((plan, i) => (
            <motion.div
              key={plan.name}
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true }}
              transition={{ duration: 0.5, delay: i * 0.1 }}
              className={`relative rounded-2xl p-8 ${
                plan.popular
                  ? 'bg-neutral-900 dark:bg-white text-white dark:text-neutral-900 ring-2 ring-neutral-900 dark:ring-white scale-105'
                  : 'bg-white dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-800'
              }`}
            >
              {plan.popular && (
                <div className="absolute -top-4 left-1/2 -translate-x-1/2">
                  <span className="px-4 py-1 bg-brand-500 text-white text-xs font-medium rounded-full">
                    Most Popular
                  </span>
                </div>
              )}

              <h3 className="text-lg font-semibold mb-2">{plan.name}</h3>
              <p className={`text-sm mb-6 ${plan.popular ? 'text-neutral-300 dark:text-neutral-500' : 'text-neutral-500'}`}>
                {plan.description}
              </p>

              <div className="mb-8">
                <motion.span
                  key={annual ? 'annual' : 'monthly'}
                  initial={{ opacity: 0, y: -10 }}
                  animate={{ opacity: 1, y: 0 }}
                  className="text-4xl font-bold"
                >
                  ${annual ? plan.annualPrice : plan.monthlyPrice}
                </motion.span>
                <span className={`text-sm ${plan.popular ? 'text-neutral-400 dark:text-neutral-500' : 'text-neutral-500'}`}>
                  /month
                </span>
              </div>

              <button className={`w-full py-3 rounded-xl font-medium text-sm transition-all duration-200 mb-8 ${
                plan.popular
                  ? 'bg-white dark:bg-neutral-900 text-neutral-900 dark:text-white hover:bg-neutral-100 dark:hover:bg-neutral-800'
                  : 'bg-neutral-900 dark:bg-white text-white dark:text-neutral-900 hover:bg-neutral-800 dark:hover:bg-neutral-100'
              }`}>
                Get Started
              </button>

              <ul className="space-y-3">
                {plan.features.map((feature) => (
                  <li key={feature} className="flex items-start gap-3 text-sm">
                    <svg className={`w-5 h-5 shrink-0 ${plan.popular ? 'text-brand-400' : 'text-brand-500'}`} fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
                    </svg>
                    <span className={plan.popular ? 'text-neutral-200 dark:text-neutral-600' : 'text-neutral-600 dark:text-neutral-400'}>
                      {feature}
                    </span>
                  </li>
                ))}
              </ul>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
};
```

---

### Navigation / Headers

#### ❌ Generic Nav

```tsx
const GenericNav = () => (
  <nav className="bg-white shadow py-4">
    <div className="max-w-7xl mx-auto px-4 flex justify-between items-center">
      <h1 className="text-xl font-bold text-blue-600">Logo</h1>
      <div className="flex gap-6">
        <a href="#" className="text-gray-600 hover:text-blue-600">Home</a>
        <a href="#" className="text-gray-600 hover:text-blue-600">Features</a>
        <a href="#" className="text-gray-600 hover:text-blue-600">Pricing</a>
        <a href="#" className="text-gray-600 hover:text-blue-600">Contact</a>
      </div>
      <button className="bg-blue-600 text-white px-4 py-2 rounded">Sign Up</button>
    </div>
  </nav>
);
```

#### ✅ Elevated Nav

```tsx
import { motion, useScroll, useMotionValueEvent } from 'framer-motion';
import { useState } from 'react';

const ElevatedNav = () => {
  const [scrolled, setScrolled] = useState(false);
  const { scrollY } = useScroll();

  useMotionValueEvent(scrollY, "change", (latest) => {
    setScrolled(latest > 50);
  });

  return (
    <motion.header
      className={`fixed top-0 left-0 right-0 z-50 transition-all duration-300 ${
        scrolled
          ? 'bg-white/80 dark:bg-neutral-950/80 backdrop-blur-xl border-b border-neutral-200/50 dark:border-neutral-800/50'
          : 'bg-transparent'
      }`}
    >
      <div className="max-w-6xl mx-auto px-6 lg:px-8">
        <div className="flex items-center justify-between h-16 lg:h-20">
          {/* Logo */}
          <a href="/" className="flex items-center gap-2">
            <div className="w-8 h-8 rounded-lg bg-brand-500 flex items-center justify-center">
              <span className="text-white font-bold text-sm">S</span>
            </div>
            <span className="font-semibold text-lg">Shimizu</span>
          </a>

          {/* Center nav — pill style */}
          <nav className="hidden lg:flex items-center gap-1 bg-neutral-100/50 dark:bg-neutral-800/50 backdrop-blur-sm px-2 py-1.5 rounded-full border border-neutral-200/50 dark:border-neutral-700/50">
            {['Product', 'Features', 'Pricing', 'Docs'].map((item) => (
              <a
                key={item}
                href={`#${item.toLowerCase()}`}
                className="px-4 py-1.5 text-sm font-medium text-neutral-600 dark:text-neutral-300 hover:text-neutral-900 dark:hover:text-white rounded-full hover:bg-white dark:hover:bg-neutral-700 transition-all duration-200"
              >
                {item}
              </a>
            ))}
          </nav>

          {/* Right side */}
          <div className="flex items-center gap-3">
            <a href="/login" className="text-sm font-medium text-neutral-600 dark:text-neutral-300 hover:text-neutral-900 dark:hover:text-white transition-colors hidden sm:block">
              Log in
            </a>
            <button className="px-5 py-2 bg-neutral-900 dark:bg-white text-white dark:text-neutral-900 text-sm font-medium rounded-full hover:bg-neutral-800 dark:hover:bg-neutral-100 transition-colors">
              Get Started
            </button>
          </div>
        </div>
      </div>
    </motion.header>
  );
};
```

---

### Footers

#### ❌ Generic Footer

```tsx
const GenericFooter = () => (
  <footer className="bg-gray-800 text-white py-12">
    <div className="max-w-7xl mx-auto px-4 grid grid-cols-4 gap-8">
      <div>
        <h3 className="font-bold mb-4">Company</h3>
        <ul className="space-y-2"><li><a href="#">About</a></li><li><a href="#">Careers</a></li></ul>
      </div>
      {/* ... more columns */}
    </div>
    <div className="max-w-7xl mx-auto px-4 mt-8 pt-8 border-t border-gray-700 text-center text-gray-400">
      © 2025 Company. All rights reserved.
    </div>
  </footer>
);
```

#### ✅ Elevated Footer

```tsx
const ElevatedFooter = () => (
  <footer className="bg-neutral-950 text-neutral-400 pt-20 pb-8">
    <div className="max-w-6xl mx-auto px-6 lg:px-8">
      {/* CTA strip above footer (optional) */}
      <div className="relative rounded-3xl bg-gradient-to-br from-brand-600 to-brand-700 p-12 lg:p-16 mb-20 overflow-hidden">
        <div className="absolute top-0 right-0 w-96 h-96 bg-white/10 rounded-full blur-3xl -translate-y-1/2 translate-x-1/2" />
        <div className="relative flex flex-col lg:flex-row items-start lg:items-center justify-between gap-8">
          <div>
            <h2 className="text-3xl lg:text-4xl font-bold text-white mb-3">
              Ready to get started?
            </h2>
            <p className="text-brand-100 text-lg">
              Join thousands of teams shipping better software.
            </p>
          </div>
          <button className="px-8 py-4 bg-white text-brand-600 rounded-xl font-medium text-lg hover:bg-neutral-100 transition-colors shrink-0">
            Start Free Trial
          </button>
        </div>
      </div>

      {/* Footer grid */}
      <div className="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-5 gap-8 lg:gap-12 mb-16">
        {/* Brand column */}
        <div className="col-span-2 lg:col-span-1">
          <div className="flex items-center gap-2 mb-6">
            <div className="w-8 h-8 rounded-lg bg-brand-500 flex items-center justify-center">
              <span className="text-white font-bold text-sm">S</span>
            </div>
            <span className="font-semibold text-lg text-white">Shimizu</span>
          </div>
          <p className="text-sm leading-relaxed mb-6">
            Building exceptional web experiences from Guam to the world.
          </p>
          <div className="flex gap-4">
            {socialLinks.map((link) => (
              <a key={link.name} href={link.url} className="text-neutral-500 hover:text-white transition-colors">
                <link.icon className="w-5 h-5" />
              </a>
            ))}
          </div>
        </div>

        {/* Link columns */}
        {footerLinks.map((column) => (
          <div key={column.title}>
            <h3 className="text-sm font-semibold text-white uppercase tracking-wider mb-4">
              {column.title}
            </h3>
            <ul className="space-y-3">
              {column.links.map((link) => (
                <li key={link.name}>
                  <a href={link.url} className="text-sm hover:text-white transition-colors duration-200">
                    {link.name}
                    {link.isNew && (
                      <span className="ml-2 text-[10px] px-1.5 py-0.5 bg-brand-500/20 text-brand-400 rounded-full font-medium">
                        New
                      </span>
                    )}
                  </a>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>

      {/* Bottom bar */}
      <div className="flex flex-col sm:flex-row items-center justify-between gap-4 pt-8 border-t border-neutral-800">
        <p className="text-xs text-neutral-500">
          © {new Date().getFullYear()} Shimizu Technology. All rights reserved.
        </p>
        <div className="flex gap-6">
          <a href="/privacy" className="text-xs text-neutral-500 hover:text-neutral-300 transition-colors">Privacy</a>
          <a href="/terms" className="text-xs text-neutral-500 hover:text-neutral-300 transition-colors">Terms</a>
          <a href="/cookies" className="text-xs text-neutral-500 hover:text-neutral-300 transition-colors">Cookies</a>
        </div>
      </div>
    </div>
  </footer>
);
```

---

### CTAs

#### ❌ Generic CTA

```tsx
<section className="bg-blue-600 text-white py-16 text-center">
  <h2 className="text-3xl font-bold mb-4">Get Started Today</h2>
  <p className="mb-8">Sign up and start building amazing products.</p>
  <button className="bg-white text-blue-600 px-8 py-3 rounded-lg font-bold">Sign Up Free</button>
</section>
```

#### ✅ Elevated CTA

```tsx
<section className="py-24 lg:py-32">
  <div className="max-w-4xl mx-auto px-6 lg:px-8 text-center">
    <motion.div
      initial={{ opacity: 0, y: 20 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true }}
      transition={{ duration: 0.6 }}
    >
      <h2 className="text-4xl lg:text-6xl font-bold tracking-tight mb-6">
        Start building{' '}
        <span className="bg-gradient-to-r from-brand-500 to-purple-500 bg-clip-text text-transparent">
          today
        </span>
      </h2>
      <p className="text-xl text-neutral-500 max-w-xl mx-auto mb-10">
        Join 10,000+ developers who ship faster with our platform. Free to start, no credit card required.
      </p>
      <div className="flex flex-col sm:flex-row items-center justify-center gap-4">
        <button className="group px-8 py-4 bg-brand-500 text-white rounded-xl font-medium text-lg hover:bg-brand-600 transition-all duration-200 hover:shadow-lg hover:shadow-brand-500/25 flex items-center gap-2">
          Get Started Free
          <svg className="w-5 h-5 transition-transform group-hover:translate-x-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 8l4 4m0 0l-4 4m4-4H3" />
          </svg>
        </button>
        <button className="px-8 py-4 text-neutral-500 hover:text-neutral-900 dark:hover:text-white font-medium text-lg transition-colors">
          Talk to Sales →
        </button>
      </div>
      <p className="mt-6 text-sm text-neutral-400">
        No credit card required · Free plan available · Cancel anytime
      </p>
    </motion.div>
  </div>
</section>
```

---

### Cards & Content Blocks

#### ❌ Generic Card

```tsx
<div className="bg-white rounded-lg shadow p-6">
  <img src="/image.jpg" className="w-full rounded mb-4" />
  <h3 className="text-xl font-bold mb-2">Card Title</h3>
  <p className="text-gray-600">Card description goes here.</p>
  <a href="#" className="text-blue-600 mt-4 inline-block">Learn more →</a>
</div>
```

#### ✅ Elevated Card

```tsx
const ElevatedCard = ({ image, tag, title, description, href }: CardProps) => (
  <a
    href={href}
    className="group block rounded-2xl overflow-hidden bg-white dark:bg-neutral-900 border border-neutral-200/50 dark:border-neutral-800 hover:border-neutral-300 dark:hover:border-neutral-700 transition-all duration-300 hover:shadow-xl hover:shadow-neutral-200/50 dark:hover:shadow-neutral-900/50"
  >
    {/* Image with zoom on hover */}
    <div className="aspect-[16/10] overflow-hidden">
      <img
        src={image}
        alt=""
        className="w-full h-full object-cover transition-transform duration-700 ease-out group-hover:scale-105"
      />
    </div>
    
    <div className="p-6">
      {/* Tag */}
      <span className="inline-block text-xs font-medium text-brand-500 uppercase tracking-wider mb-3">
        {tag}
      </span>
      
      {/* Title */}
      <h3 className="text-xl font-semibold mb-3 group-hover:text-brand-500 transition-colors duration-200">
        {title}
      </h3>
      
      {/* Description */}
      <p className="text-neutral-500 dark:text-neutral-400 text-sm leading-relaxed mb-4 line-clamp-2">
        {description}
      </p>
      
      {/* Link with animated arrow */}
      <span className="inline-flex items-center gap-2 text-sm font-medium text-neutral-900 dark:text-white">
        Read more
        <svg
          className="w-4 h-4 transition-transform duration-200 group-hover:translate-x-1"
          fill="none" viewBox="0 0 24 24" stroke="currentColor"
        >
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17 8l4 4m0 0l-4 4m4-4H3" />
        </svg>
      </span>
    </div>
  </a>
);
```

---

## 6. Tools & Resources

### Design Tools

| Tool | Purpose | URL |
|------|---------|-----|
| **Figma** | UI design, prototyping, component libraries | figma.com |
| **Coolors** | Color palette generation | coolors.co |
| **Realtime Colors** | Preview palettes on a real site layout | realtimecolors.com |
| **FontPair** | Font pairing suggestions | fontpair.co |
| **Type Scale** | Visual type scale generator | typescale.com |
| **Contrast Checker** | WCAG contrast ratio checking | webaim.org/resources/contrastchecker |
| **Tailwind Play** | Tailwind CSS playground | play.tailwindcss.com |
| **Heroicons** | Beautiful hand-crafted SVG icons | heroicons.com |
| **Lucide** | Icon library, Heroicons alternative | lucide.dev |
| **Phosphor Icons** | Flexible icon family | phosphoricons.com |

### Animation Tools

| Tool | Purpose | URL |
|------|---------|-----|
| **Framer Motion** | React animation library — our primary choice | framer.com/motion |
| **GSAP** | Professional-grade animation library | gsap.com |
| **Lenis** | Smooth scroll library | lenis.darkroom.engineering |
| **Auto-Animate** | Zero-config animation drop-in | auto-animate.formkit.com |
| **Motion One** | Lightweight animation library | motion.dev |
| **CSS Easing Functions** | Easing curve visualizer | easings.net |
| **Cubic Bezier** | Custom easing curve generator | cubic-bezier.com |

### Inspiration

| Site | Focus | URL |
|------|-------|-----|
| **Awwwards** | Cutting-edge web design | awwwards.com |
| **Godly** | Curated web design inspiration | godly.website |
| **SaaS Landing Page** | SaaS-specific landing pages | saaslandingpage.com |
| **Mobbin** | Mobile & web UI patterns | mobbin.com |
| **Dark Mode Design** | Dark UI inspiration | darkmodedesign.com |
| **Land-book** | Landing page gallery | land-book.com |
| **One Page Love** | One-page website gallery | onepagelove.com |
| **Refero** | Design reference library | refero.design |
| **Page Flows** | User flow recordings | pageflows.com |

### Asset Sources

| Source | Type | URL |
|--------|------|-----|
| **Unsplash** | Free high-quality photos | unsplash.com |
| **Pexels** | Free photos and videos | pexels.com |
| **unDraw** | Free customizable illustrations | undraw.co |
| **Storyset** | Free animated illustrations | storyset.com |
| **Heroicons** | Free SVG icons by Tailwind team | heroicons.com |
| **Lottie Files** | Animated icons and illustrations | lottiefiles.com |
| **Rive** | Interactive animations | rive.app |
| **Spline** | 3D design for web | spline.design |

### Sites to Study

Study these sites and reverse-engineer what makes them exceptional:

| Site | Why Study It |
|------|-------------|
| **stripe.com** | Master of gradient use, animation, and content hierarchy. Their landing pages are the gold standard. |
| **linear.app** | Dark mode perfection. Smooth animations. Clean typography. Everything feels intentional. |
| **vercel.com** | Grid backgrounds, glow effects, sophisticated dark theme. Engineering-focused but beautiful. |
| **apple.com** | Scroll-triggered animations, product photography, typography at its finest. |
| **notion.so** | Friendly design system, great illustrations, approachable but polished. |
| **raycast.com** | Beautiful dark UI, keyboard-first design, subtle animations. |
| **arc.net** | Playful, colorful, unique layout choices. Breaks conventions well. |
| **craft.do** | Apple-level polish, beautiful spacing, smooth interactions. |
| **liveblocks.io** | Developer tool with exceptional design. Great code examples presentation. |
| **resend.com** | Clean, minimal, dark mode done right. Good typography. |
| **cal.com** | Open source with great design. Good balance of function and aesthetics. |

---

## 7. Quick Checklist: "Does This Site Feel Custom?"

Print this. Tape it to your monitor. Check it before every launch.

### Typography
- [ ] Using a deliberate font (not just the system default or only Inter)
- [ ] Clear type hierarchy (h1 is noticeably larger than h2, which is larger than h3)
- [ ] Body text is 16-18px and readable (not 14px)
- [ ] Line length is under 75 characters for body text (`max-w-prose` or similar)
- [ ] Headings use `tracking-tight` (negative letter-spacing)
- [ ] Consistent font weights (not random bold everywhere)
- [ ] Line heights feel right (tight for headings: 1.1–1.2, relaxed for body: 1.5–1.7)

### Color
- [ ] Has a brand color beyond blue + gray
- [ ] Using tinted neutrals (not pure gray)
- [ ] Has an accent color for highlights/CTAs
- [ ] Dark mode is intentional (not just inverted)
- [ ] Gradients (if used) are subtle and purposeful
- [ ] Sufficient contrast ratios (4.5:1 for body text, 3:1 for large text)

### Spacing
- [ ] Consistent section padding (same `py-` value throughout)
- [ ] Generous whitespace (doesn't feel cramped)
- [ ] Content doesn't stretch too wide — uses `max-w-5xl` or `max-w-6xl`, not `7xl`
- [ ] Spacing between elements follows a consistent scale
- [ ] Headers have proper margin below them (`mb-6` or more, not `mb-2`)
- [ ] Intro text has generous margin before the content below it (`mb-12` to `mb-16`)

### Layout
- [ ] Not the standard hero/features/testimonials/CTA cookie cutter
- [ ] At least one section with an asymmetric or unique layout
- [ ] Content widths vary (not everything in the same container)
- [ ] Responsive design is considered (not just "stack on mobile")
- [ ] Elements overlap or break the grid somewhere
- [ ] Sticky elements where appropriate (nav, sidebar headings)

### Animation
- [ ] Hero has entrance animation (staggered fade-in at minimum)
- [ ] Buttons have hover states beyond just color change (lift, shadow, arrow movement)
- [ ] Cards have hover interactions (border change, slight lift, image zoom)
- [ ] Scroll reveals exist (elements animate in as they enter viewport)
- [ ] Animations use proper easing (no linear, no default ease)
- [ ] Animations are fast enough (under 600ms for most things)
- [ ] NOT everything is animated — restraint is key
- [ ] `prefers-reduced-motion` is respected

### Imagery
- [ ] No obvious stock photos (people pointing at laptops)
- [ ] Images have consistent treatment (all rounded, all same aspect ratio, etc.)
- [ ] Icons are from the same library (not mixing styles)
- [ ] Any illustrations match the brand style
- [ ] Images are properly optimized (WebP, lazy loaded, responsive sizes)

### Polish
- [ ] Focus states are styled (not just browser default blue ring)
- [ ] Loading states exist (skeleton screens or spinners)
- [ ] Transitions between states are smooth (no jarring jumps)
- [ ] Empty states are designed (not just "No data")
- [ ] Error states are friendly and helpful
- [ ] Forms have proper validation UX (inline errors, success states)
- [ ] Page has a `<title>` and meta description
- [ ] Favicon is custom (not the default framework icon)
- [ ] Social sharing image (og:image) is designed

### The "Squint Test"
- [ ] Squint at the page. Can you still see the hierarchy? Headers should be clearly distinct from body text even when blurred.
- [ ] Does it look like ONE person designed it? Visual consistency throughout?
- [ ] Is there at least ONE moment that makes you go "that's nice"?
- [ ] Would you be proud to show this to a designer?

---

## Final Thoughts

The difference between a "good enough" site and an exceptional one isn't talent — it's intention. Every choice should be deliberate:

1. **Typography:** Chosen, not defaulted to
2. **Color:** Crafted, not pulled from a template
3. **Spacing:** Generous and consistent
4. **Animation:** Purposeful and restrained
5. **Layout:** Varied and interesting
6. **Details:** Polished to the pixel

You don't need to nail all of these at once. Pick one area to improve per project. Typography alone can transform a site. Adding proper hover states and scroll reveals can take it from flat to professional.

The best sites in the world aren't built by people who know more tricks — they're built by people who make more intentional choices.

**Now go build something beautiful.** 🚀

---

*Guide created for Shimizu Technology. References: Stripe, Linear, Vercel, Apple, and the best of modern web design.*
*Use with: React + TypeScript + Tailwind CSS + Framer Motion*
