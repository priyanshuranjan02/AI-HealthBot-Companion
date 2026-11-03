# 🩺 AI HealthBot

### AI-Powered Multilingual Healthcare Assistant for Symptom Assessment and Risk Triage

AI HealthBot is a full-stack healthcare support platform designed to make preliminary health information and symptom assessment more accessible. It combines conversational AI, symptom-based risk assessment, secure health profiles, and dedicated workflows for NGOs and administrators.

> ⚠️ **Medical Disclaimer:** AI HealthBot is an informational and decision-support tool. It does not provide a definitive medical diagnosis and is not a substitute for professional medical advice, diagnosis, or treatment. Always consult qualified healthcare professionals.

---

## 🚀 Features

### 🤖 AI Healthcare Assistant
- Conversational AI-assisted symptom assessment.
- Contextual follow-up questions.
- Severity-based risk categorization: Low, Moderate, and High.
- Multilingual healthcare support.
- Personalized health guidance and recommendations.
- Downloadable health reports.
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
- Privacy-preserving health analytics.
- Small-cohort suppression to protect sensitive information.

### 🛡️ Administrator Portal
- Dedicated administrator authentication.
- Role-based access control.
- NGO application verification.
- Approval, rejection, and suspension workflows.
- Mandatory reasons for rejection and suspension.
- Application statistics and review history.
- Prevention of administrator self-review.

---

## 🏗️ System Architecture

    USER
      |
      v
    React + Vite Frontend
      |
      v
    Supabase Authentication
      |
      v
    Supabase Edge Functions
      |
      +---------------------+---------------------+
      |                     |                     |
      v                     v                     v
    AI Symptom          NGO Application       Admin/NGO
    Analysis             Management           Management
      |                     |                     |
      +---------------------+---------------------+
                            |
                            v
                   PostgreSQL Database
                    + Row Level Security
                            |
                 +----------+----------+
                 |                     |
                 v                     v
           User Dashboard        NGO Dashboard
                                       |
                                       v
                              Privacy-Preserving
                                  Analytics

The frontend is built with React and Vite. Backend operations are handled through Supabase Edge Functions and PostgreSQL. Authentication, database permissions, and server-side authorization enforce access boundaries.

---

## ⚙️ Technology Stack

| Layer | Technologies |
|---|---|
| Frontend | React, TypeScript, Vite |
| Styling | Tailwind CSS, shadcn/ui |
| UI Components | Radix UI, Lucide Icons |
| Backend | Supabase Edge Functions, Deno, TypeScript |
| Database | PostgreSQL, Supabase |
| Authentication | Supabase Auth, JWT |
| Database Security | Row Level Security, PostgreSQL ACLs |
| Testing | Vitest, React Testing Library, pgTAP |
| Build | Vite |
| Deployment | Vercel |

---

## 🔐 Security and Privacy

Security is enforced at multiple layers rather than relying only on frontend route protection.

- Administrator privileges are exclusively granted through `public.user_roles` with the `admin` role.
- Profile roles are restricted to `user` and `ngo`.
- Profile metadata cannot grant administrator privileges.
- NGO dashboard access requires an approved application and the appropriate profile role.
- Sensitive operations are validated by authenticated backend functions.
- NGO review operations prevent self-review.
- Rejection and suspension require a reason.
- Database access is protected through RLS and least-privilege grants.
- Analytics fail closed and suppress small cohorts.
- The current minimum analytics cohort threshold is 10.
- Account deletion is handled through an authenticated server-side workflow.

Public signup cannot create administrator accounts. Initial administrator provisioning is an authorized project-owner operation.

---

## 📂 Project Structure

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
    ├── docs/
    ├── package.json
    └── vite.config.ts

---

## 💻 Getting Started

### Prerequisites
- Node.js
- npm
- A Supabase project
- Required AI provider credentials for symptom analysis

### 1. Clone the Repository

    git clone https://github.com/priyanshuranjan02/AI-HealthBot-Companion.git
    cd AI-HealthBot-Companion

### 2. Install Dependencies

    npm install

### 3. Configure Environment Variables

Create a `.env` file in the project root:

    VITE_SUPABASE_URL=your_supabase_project_url
    VITE_SUPABASE_PUBLISHABLE_KEY=your_supabase_publishable_key

Configure backend-only credentials and AI provider secrets through the Supabase Edge Function environment.

**Never expose service-role keys or AI provider secrets through frontend variables or commit them to Git.**

### 4. Start the Development Server

    npm run dev

Vite will display the local development URL in your terminal.

---

## ⚡ Supabase Edge Functions

The application uses the following backend functions:

| Function | Responsibility |
|---|---|
| `analyze-symptoms` | AI-assisted symptom analysis |
| `dashboard-stats` | Authorized, privacy-preserving NGO analytics |
| `admin-ngo-management` | Administrator access and NGO verification |
| `ngo-application` | NGO application submission and status |
| `delete-account` | Authenticated account deletion |

Database migrations and SQL security tests are maintained under `supabase/`.

> **Migration safety:** Migration files include alternative baseline candidates. Their timestamps do not establish that they are all compatible or should be applied sequentially. Verify the target schema, migration history, ownership, and security contracts before applying migrations. Do not blindly run `supabase db push` against a hosted project with unreconciled migration history.

---

## 🧪 Testing and Validation

Run the frontend test suite:

    npm test

Run TypeScript validation:

    npx tsc --noEmit

Run lint checks:

    npm run lint

Create a production build:

    npm run build

Preview the production build locally:

    npm run preview

Database-level pgTAP tests are maintained separately under `supabase/tests/` and require an appropriately configured disposable database.

### Current Development Version — Verification Results

| Validation | Result |
|---|---|
| Vitest | 86 passed, 2 skipped |
| pgTAP | 98 assertions passed |
| TypeScript | Passed |
| ESLint | 0 errors, 7 warnings |
| Production build | Passed |
| Git diff validation | Passed |
| Admin/NGO backend integration | Passed |
| Browser role and workflow regression | Passed |

The two skipped tests are optional local Auth signup integration tests. Successful external AI-provider response verification remains a separate integration item.

---

## 🌐 Deployment

### Frontend — Vercel

The frontend can be deployed through Vercel Git integration.

Recommended project settings:

| Setting | Value |
|---|---|
| Framework Preset | Vite |
| Build Command | `npm run build` |
| Output Directory | `dist` |
| Install Command | `npm install` |

Configure these frontend environment variables in Vercel:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

A Git push can trigger a preview or production deployment depending on the repository connection, configured production branch, and Vercel deployment settings.

### Backend — Supabase

The backend is deployed separately from the Vercel frontend.

Supabase Edge Functions, database migrations, and required secrets must be configured and released through the approved Supabase deployment process.

A successful Vercel frontend deployment does not automatically deploy Edge Functions or apply database migrations.

---

## 🔮 Future Enhancements

- Location-based hospital discovery.
- Voice-based symptom input.
- Text-to-speech health guidance.
- Appointment scheduling.
- Doctor consultation integration.
- Improved offline accessibility.
- Expanded privacy-preserving NGO analytics.

---

## 🤝 Contributing

Suggestions, bug reports, and contributions are welcome.

1. Fork the repository.
2. Create a feature branch.
3. Implement and test your changes.
4. Submit a pull request with a clear description.

Security-related changes should include appropriate authorization and database regression tests.

---

## 📬 Contact

**Priyanshu Ranjan**

- Email: [ranjanpriyanshu441@gmail.com](mailto:ranjanpriyanshu441@gmail.com)
- LinkedIn: [Priyanshu Ranjan](https://www.linkedin.com/in/priyanshu-ranjan-74170a227/)
- GitHub: [@priyanshuranjan02](https://github.com/priyanshuranjan02)
- Repository: [AI HealthBot](https://github.com/priyanshuranjan02/AI-HealthBot-Companion)

---

⭐ If you find this project useful, consider giving the repository a star.
