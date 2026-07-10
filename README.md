# 🩺 AI HealthBot

> **An AI-Powered Multilingual Healthcare Assistant for Symptom Assessment and Risk Triage**

AI HealthBot is a full-stack healthcare web application that leverages **Machine Learning**, **Google Gemini 2.5 Flash**, and modern web technologies to provide preliminary symptom assessment, conversational health guidance, and severity-based risk triage for rural communities and NGOs.

> ⚠️ **Disclaimer:** AI HealthBot is a healthcare awareness and decision-support tool. It is **not a substitute for professional medical diagnosis or treatment**.

---

## 🚀 Features

- 🤖 AI-powered conversational healthcare assistant
- 🩺 Symptom assessment with contextual follow-up questions
- 📊 Severity-based risk triage (Low, Moderate, High)
- 🧠 Gemini 2.5 Flash integration for intelligent responses
- 🌍 Multilingual support
- 🔐 Secure authentication using Supabase Auth + JWT
- 👤 User profile and health history
- 📈 NGO dashboard with health analytics
- 🚨 Emergency assistance module
- 📱 Fully responsive UI
- 🌙 Dark/Light mode
- 📄 Downloadable health reports (PDF)

---


# 🏗️ System Architecture

```
User
   │
   ▼
React + Vite Frontend
   │
   ▼
Node.js + TypeScript Backend
   │
   ├─────────────► Gemini 2.5 Flash
   │
   ├─────────────► ML Symptom Analysis
   │
   ├─────────────► Supabase Database
   │
   └─────────────► JWT Authentication

           ▼

Prediction + Risk Analysis + Recommendation
```

---

# ⚙️ Tech Stack

## Frontend

- React
- TypeScript
- Vite
- Tailwind CSS
- shadcn/ui

## Backend

- Node.js
- TypeScript
- Supabase Edge Functions

## AI & Machine Learning

- Google Gemini 2.5 Flash
- Symptom Classification
- Risk Triage Engine

## Database

- Supabase (PostgreSQL)

## Authentication

- Supabase Auth
- JWT

## Other Tools

- Redis
- Lucide Icons
- React Router
- PDF Report Generation

---

# 📂 Project Structure

```
AI-HealthBot
│
├── src
│   ├── components
│   ├── pages
│   ├── hooks
│   ├── integrations
│   ├── lib
│   ├── utils
│   └── main.tsx
│
├── supabase
│   ├── functions
│   └── migrations
│
├── public
│
└── package.json
```

---

# 🔄 Workflow

1. User logs in securely
2. Selects a health category
3. Describes symptoms
4. AI asks follow-up questions
5. Gemini interprets responses
6. ML model predicts probable condition
7. System assigns risk level
8. Personalized recommendations are displayed
9. User can download the health report

---

# 🎯 Risk Categories

🟢 **Low Risk**
- Home care recommended

🟡 **Moderate Risk**
- Visit a healthcare professional

🔴 **High Risk**
- Immediate medical attention advised

---

# 🌟 Key Highlights

- Community-focused healthcare solution
- Rural accessibility
- AI-powered conversational interface
- Explainable health recommendations
- Secure authentication
- Modern dashboard and analytics
- Scalable full-stack architecture

---

# 💻 Installation

## Clone Repository

```bash
git clone https://github.com/priyanshuranjan02/AI-HealthBot-Companion.git
cd AI-HealthBot-Companion
```

Install dependencies

```bash
npm install
```

Run development server

```bash
npm run dev
```

---


# 📊 Future Enhancements

- 📍 Nearest Hospital Detection
- 🎤 Voice-based Symptom Input
- 🔊 Text-to-Speech Recommendations
- 📅 Appointment Scheduling
- 🧑‍⚕️ Doctor Consultation
- 📡 Offline Mode
- 📈 Advanced NGO Analytics


---

# 🤝 Contributing

Contributions, suggestions, and improvements are welcome.

Feel free to fork the repository and submit a pull request.

---


# 📬 Contact

**Priyanshu Ranjan**

📧 ranjanpriyanshu441@gmail.com

🔗 LinkedIn: [https://www.linkedin.com/in/priyanshu-ranjan-74170a227/](https://www.linkedin.com/in/priyanshu-ranjan-74170a227/)

💻 GitHub: https://github.com/priyanshuranjan02

---

⭐ If you found this project useful, consider giving it a **Star** on GitHub!
