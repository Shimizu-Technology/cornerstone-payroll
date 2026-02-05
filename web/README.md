# Cornerstone Payroll Frontend

React frontend for the Cornerstone Payroll system — a Guam-specific payroll processing application.

## Tech Stack

- **React 19** + **TypeScript**
- **Vite** for build tooling
- **Tailwind CSS 4** for styling
- **React Router** for navigation

## Getting Started

```bash
# Install dependencies
npm install

# Start development server
npm run dev

# Build for production
npm run build

# Preview production build
npm run preview
```

## Development

```bash
# Run type checking
npm run typecheck

# Run linter
npm run lint

# Run all quality checks (gate script)
npm run gate
```

## Project Structure

```
src/
├── components/
│   ├── ui/           # Reusable UI components (Button, Card, Input, etc.)
│   ├── layout/       # Layout components (Sidebar, Header)
│   ├── auth/         # Auth components (WorkOS integration) - TBD
│   ├── employees/    # Employee management components - TBD
│   └── payroll/      # Payroll processing components - TBD
├── pages/
│   ├── Dashboard.tsx
│   ├── Employees.tsx
│   ├── PayPeriods.tsx
│   ├── PayrollRun.tsx
│   └── Reports.tsx
├── services/
│   └── api.ts        # API client with type-safe endpoints
├── lib/
│   └── utils.ts      # Utility functions
├── types/
│   └── index.ts      # TypeScript type definitions
├── App.tsx           # Main app with routing
└── main.tsx          # Entry point
```

## Environment Variables

Copy `.env.example` to `.env` and configure:

```bash
VITE_API_URL=http://localhost:3000/api/v1
```

## Features

### Current (MVP)

- Dashboard with payroll overview
- Employee management (list view)
- Pay period management
- Payroll processing view
- Reports placeholder

### Planned

- Full CRUD for employees
- Time entry management
- Payroll calculation integration
- PDF generation (pay stubs, checks)
- WorkOS authentication
- Role-based access control

## Related

- **API**: See `../api/` for the Rails backend (TBD)
- **PRD**: See `../PRD.md` for full requirements
- **Build Plan**: See `../BUILD_PLAN.md` for technical plan
