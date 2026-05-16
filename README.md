# WalkieTalkie — CCC Capture POC
**Proof of Concept: Complaint, Cause & Correction extraction for Salesforce Field Service**

[![Status](https://img.shields.io/badge/status-POC-blue)]()
[![Phase](https://img.shields.io/badge/phase-1%20of%206-lightgrey)]()
[![Platform](https://img.shields.io/badge/platform-Salesforce%20LWC%2BAlex-00A1E0)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

---

## What This Is

This is a working proof of concept for one specific problem: fleet maintenance technicians spend time navigating mobile apps instead of working. This POC demonstrates how to capture structured work data (what was found, why it happened, what was done) through natural language input and LLM extraction — eliminating unnecessary UI navigation.

**Current state:** Text input → LLM extraction → Salesforce fields (v1.0). Works on Salesforce mobile app.

**This is not:** A complete voice-first platform. A full agentic layer for field service. Shipping to production. This is phase 1 of a larger vision called WalkieTalkie, but this repository contains only the first, proven piece.

---

## The Problem

Fleet maintenance operations generate work order volumes but skip the *why* data:
- Why was this repair done?
- What did the technician observe?
- What was the root cause?
- What fixed it?

This creates real friction:
- **Audit exposure** — A $3K invoice with no diagnostic reasoning
- **Operational blindness** — No pattern recognition without structured complaint/cause data
- **Tech friction** — Technicians on their feet with gloves won't navigate nested mobile UI forms just to document their work

This POC tests a specific hypothesis: **Can we capture the 'why' through natural language + LLM extraction fast enough that field technicians will actually do it?**

---

## Approach

This POC demonstrates a specific architecture pattern for integrating LLMs with Salesforce:

1. **LWC component** captures technician input on the Work Order page
2. **Apex controller** handles the outbound callout to OpenAI GPT-4o
3. **LLM extracts structure** (Complaint, Cause, Correction) from unstructured text
4. **Apex writes back** to four custom Work Order fields

This is intentionally narrow: prove that the pattern works, measure the UX, validate that the output quality is acceptable. Future phases (voice input, dynamic queries, re-prompting) would extend this pattern, not replace it.

**Why this architecture:**
- Credentials stay server-side (Named Credentials in Apex, never exposed to LWC)
- LLM processing happens server-side (compliant with enterprise data agreements, easier to migrate to Azure OpenAI)
- The LWC is just a thin input layer — simple to test and change

---

## Phase 1: Complaint, Cause & Correction (CCC) Capture — Text Input

**Status:** Working POC  
**Target:** Salesforce mobile app (iOS)  
**Implementation:** LWC + Apex + OpenAI GPT-4o

Technicians type a free-form description of their work. The LLM structures it into three fields and writes to the Work Order.

### What's Implemented

| What | Where |
|------|-------|
| LWC text input | `force-app/main/default/lwc/cccCapture/` |
| Apex callout controller | `force-app/main/default/classes/CCCController.cls` |
| Work Order custom fields | `force-app/main/default/objects/WorkOrder/fields/` |
| Extraction prompt | `force-app/main/default/prompts/` |

### Custom Fields on Work Order

- `CCC_Raw_Input__c` — The technician's original text
- `CCC_Complaint__c` — LLM-extracted symptom/observation
- `CCC_Cause__c` — LLM-extracted root cause
- `CCC_Correction__c` — LLM-extracted corrective action

### What Works

✅ Deploy via SF CLI  
✅ LWC renders on Work Order page  
✅ Text input → OpenAI GPT-4o → Field write  
✅ Accessible on Salesforce mobile (iOS)  
✅ Cost per extraction: ~$0.01 (dev pricing)

### What Doesn't Work Yet

❌ Voice input (requires MediaRecorder validation in SF mobile WebView)  
❌ Error recovery / re-prompting  
❌ Quality validation before write  
❌ Production env (would require Azure OpenAI provisioning)

---

## Longer Vision (If Phase 1 Validates)

If this POC proves that technicians will actually capture structured data through natural language input, the pattern extends to:

- **Voice input** — Replace text with speech capture and transcription
- **Work order queries** — "What do I have assigned today?" → LLM → Salesforce MCP
- **Workflow state** — "Starting work" / "Work complete" voice triggers
- **Parts tracking** — Natural language parts consumption + verification loop
- **Re-prompting** — Quality gates before write (confidence scoring, validation requests)

Each of these is a separate POC with its own hypothesis. None are committed.

---

## Setup

### Prerequisites
- Salesforce Developer Org
- Salesforce CLI (`sf`)
- OpenAI API key
- A Work Order to test on

### Deploy

```bash
# Authenticate
sf org login web --alias walkie-dev

# Deploy metadata
sf project deploy start --target-org walkie-dev --source-dir force-app

# Set the OpenAI API key (via Anonymous Apex in CLI or org UI)
# Setup → Custom Settings → CCC Configuration → Manage → New
```

### Add the Component to Work Order

1. Open a Work Order record
2. Click the gear icon → Edit Page
3. Drag `cccCapture` from Components onto the page
4. Save and Activate
5. Test with text input

---

## Design Decisions

| Decision | Chosen | Why |
|----------|--------|-----|
| **Callout pattern** | Apex via Named Credentials | Standard enterprise Salesforce pattern; credentials server-side only |
| **LLM provider (dev)** | OpenAI API direct | Fast iteration; model quality; no procurement friction |
| **LLM provider (prod)** | Azure OpenAI | Enterprise data agreements; existing infrastructure |
| **When to write** | Immediately on extraction | Simpler UX for POC; validation/re-prompting deferred to future phase |
| **Error handling** | User-facing message, no retry | POC scope; production would need retry logic + observability |

---

## Constraints & Open Questions

- **Android WebView:** MediaRecorder doesn't reliably capture audio in SF mobile app on Android. iOS validated. Future voice input likely requires FSL Mobile Extension Toolkit.
- **Lightning Web Security:** Must be enabled on the org for `getUserMedia` access (needed for voice input in v1.1).
- **Extract quality:** POC doesn't validate extraction quality before write. Production use would need confidence scoring / re-prompt.
- **Azure provisioning:** Moving to Azure OpenAI requires tenant setup and lead time. Not blocking this POC.

---

## What This Demonstrates

For someone evaluating this work:

- **Systems thinking across boundaries** — Integrating Salesforce, OpenAI, and mobile UI without forcing everything into a single vendor's model
- **Shipping over perfection** — This is a working POC, not a fully hardened system. Real artifacts over theoretical roadmaps.
- **Honest constraint documentation** — Not hiding the Android WebView issue or the need for Azure provisioning later
- **LLM as a tool, not magic** — Structured prompt, predictable extraction, clean integration pattern

---

## Roadmap (Phase 1 Only)

- [x] Problem scoping and architecture
- [x] CCC extraction prompt
- [x] Custom fields on Work Order
- [x] LWC component + Apex controller
- [x] OpenAI callout integration
- [ ] End-to-end testing on Salesforce mobile (iOS)
- [ ] Demo readiness

Future phases (voice input, work order queries, workflow state) would follow only if Phase 1 demonstrates utility.

---

## License & Use

MIT — use this as a reference for Salesforce + LLM integration patterns, fork it, build on it.
