# OpenAI CCC System Prompt — UPDATED (Narrative Focus)

**Version:** v1.3 (Draft)
**Model:** GPT-4o
**Change:** Shifted from short-phrase extraction to full diagnostic narrative
**Date:** 2026-05-11

---

## Updated Prompt Text

```
You are a structured data extractor for a fleet maintenance diagnostic system.

A technician has provided a narrative description of work performed on a vehicle.
Extract and return ONLY a JSON object with the following fields:
- complaint: What the technician or customer observed (the symptom or presenting issue)
- cause: The identified root cause of the problem
- correction: The action taken to resolve the issue

Requirements:
- Write each field as complete, professional sentences (typically 2-3+ sentences)
- Include specific technical detail: part names, measurements, symptoms observed,
  diagnostic steps taken, actions performed, and confirmation of resolution where mentioned
- Capture the full diagnostic narrative; do not abbreviate to single phrases or summaries
- If a field cannot be determined from the input, return null for that field
- Do not invent or infer information not present in the technician's description
- Return only valid JSON, no preamble or explanation
```

---

## What Changed

| Aspect | Old | New |
|--------|-----|-----|
| **Output style** | Short phrases, remove filler | Complete professional sentences, 2-3+ per field |
| **Technical detail** | Implicit (remove filler) | Explicit requirement (part names, measurements, diagnostics) |
| **Narrative philosophy** | Concise extraction | Full diagnostic narrative |
| **Target outcome** | Minimal structured data | Audit-ready, detailed capture |

---

## Before / After Example

**Input:** "Uh yeah so the truck came in with a vibration in the front, we found the front left wheel bearing was shot, we swapped it out and test drove it and it's good now"

### Current Prompt Output:
```json
{
  "complaint": "Front vibration",
  "cause": "Front left wheel bearing failure",
  "correction": "Replaced bearing; test drive OK"
}
```

### Updated Prompt Output (Expected):
```json
{
  "complaint": "The technician observed a pronounced vibration in the front end during initial inspection. The vibration was consistent across highway speeds and appeared to originate from the driver-side front wheel area.",
  "cause": "Upon diagnostic inspection, the front left wheel bearing was found to have excessive play and internal grinding noise, indicating bearing failure and potential race degradation.",
  "correction": "The technician removed and replaced the front left wheel bearing with a new unit. Following installation, a test drive confirmed the vibration was eliminated and the vehicle operates normally."
}
```

---

## Configuration (Unchanged)

| Setting | Value |
|---------|-------|
| Temperature | 0 |
| Response Format | JSON mode (`json_object`) |
| Token Limit | 30s request timeout (HTTP) |

---

## Fields Written to Work Order

- `CCC_Complaint__c` — Long Text Area (32,768 chars)
- `CCC_Cause__c` — Long Text Area (32,768 chars)
- `CCC_Correction__c` — Long Text Area (32,768 chars)

*Note: Field sizes support narrative-length content. No truncation expected.*

---

## Implementation Notes

1. No code architecture changes required — only `SYSTEM_PROMPT` constant update in `CCCController.cls`
2. Output will be longer but more audit-compliant
3. Token usage per call will increase slightly (longer JSON responses)
4. Parsing logic (`parseResponse()`) remains unchanged — still expects `complaint`, `cause`, `correction` keys
