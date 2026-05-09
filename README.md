# WalkieTalkie
voice based agentice overlay for Field service technicians 


# 🎙️ Walkie Talkie for Techs
### Voice-Enabled Field Intelligence for Salesforce Field Service

[![Status](https://img.shields.io/badge/status-active--development-brightgreen)]()
[![Platform](https://img.shields.io/badge/platform-Salesforce%20FSL-00A1E0)]()
[![POC](https://img.shields.io/badge/phase-POC%20v1.0-orange)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

---

## Overview

**Walkie Talkie for Techs** is an open exploration of voice-enabled agentic tooling for field service technicians working in fleet maintenance environments. The project is built on Salesforce Field Service and explores what happens when you remove the keyboard from field data capture entirely.

The core idea is simple: technicians working on vehicles in yards and maintenance facilities are not knowledge workers sitting at desks. They are standing next to trucks with gloves on. Every moment they spend navigating a mobile app is a moment they are not working. Voice is the natural interface for this environment — and modern LLMs make it possible to turn unstructured spoken language into structured, actionable Salesforce data.

This project is being built incrementally, starting with the highest-value, lowest-complexity use case and expanding outward. Each phase is a working, demonstrable artifact — not a prototype that never ships.

---

## Why This Exists

Large fleet maintenance operations generate enormous volumes of work order data but consistently underinvest in *why* data. Why was this repair performed? What did the technician observe? What was the root cause? What was done to fix it?

This gap creates real problems:

- **Client audit exposure** — When a customer questions a $3,000 invoice, there is often no structured record of the diagnostic rationale
- **Operational blindness** — Without structured complaint and cause data, fleet-level pattern recognition is impossible
- **Tech friction** — Every data entry requirement that doesn't feel worthwhile to a technician is a data entry requirement that gets skipped

Voice-first, LLM-backed tooling addresses all three simultaneously: it captures the *why*, structures it automatically, and makes the capture experience fast enough that technicians will actually do it.

---

## Architecture Principles

This project makes deliberate architectural choices that are worth stating explicitly:

**LLM as orchestration brain, Salesforce as persistence target.** Rather than forcing logic through Agentforce's structured flow model, the pattern here is to give the LLM genuine reasoning authority and use Salesforce's REST API as a clean write endpoint. This keeps the intelligence layer flexible and the Salesforce layer simple.

**Apex as the callout layer.** All external API calls (LLM, STT) route through Salesforce Apex via Named Credentials. The mobile front end (LWC) never makes direct external calls. This is the correct enterprise pattern and keeps credentials secure.

**Azure OpenAI for production, direct OpenAI API for development.** POC builds use the OpenAI API directly (fast, cheap, no procurement). Production deployments target Azure OpenAI and Azure AI Speech within existing enterprise Azure infrastructure — same models, enterprise data agreements, no new vendors.

**Progressive complexity.** Each phase is a working system, not a stepping stone. v1.0 ships. v1.1 extends it. Nothing gets thrown away.

---

## Project Phases

### ✅ Phase 1 — Complaint, Cause & Correction (CCC) Capture

**Status:** In Development  
**Branch:** `feature/ccc-capture`

The first feature and the POC that funds everything else. Technicians describe their work in natural language — what they found, why it happened, what they did about it. An LLM structures that narrative into discrete Complaint, Cause, and Correction fields on the Salesforce Work Order.

**v1.0 — Text Input (POC)**
- LWC component on the Work Order record with a text input field
- Apex callout to OpenAI GPT-4o for CCC extraction
- Four fields written to the Work Order: raw input, complaint, cause, correction
- Demoable on Salesforce mobile app (iOS)

**v1.1 — Voice Input**
- MediaRecorder API in LWC captures technician audio
- Audio transcribed via OpenAI Whisper
- Transcribed text passed through existing CCC extraction pipeline
- Same four fields, same write pattern — only the input method changes

**Data Model:**

| Field | API Name | Type | Description |
|-------|----------|------|-------------|
| CCC — Raw Input | `CCC_Raw_Input__c` | Long Text Area | Unmodified technician input |
| CCC — Complaint | `CCC_Complaint__c` | Long Text Area | LLM-extracted symptom/observation |
| CCC — Cause | `CCC_Cause__c` | Long Text Area | LLM-extracted root cause |
| CCC — Correction | `CCC_Correction__c` | Long Text Area | LLM-extracted corrective action |

**Tech Stack:**
- Salesforce LWC + Apex
- OpenAI GPT-4o (dev) / Azure OpenAI (production)
- OpenAI Whisper (dev) / Azure AI Speech (production)
- Salesforce Named Credentials for API auth

---

### 🔜 Phase 2 — Work Order Opening ("What Am I Working On?")

Technician arrives at a yard or job site and speaks a simple prompt: *"What do I have to work on today?"* The system identifies open work orders assigned to them at that location and reads back the relevant details — vehicle, job type, priority. No navigating. No searching. Just an answer.

**Planned approach:**
- Voice trigger → STT → LLM with Salesforce MCP connector
- LLM queries Salesforce for assigned WOs by technician and location
- Structured spoken/text response returned to technician
- Introduces the MCP pattern for dynamic Salesforce data querying

---

### 🔜 Phase 3 — Starting Work ("Clock Me In")

Technician speaks: *"I'm starting work on WO-00123."* System confirms the work order, sets status to In Progress, and timestamps the start. Simple, fast, hands-free.

**Planned approach:**
- Voice → STT → LLM intent classification
- LLM identifies WO identifier and action intent
- Apex updates WO status and start time via REST
- Introduces intent classification as a pattern alongside extraction

---

### 🔜 Phase 4 — Work Order Close-Out

Technician closes out a completed job. Standard close-out first, then a more complex variant covering close-out in arrears (work completed but not yet logged). CCC capture (Phase 1) becomes a natural part of this flow — the close-out prompt surfaces CCC if it hasn't been captured yet.

**Planned approach:**
- Voice close-out trigger → LLM confirms job details
- CCC prompt integrated if fields are empty
- WO status, completion time, and labor records updated via Apex/REST

---

### 🔜 Phase 5 — Product Consumption & Quantity Verification

Technician reports parts used: *"I used two quarts of 15W-40 and one fuel filter."* System identifies the products, quantities, and associated WO, and writes consumption records. Includes verification — if quantities seem unusual, the system flags for confirmation before writing.

**Planned approach:**
- Voice → STT → LLM product/quantity extraction
- LLM cross-references against expected parts for the job type
- Introduces verification/re-prompt pattern before write
- Most complex data extraction phase — multiple entities, unit parsing, catalog matching

---

### 🔜 Phase 6 — Additional Labor & Products

Technician identifies scope additions mid-job: *"I also need to replace the serpentine belt — adding that as a new line."* System creates new labor or product line items on the WO without requiring the technician to navigate into the app.

---

## Repo Structure

```
walkie-talkie-for-techs/
│
├── force-app/
│   └── main/
│       └── default/
│           ├── lwc/
│           │   └── cccCapture/          # Phase 1 LWC component
│           ├── classes/
│           │   └── CCCCaptureController.cls  # Apex callout controller
│           └── objects/
│               └── WorkOrder/
│                   └── fields/          # Custom field metadata
│
├── docs/
│   ├── PRD_CCC_v1.0.md                 # Product requirements — text POC
│   ├── PRD_CCC_v1.1.md                 # Product requirements — voice
│   └── architecture/
│       └── phase1_architecture.md
│
├── prompts/
│   └── ccc_extraction.txt              # LLM prompt for CCC extraction
│
├── scripts/
│   └── apex/                           # Anonymous Apex for setup/testing
│
└── README.md
```

---

## Getting Started

### Prerequisites
- Salesforce Developer Org (free at [developer.salesforce.com](https://developer.salesforce.com))
- Salesforce CLI (`sf` / `sfdx`)
- OpenAI API key ([platform.openai.com](https://platform.openai.com))
- Node.js (for local development tooling)

### Setup

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/walkie-talkie-for-techs.git
cd walkie-talkie-for-techs

# Authenticate to your dev org
sf org login web --alias wtt-dev

# Deploy metadata
sf project deploy start --target-org wtt-dev
```

### Configure Named Credential
1. In your dev org, navigate to **Setup → Named Credentials**
2. Create a new Named Credential for OpenAI:
   - **Label:** OpenAI API
   - **URL:** `https://api.openai.com`
   - **Auth Protocol:** Custom Header
   - **Header:** `Authorization: Bearer YOUR_OPENAI_API_KEY`

### Add Custom Fields to Work Order
Deploy the included field metadata or create manually:
- `CCC_Raw_Input__c` — Long Text Area (32,768)
- `CCC_Complaint__c` — Long Text Area (32,768)
- `CCC_Cause__c` — Long Text Area (32,768)
- `CCC_Correction__c` — Long Text Area (32,768)

---

## Design Decisions & Trade-offs

| Decision | Chosen Approach | Alternative Considered | Reason |
|----------|----------------|----------------------|--------|
| LLM provider (dev) | OpenAI API direct | Agentforce / Einstein | Speed of iteration; model capability; Agentforce better suited for structured flow orchestration than free-form extraction |
| LLM provider (prod) | Azure OpenAI | OpenAI direct | Enterprise data agreements; existing Ryder Azure relationship |
| Callout pattern | Apex → external API | LWC → external API | Named Credential security; standard enterprise Salesforce pattern |
| Salesforce integration | REST API write | MCP (Phases 1-3) | MCP complexity not warranted for single-field write; MCP introduced in Phase 2 where dynamic querying is needed |
| Audio capture (v1.1) | MediaRecorder API in LWC | Native FSL Extension | Lower build complexity; validated approach for iOS; Android requires FSL Extension Toolkit |

---

## Known Constraints & Open Questions

- **Android audio capture:** `getUserMedia` / MediaRecorder does not work reliably in the Salesforce mobile app Android WebView. iOS is the validated demo platform. Cross-platform production support likely requires the FSL Mobile Extension Toolkit (React Native).
- **LWS dependency:** Lightning Web Security must be enabled on the org for `getUserMedia` access in LWC without a Visualforce page workaround.
- **MediaRecorder in FSL WebView:** Needs spike validation before v1.1 build begins. Go/no-go gate.
- **Azure OpenAI provisioning:** Production deployment requires Azure OpenAI to be provisioned in the target enterprise Azure tenant. Lead time varies.

---

## Portfolio Context

This project sits at the intersection of several things I'm actively building toward:

- **Enterprise solutions architecture** — Designing systems that cross platform boundaries (Salesforce, Azure, OpenAI) rather than optimizing within a single vendor's ecosystem
- **Agentic patterns in the enterprise** — Real-world application of LLM orchestration, structured extraction, and MCP patterns in a production Salesforce context
- **Field-first UX thinking** — The best enterprise software is invisible. This project is about reducing friction to zero for people doing physical work

I'm building this in public as a way of documenting the architectural thinking, not just the code. The `/docs` folder is as important as `force-app`.

---

## Roadmap

- [x] Project scoping and architecture design
- [x] PRD — CCC Capture v1.0 (text)
- [x] PRD — CCC Capture v1.1 (voice)
- [ ] Custom field deployment on Work Order
- [ ] Named Credential setup (OpenAI)
- [ ] `cccCapture` LWC — text input (v1.0)
- [ ] `CCCCaptureController` Apex class
- [ ] End-to-end v1.0 demo on Salesforce mobile (iOS)
- [ ] MediaRecorder spike — iOS WebView validation
- [ ] `cccCapture` LWC — voice input (v1.1)
- [ ] Whisper integration in Apex (v1.1)
- [ ] Phase 2 scoping — WO query / "what am I working on?"

---

## Contributing

This is a portfolio and exploration project. If you're building something similar in the Salesforce + LLM space and want to compare notes, open an issue or reach out directly.

---

## License

MIT — build on it, learn from it, take it somewhere interesting.
