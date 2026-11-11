# 🩺 AI HealthBot

### AI-Powered Multilingual Healthcare Assistant for Symptom Assessment and Risk Triage

AI HealthBot is a full-stack healthcare support platform designed to make preliminary health information and symptom assessment more accessible. It combines conversational AI, symptom-based risk assessment, secure health profiles, and dedicated workflows for NGOs and administrators.

The platform aims to support individuals and community healthcare organizations through accessible digital health assistance, secure assessment records, and privacy-conscious health insights.

> ⚠️ **Medical Disclaimer:** AI HealthBot is an informational and decision-support tool. It does not provide a definitive medical diagnosis and is not a substitute for professional medical advice, diagnosis, or treatment. Always consult qualified healthcare professionals. In an emergency, contact local emergency services immediately.

---

## 🚀 Features

### 🤖 AI Healthcare Assistant

- Conversational AI-assisted symptom assessment.
- Contextual follow-up questions.
- Severity-based risk categorization: Low, Moderate, and High.
- Multilingual healthcare support.
- Personalized health guidance and recommendations.
- Downloadable health assessment reports.
- Emergency guidance for potentially serious symptoms.

### 👤 User Portal

- Secure authentication using Supabase Auth.
- Personal profile management.
- Health history and assessment records.
- Protected user sessions.
- Responsive desktop and mobile interface.
- Light and dark themes.

### 🏥 NGO Portal

- NGO registration and application submission.
- Application status tracking.
- Resubmission following rejection.
- Dedicated dashboard for approved NGOs.
- Privacy-preserving community health analytics.
- Small-cohort suppression to protect sensitive information.
- Restricted dashboard access based on verified NGO approval status.

### 🛡️ Administrator Portal

- Dedicated administrator authentication.
- Role-based access control.
- NGO application verification.
- Approval, rejection, and suspension workflows.
- Mandatory reasons for rejection and suspension.
- Application statistics and review history.
- Prevention of administrator self-review.
- Secure reinstatement of suspended NGO applications.
- Audit logging for administrative decisions.

### 🔄 NGO Reinstatement Workflow

The current version includes a dedicated administrator workflow for reinstating suspended NGO applications.

- Only authorized administrators can initiate reinstatement.
- The administrator must provide a non-empty reinstatement reason.
- Only the applicant's latest suspended application can be reinstated.
- Administrators cannot reinstate their own applications.
- Successful reinstatement changes the application status from `suspended` to `approved`.
- The applicant's profile role is restored to `ngo`.
- The original suspension audit event is preserved.
- A separate `ngo_application_reinstated` audit event records the reinstatement decision.
- NGO dashboard access becomes available again after the persisted application status and profile role satisfy the eligibility checks.

The workflow is implemented through a restricted PostgreSQL RPC and the `admin-ngo-management` Supabase Edge Function.

---

## 🏗️ System Architecture

```text
                         USER
                           |
                           v
                  React + Vite Frontend
                           |
                           v
                    Supabase Auth
                           |
                           v
                  Supabase Edge Functions
                           |
          +----------------+----------------+
          |                |                |
          v                v                v
    AI Symptom        NGO Application    Admin/NGO
     Analysis          Management       Management
          |                |                |
          +----------------+----------------+
                           |
                           v
                    PostgreSQL
                  + Row Level Security
                           |
             +-------------+-------------+
             |                           |
             v                           v
       User Dashboard              NGO Dashboard
                                         |
                                         v
                              Privacy-Preserving
                                  Analytics
```

The frontend is built with React and Vite. Backend operations are handled through Supabase Edge Functions and PostgreSQL.

Authentication, database permissions, server-side authorization, and Row Level Security enforce access boundaries across the platform.

---

## ⚙️ Technology Stack

| Layer | Technologies |
|---|---|
| Frontend | React, TypeScript, Vite |
| Styling | Tailwind CSS |
| UI Components | shadcn/ui, Radix UI |
| Icons | Lucide React |
| Backend | Supabase Edge Functions, Deno, TypeScript |
| Database | PostgreSQL, Supabase |
| Authentication | Supabase Auth, JWT |
| Database Security | Row Level Security, PostgreSQL ACLs |
| Testing | Vitest, React Testing Library, pgTAP |
| Build Tool | Vite |
| Backend Management | Lovable Cloud |
| Frontend Deployment | Vercel |
| Version Control | Git and GitHub |

---

## 🔐 Security and Privacy

Security is enforced at multiple layers rather than relying only on frontend route protection.

### Authentication and Authorization

- Authentication is managed through Supabase Auth.
- Administrator privileges are exclusively granted through `public.user_roles` with the `admin` role.
- Profile roles are restricted to `user` and `ngo`.
- Profile metadata cannot grant administrator privileges.
- Public signup cannot create administrator accounts.
- Protected administrative operations validate authorization on the backend.

### NGO Application Security

- NGO approval and suspension decisions are handled through protected backend workflows.
- NGO reviewers cannot review their own applications.
- Rejection and suspension require a reason.
- Reinstatement is restricted to the latest suspended application.
- Applicant identity and reviewer identity are derived and verified server-side.
- Administrative decisions are recorded in the audit log.

### Database Security

- PostgreSQL Row Level Security protects application data.
- Sensitive operations use restricted database functions.
- Function execution permissions follow least-privilege principles.
- Security-sensitive functions use controlled ownership and search-path settings.
- Administrative and NGO workflows validate state transitions at the database level.

### Analytics Privacy

- NGO analytics are provided through an authorized backend workflow.
- The backend independently verifies the requesting user's identity and NGO eligibility.
- Small-cohort analytics are suppressed to reduce the risk of exposing individual-level information.
- The current minimum analytics cohort threshold is **10**.
- The frontend does not directly read individual symptom records for NGO analytics.

### Account Management

- Account deletion is handled through an authenticated server-side workflow.
- Public users cannot directly assign privileged roles.
- Initial administrator provisioning is an authorized project-owner operation.

---

## 📂 Project Structure

```text
AI-HealthBot-Companion/
|
├── public/
|
├── src/
│   ├── components/
│   ├── hooks/
│   ├── integrations/
│   │   └── supabase/
│   ├── lib/
│   ├── pages/
│   │   ├── AdminDashboard.tsx
│   │   ├── NgoApplication.tsx
│   │   ├── Dashboard.tsx
│   │   ├── Auth.tsx
│   │   └── Profile.tsx
│   ├── test/
│   └── main.tsx
|
├── supabase/
│   ├── functions/
│   │   ├── admin-ngo-management/
│   │   ├── analyze-symptoms/
│   │   ├── dashboard-stats/
│   │   ├── delete-account/
│   │   └── ngo-application/
│   ├── migrations/
│   └── tests/
|
├── drizzle/
│   └── migrations/
|
├── docs/
|
├── package.json
├── tsconfig.json
├── vite.config.ts
└── README.md
```

---

## 💻 Getting Started

### Prerequisites

- Node.js (LTS recommended).
- npm.
- Access to a configured Supabase project.
- Required AI provider credentials for symptom analysis.

### 1. Clone the Repository

```bash
git clone https://github.com/priyanshuranjan02/AI-HealthBot-Companion.git

cd AI-HealthBot-Companion
```

### 2. Install Dependencies

```bash
npm install
```

### 3. Configure Environment Variables

Create a `.env` file in the project root:

```env
VITE_SUPABASE_URL=your_supabase_project_url

VITE_SUPABASE_PUBLISHABLE_KEY=your_supabase_publishable_key
```

Configure backend-only credentials and AI provider secrets through the authorized Supabase/Lovable backend environment.

> **Security Notice:** Never expose service-role keys, private API keys, or AI provider secrets through frontend environment variables. Never commit credentials or `.env` files to Git.

### 4. Start the Development Server

```bash
npm run dev
```

Vite will display the local development URL in the terminal.

---

## ⚡ Supabase Edge Functions

The application uses the following backend functions:

| Function | Responsibility |
|---|---|
| `analyze-symptoms` | AI-assisted symptom analysis |
| `dashboard-stats` | Authorized, privacy-preserving NGO analytics |
| `admin-ngo-management` | Administrator authentication and NGO verification, approval, rejection, suspension, and reinstatement |
| `ngo-application` | NGO application submission and status management |
| `delete-account` | Authenticated account deletion |

Backend database operations use PostgreSQL functions, Row Level Security, and restricted execution permissions.

### Important Migration Safety

The repository contains historical migrations and alternative migration candidates.

Do not blindly execute every migration in chronological order or run a generic `supabase db push` against a hosted project without reconciling its actual schema, migration history, ownership, privileges, and security contracts.

Production database changes and Edge Function deployments must follow the reviewed deployment workflow for the connected Lovable/Supabase environment.

A successful frontend deployment does not automatically apply database migrations or deploy Edge Functions.

---

## 🧪 Testing and Validation

Run the frontend test suite:

```bash
npm test
```

Run TypeScript validation:

```bash
npx tsc --noEmit
```

Run lint checks:

```bash
npm run lint
```

Create a production build:

```bash
npm run build
```

Preview the production build locally:

```bash
npm run preview
```

Database-level pgTAP tests are maintained separately under the testing directories and require an appropriately configured disposable database.

### Current Version — Validation Summary

| Validation | Result |
|---|---|
| Vitest | 162 passed, 3 skipped |
| TypeScript validation | Passed |
| ESLint | 0 errors, 7 warnings |
| Production build | Passed |
| SQL security checks | 120/120 passed in synthetic validation |
| NGO workflow concurrency checks | Passed in isolated synthetic testing |
| Admin/NGO reinstatement integration | Passed in isolated synthetic testing |
| Production reinstatement happy path | Successfully verified |

**Validation scope and limitations**

- The automated SQL and concurrency results were obtained using isolated synthetic PostgreSQL/Supabase-compatible fixtures. They are not a substitute for production security testing.
- The reinstatement happy path was successfully verified in production on November 11, 2026.
- The production verification confirmed the application status changed to `approved`, the applicant profile role returned to `ngo`, and a separate `ngo_application_reinstated` audit event was recorded.
- The applicant was able to access the NGO dashboard after reinstatement.
- Negative production scenarios, including unauthorized administrators, self-review attempts, duplicate requests, and invalid-state transitions, have not all been independently exercised against production.

These results should not be interpreted as exhaustive production security certification.

---

## 🌐 Deployment

### Frontend — Vercel

The frontend is deployed through Vercel Git integration.

**Production URL:**  
https://ai-health-bot-companion.vercel.app

Recommended Vercel project settings:

| Setting | Value |
|---|---|
| Framework Preset | Vite |
| Build Command | `npm run build` |
| Output Directory | `dist` |
| Install Command | `npm install` |
| Production Branch | `main` |

Configure the following frontend environment variables in Vercel:

```env
VITE_SUPABASE_URL=your_supabase_project_url

VITE_SUPABASE_PUBLISHABLE_KEY=your_supabase_publishable_key
```

### Backend — Lovable Cloud / Supabase

The backend is managed through the connected Lovable Cloud/Supabase environment.

It includes:

- PostgreSQL database and migrations.
- Supabase Edge Functions.
- Authentication and authorization.
- Database access policies and RPC functions.
- Backend environment secrets.

Backend changes must be reviewed and deployed independently of frontend changes.

---

## ✅ Current Development Status

**Current release: November 2026**

The current version includes:

- AI-assisted multilingual symptom assessment.
- User authentication and profile management.
- User health assessment history and reports.
- NGO application and verification workflows.
- Admin approval, rejection, and suspension workflows.
- Privacy-preserving NGO analytics.
- Secure administrator authorization.
- Audit logging for NGO administrative decisions.
- Production-deployed NGO reinstatement workflow.

### Latest Completed Milestone: NGO Reinstatement

| Milestone | Status |
|---|---|
| Secure reinstatement backend workflow | Completed |
| Database RPC and authorization controls | Deployed |
| `admin-ngo-management` Edge Function | Deployed |
| Frontend integration | Merged |
| Pull Request #6 | Merged into `main` |
| Production reinstatement test | Successful |
| Applicant NGO dashboard restoration | Verified |

The current release is frozen following successful production verification. Additional security regression scenarios, cleanup, and broader enhancements are deferred to a future development version.

---

## 🔮 Future Enhancements

The following items are potential future improvements and are not represented as completed features in the current release:

- Location-based hospital discovery.
- Voice-based symptom input.
- Text-to-speech health guidance.
- Appointment scheduling.
- Doctor consultation integration.
- Improved offline accessibility.
- Expanded privacy-preserving NGO analytics.
- Additional production security regression tests.
- Further administrative workflow improvements.

---

## 🤝 Contributing

Suggestions, bug reports, and contributions are welcome.

1. Fork the repository.
2. Create a feature branch from the latest `main`.
3. Implement the change.
4. Add or update relevant tests.
5. Run the available validation commands.
6. Submit a pull request with a clear description.

Security-related changes should include appropriate authorization, database, and regression tests.

---

## 📬 Contact

**Priyanshu Ranjan**

- Email: [ranjanpriyanshu441@gmail.com](mailto:ranjanpriyanshu441@gmail.com)
- LinkedIn: [Priyanshu Ranjan](https://www.linkedin.com/in/priyanshu-ranjan-74170a227/)
- GitHub: [@priyanshuranjan02](https://github.com/priyanshuranjan02)
- Repository: [AI HealthBot](https://github.com/priyanshuranjan02/AI-HealthBot-Companion)

---

⭐ If you find this project useful, consider giving the repository a star.
