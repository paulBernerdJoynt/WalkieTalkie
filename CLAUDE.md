# WalkieTalkie — CCC Capture (v1.0)

Salesforce SFDX project. Target org alias: `agentforce poc`.

## Deploy

```bash
# Set default org
sf config set target-org "agentforce poc"

# Deploy everything
sf project deploy start --source-dir force-app

# Run Apex tests
sf apex run test --test-level RunLocalTests --wait 10
```

## Post-Deploy Setup (required — do this after first deploy)

### 1. Enter the OpenAI API key

The API key is stored in a **Protected Hierarchy Custom Setting** (`CCC_Configuration__c`). It cannot be deployed via metadata — enter it in the org UI or via the CLI:

```bash
sf apex run --target-org "agentforce poc" <<'EOF'
CCC_Configuration__c config = new CCC_Configuration__c();
config.SetupOwnerId = UserInfo.getOrganizationId();
config.OpenAI_Key__c = 'sk-YOUR-KEY-HERE';
upsert config;
EOF
```

Or: Setup → Custom Settings → CCC Configuration → Manage → New (Org-level default).

### 2. Add the LWC to the Work Order record page

1. Open any Work Order record
2. Click the gear icon → Edit Page (Lightning App Builder)
3. Drag `cccCapture` from the Components panel onto the page
4. Save and Activate

### 3. Verify Remote Site Setting

Setup → Remote Site Settings → `OpenAI_API` — confirm URL is `https://api.openai.com` and is active.

## Architecture

```
[LWC: cccCapture]
    ↓ @AuraEnabled
[Apex: CCCController]
    ↓ callout:OpenAI_API/v1/chat/completions
[OpenAI GPT-4o]
    ↓ JSON { complaint, cause, correction }
[WorkOrder: CCC_Complaint__c / CCC_Cause__c / CCC_Correction__c]
```

## Key Files

- `force-app/main/default/classes/CCCController.cls` — Apex callout + DML
- `force-app/main/default/lwc/cccCapture/` — LWC component
- `force-app/main/default/objects/WorkOrder/fields/` — 4 custom fields
- `force-app/main/default/objects/CCC_Configuration__c/` — Protected custom setting (API key)
- `force-app/main/default/remoteSiteSettings/OpenAI_API.remoteSite-meta.xml` — Allows outbound callout to api.openai.com

## Roadmap

- v1.0: Text input → LLM extraction → structured CCC on Work Order (this)
- v1.1: Voice/STT input replacing the textarea
- v2: Re-prompt loop for quality validation
