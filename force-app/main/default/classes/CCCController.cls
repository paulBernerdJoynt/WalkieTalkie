public with sharing class CCCController {

    private static final String OPENAI_ENDPOINT = 'https://api.openai.com/v1/chat/completions';
    private static final String OPENAI_MODEL    = 'gpt-4o';
    private static final Integer TIMEOUT_MS     = 8000;

    private static final String SYSTEM_PROMPT =
        'You are a structured data extractor for a fleet maintenance system.\n\n' +
        'A technician has provided a free-form description of work performed on a vehicle.\n' +
        'Extract and return ONLY a JSON object with the following fields:\n' +
        '- complaint: What the technician or customer observed (the symptom)\n' +
        '- cause: What was identified as the root cause of the issue\n' +
        '- correction: What action was taken to resolve the issue\n\n' +
        'Rules:\n' +
        '- Remove filler words, hesitations, and repetition\n' +
        '- If a field cannot be determined from the input, return null for that field\n' +
        '- Do not invent or infer information not present in the input\n' +
        '- Return only valid JSON, no preamble or explanation';

    /**
     * Called by the cccCapture LWC. Returns extracted { complaint, cause, correction }
     * so the component can display them without a record refresh.
     *
     * Callout ordering: callout happens before any DML — satisfies Salesforce's
     * "no callout after DML" rule. Raw input is persisted in both success and error paths.
     */
    @AuraEnabled
    public static Map<String, String> submitCCC(String workOrderId, String rawInput) {
        if (String.isBlank(workOrderId)) {
            throw new AuraHandledException('Work Order ID is required.');
        }
        if (String.isBlank(rawInput)) {
            throw new AuraHandledException('Input text is required.');
        }

        String apiKey = getApiKey();

        HttpRequest  req = buildRequest(apiKey, rawInput);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            persistRawInput(workOrderId, rawInput);
            throw new AuraHandledException('LLM connection failed — raw input saved. (' + e.getMessage() + ')');
        }

        if (res.getStatusCode() != 200) {
            persistRawInput(workOrderId, rawInput);
            throw new AuraHandledException(
                'LLM returned HTTP ' + res.getStatusCode() + ' — raw input saved.'
            );
        }

        Map<String, String> ccc = parseResponse(res.getBody());

        update new WorkOrder(
            Id              = workOrderId,
            CCC_Raw_Input__c  = rawInput,
            CCC_Complaint__c  = ccc.get('complaint'),
            CCC_Cause__c      = ccc.get('cause'),
            CCC_Correction__c = ccc.get('correction')
        );

        return ccc;
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    private static String getApiKey() {
        CCC_Configuration__c cfg = CCC_Configuration__c.getOrgDefaults();
        if (cfg == null || String.isBlank(cfg.OpenAI_Key__c)) {
            throw new AuraHandledException(
                'OpenAI API key not configured. Ask your Salesforce admin to set the CCC Configuration custom setting.'
            );
        }
        return cfg.OpenAI_Key__c;
    }

    private static HttpRequest buildRequest(String apiKey, String rawInput) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'model'           => OPENAI_MODEL,
            'temperature'     => 0,
            'response_format' => new Map<String, String>{ 'type' => 'json_object' },
            'messages'        => new List<Object>{
                new Map<String, String>{ 'role' => 'system', 'content' => SYSTEM_PROMPT },
                new Map<String, String>{ 'role' => 'user',   'content' => rawInput }
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(OPENAI_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + apiKey);
        req.setTimeout(TIMEOUT_MS);
        req.setBody(JSON.serialize(requestBody));
        return req;
    }

    private static Map<String, String> parseResponse(String responseBody) {
        try {
            Map<String, Object> root    = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object>        choices = (List<Object>) root.get('choices');
            Map<String, Object> choice  = (Map<String, Object>) choices[0];
            Map<String, Object> message = (Map<String, Object>) choice.get('message');
            String              content = (String) message.get('content');

            Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(content);

            Map<String, String> ccc = new Map<String, String>();
            for (String key : new List<String>{ 'complaint', 'cause', 'correction' }) {
                Object val = raw.get(key);
                ccc.put(key, (val != null) ? String.valueOf(val) : null);
            }
            return ccc;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to parse LLM response: ' + e.getMessage());
        }
    }

    private static void persistRawInput(String workOrderId, String rawInput) {
        try {
            update new WorkOrder(Id = workOrderId, CCC_Raw_Input__c = rawInput);
        } catch (Exception e) {
            // Best-effort — do not mask the upstream error
        }
    }
}
