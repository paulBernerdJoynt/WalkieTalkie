public with sharing class CCCController {

    private static final String OPENAI_ENDPOINT       = 'https://api.openai.com/v1/chat/completions';
    private static final String WHISPER_ENDPOINT      = 'https://api.openai.com/v1/audio/transcriptions';
    private static final String OPENAI_MODEL          = 'gpt-4o';
    private static final String WHISPER_MODEL         = 'whisper-1';
    private static final String AGENTFORCE_TEMPLATE   = 'CCC_Extractor';
    private static final Integer TIMEOUT_MS           = 30000;

    // v1.3: System prompt is now fetched from CCC_Prompt_Template__c (active version)
    // This constant is kept for backward compatibility during transition
    private static final String SYSTEM_PROMPT_FALLBACK =
        'You are a structured data extractor for a fleet maintenance diagnostic system.\n\n' +
        'A technician has provided a narrative description of work performed on a vehicle.\n' +
        'Extract and return ONLY a JSON object with the following fields:\n' +
        '- complaint: What the technician or customer observed (the symptom or presenting issue)\n' +
        '- cause: The identified root cause of the problem\n' +
        '- correction: The action taken to resolve the issue\n\n' +
        'Requirements:\n' +
        '- Write each field as complete, professional sentences (typically 2-3+ sentences)\n' +
        '- Include specific technical detail: part names, measurements, symptoms observed, diagnostic steps taken, actions performed, and confirmation of resolution where mentioned\n' +
        '- Capture the full diagnostic narrative; do not abbreviate to single phrases or summaries\n' +
        '- If a field cannot be determined from the input, return null for that field\n' +
        '- Do not invent or infer information not present in the technician\'s description\n' +
        '- Return only valid JSON, no preamble or explanation';

    // ── v1.2 unified voice path ───────────────────────────────────────────────

    /**
     * Primary method for the v1.2 LWC. Called after the user reviews the Whisper
     * transcript and taps one of the three LLM buttons.
     *
     * path: 'openai' | 'agentforce' | 'both'
     *
     * Returns a flat map with provider-prefixed keys so the LWC can render
     * side-by-side results without a second round-trip.
     *
     * For 'both': if Agentforce fails (e.g. template not yet configured), the
     * OpenAI result is still written and 'af_error' is returned in the map.
     */
    @AuraEnabled
    public static Map<String, String> extractCCC(String workOrderId, String transcript, String path) {
        if (String.isBlank(workOrderId)) throw new AuraHandledException('Work Order ID is required.');
        if (String.isBlank(transcript))  throw new AuraHandledException('Transcript is required.');
        if (String.isBlank(path))        throw new AuraHandledException('Path is required.');

        WorkOrder wo = new WorkOrder(
            Id                    = workOrderId,
            CCC_Raw_Transcript__c = transcript
        );

        Map<String, String> result = new Map<String, String>{ 'path' => path };

        String systemPrompt = getActivePrompt();

        // Get active prompt template for reference
        CCC_Prompt_Template__c activeTemplate = null;
        try {
            List<CCC_Prompt_Template__c> templates = [
                SELECT Id FROM CCC_Prompt_Template__c
                WHERE Is_Active__c = true
                LIMIT 1
            ];
            if (!templates.isEmpty()) {
                activeTemplate = templates[0];
            }
        } catch (Exception e) { }

        // Create attempt record
        String attemptId = createAttemptRecord(workOrderId, transcript,
                                              (activeTemplate != null) ? activeTemplate.Id : null);

        // HTTP callouts must happen before any DML
        if (path == 'openai' || path == 'both') {
            String apiKey = getApiKey();
            String promptLog = '[SYSTEM PROMPT]\n' + systemPrompt + '\n\n[USER INPUT]\n' + transcript;
            HttpRequest  req = buildChatRequest(apiKey, systemPrompt, transcript);
            HttpResponse res;
            try {
                res = new Http().send(req);
            } catch (CalloutException e) {
                updateAttemptWithSTTResult(attemptId, 'Success', null);
                updateAttemptWithLLMResult(attemptId, 'Failure', 'Network unavailable: ' + e.getMessage(), null, null, null);
                throw new AuraHandledException('OpenAI connection failed. Attempt: ' + attemptId + ' (' + e.getMessage() + ')');
            }
            if (res.getStatusCode() != 200) {
                updateAttemptWithSTTResult(attemptId, 'Success', null);
                updateAttemptWithLLMResult(attemptId, 'Failure', 'HTTP ' + res.getStatusCode(), null, null, null);
                throw new AuraHandledException('OpenAI returned HTTP ' + res.getStatusCode() + '. Attempt: ' + attemptId);
            }
            Map<String, String> oai = parseResponse(res.getBody());
            wo.CCC_Prompt_Log__c   = promptLog;
            wo.CCC_Response_Log__c = res.getBody();
            wo.CCC_Complaint__c    = oai.get('complaint');
            wo.CCC_Cause__c        = oai.get('cause');
            wo.CCC_Correction__c   = oai.get('correction');
            result.put('openai_complaint',  oai.get('complaint'));
            result.put('openai_cause',      oai.get('cause'));
            result.put('openai_correction', oai.get('correction'));

            // Log LLM success
            updateAttemptWithSTTResult(attemptId, 'Success', null);
            updateAttemptWithLLMResult(attemptId, 'Success', null, oai.get('complaint'), oai.get('cause'), oai.get('correction'));
        }

        // Invocable.Action (Einstein LLM Gateway — not a counted HTTP callout)
        if (path == 'agentforce' || path == 'both') {
            try {
                Map<String, String> af = callAgentforce(transcript);
                wo.AF_Complaint__c  = af.get('complaint');
                wo.AF_Cause__c      = af.get('cause');
                wo.AF_Correction__c = af.get('correction');
                result.put('af_complaint',  af.get('complaint'));
                result.put('af_cause',      af.get('cause'));
                result.put('af_correction', af.get('correction'));
            } catch (Exception e) {
                if (path == 'agentforce') {
                    throw new AuraHandledException(e.getMessage());
                }
                // 'both' path: record the error but still save OpenAI results
                result.put('af_error', e.getMessage());
            }
        }

        update wo;
        return result;
    }

    // ── v1.0 text path ───────────────────────────────────────────────────────

    @AuraEnabled
    public static Map<String, String> submitCCC(String workOrderId, String rawInput) {
        if (String.isBlank(workOrderId)) throw new AuraHandledException('Work Order ID is required.');
        if (String.isBlank(rawInput))    throw new AuraHandledException('Input text is required.');

        String apiKey    = getApiKey();
        String systemPrompt = getActivePrompt();

        // Get active prompt template for reference
        CCC_Prompt_Template__c activeTemplate = null;
        try {
            List<CCC_Prompt_Template__c> templates = [
                SELECT Id FROM CCC_Prompt_Template__c
                WHERE Is_Active__c = true
                LIMIT 1
            ];
            if (!templates.isEmpty()) {
                activeTemplate = templates[0];
            }
        } catch (Exception e) { }

        // Create attempt record to log this extraction
        String attemptId = createAttemptRecord(workOrderId, rawInput,
                                              (activeTemplate != null) ? activeTemplate.Id : null);

        String promptLog = '[SYSTEM PROMPT]\n' + systemPrompt + '\n\n[USER INPUT]\n' + rawInput;

        HttpRequest  req = buildChatRequest(apiKey, systemPrompt, rawInput);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            // Log STT as success (it's text input), LLM as failed
            updateAttemptWithSTTResult(attemptId, 'Success', null);
            updateAttemptWithLLMResult(attemptId, 'Failure', 'Network unavailable: ' + e.getMessage(), null, null, null);
            persistRawInput(workOrderId, rawInput, promptLog, null, null);
            throw new AuraHandledException('LLM connection failed — raw input saved. (' + e.getMessage() + ')');
        }

        if (res.getStatusCode() != 200) {
            // Log STT as success, LLM as failed
            updateAttemptWithSTTResult(attemptId, 'Success', null);
            updateAttemptWithLLMResult(attemptId, 'Failure', 'HTTP ' + res.getStatusCode(), null, null, null);
            persistRawInput(workOrderId, rawInput, promptLog, res.getBody(), null);
            throw new AuraHandledException('LLM returned HTTP ' + res.getStatusCode() + ' — raw input saved. Attempt: ' + attemptId);
        }

        Map<String, String> ccc = parseResponse(res.getBody());

        // Log LLM success
        updateAttemptWithSTTResult(attemptId, 'Success', null);
        updateAttemptWithLLMResult(attemptId, 'Success', null, ccc.get('complaint'), ccc.get('cause'), ccc.get('correction'));

        update new WorkOrder(
            Id                  = workOrderId,
            CCC_Raw_Input__c    = rawInput,
            CCC_Prompt_Log__c   = promptLog,
            CCC_Response_Log__c = res.getBody(),
            CCC_Complaint__c    = ccc.get('complaint'),
            CCC_Cause__c        = ccc.get('cause'),
            CCC_Correction__c   = ccc.get('correction')
        );

        return ccc;
    }

    // ── v1.1 voice path ──────────────────────────────────────────────────────

    /**
     * Step 1 of the voice path: transcribe audio only.
     * LWC passes base64-encoded audio; returns the transcript string.
     * No DML — caller decides whether to proceed to extraction.
     */
    @AuraEnabled
    public static String transcribeAudio(String workOrderId, String base64Audio, String mimeType) {
        if (String.isBlank(workOrderId)) throw new AuraHandledException('Work Order ID is required.');
        if (String.isBlank(base64Audio)) throw new AuraHandledException('Audio data is required.');

        String apiKey = getApiKey();
        Blob   audio  = EncodingUtil.base64Decode(base64Audio);

        HttpRequest  req = buildWhisperRequest(apiKey, audio, mimeType);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            throw new AuraHandledException('Transcription connection failed. (' + e.getMessage() + ')');
        }

        if (res.getStatusCode() != 200) {
            throw new AuraHandledException('Whisper returned HTTP ' + res.getStatusCode());
        }

        return parseTranscript(res.getBody());
    }

    /**
     * Step 2 of the voice path (review mode): extract CCC from a transcript
     * that the technician has already reviewed.
     * Also used as the single call for the fast (no-review) voice path.
     */
    @AuraEnabled
    public static Map<String, String> extractCCCFromTranscript(String workOrderId, String transcript) {
        if (String.isBlank(workOrderId)) throw new AuraHandledException('Work Order ID is required.');
        if (String.isBlank(transcript))  throw new AuraHandledException('Transcript is required.');

        String apiKey    = getApiKey();
        String systemPrompt = getActivePrompt();

        // Get active prompt template for reference
        CCC_Prompt_Template__c activeTemplate = null;
        try {
            List<CCC_Prompt_Template__c> templates = [
                SELECT Id FROM CCC_Prompt_Template__c
                WHERE Is_Active__c = true
                LIMIT 1
            ];
            if (!templates.isEmpty()) {
                activeTemplate = templates[0];
            }
        } catch (Exception e) { }

        // Create attempt record
        String attemptId = createAttemptRecord(workOrderId, transcript,
                                              (activeTemplate != null) ? activeTemplate.Id : null);

        String promptLog = '[SYSTEM PROMPT]\n' + systemPrompt + '\n\n[USER INPUT]\n' + transcript;

        HttpRequest  req = buildChatRequest(apiKey, systemPrompt, transcript);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            // Transcript came from STT (success), but LLM call failed
            updateAttemptWithSTTResult(attemptId, 'Success', null);
            updateAttemptWithLLMResult(attemptId, 'Failure', 'Network unavailable: ' + e.getMessage(), null, null, null);
            persistTranscript(workOrderId, transcript);
            throw new AuraHandledException('LLM connection failed — transcript saved. Attempt: ' + attemptId + ' (' + e.getMessage() + ')');
        }

        if (res.getStatusCode() != 200) {
            updateAttemptWithSTTResult(attemptId, 'Success', null);
            updateAttemptWithLLMResult(attemptId, 'Failure', 'HTTP ' + res.getStatusCode(), null, null, null);
            persistTranscript(workOrderId, transcript);
            throw new AuraHandledException('LLM returned HTTP ' + res.getStatusCode() + ' — transcript saved. Attempt: ' + attemptId);
        }

        Map<String, String> ccc = parseResponse(res.getBody());

        // Log success
        updateAttemptWithSTTResult(attemptId, 'Success', null);
        updateAttemptWithLLMResult(attemptId, 'Success', null, ccc.get('complaint'), ccc.get('cause'), ccc.get('correction'));

        update new WorkOrder(
            Id                  = workOrderId,
            CCC_Raw_Input__c    = transcript,
            CCC_Transcript__c   = transcript,
            CCC_Prompt_Log__c   = promptLog,
            CCC_Response_Log__c = res.getBody(),
            CCC_Complaint__c    = ccc.get('complaint'),
            CCC_Cause__c        = ccc.get('cause'),
            CCC_Correction__c   = ccc.get('correction')
        );

        return ccc;
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    /**
     * Get the active CCC_Prompt_Template__c. If none active, return the fallback.
     */
    private static String getActivePrompt() {
        try {
            List<CCC_Prompt_Template__c> templates = [
                SELECT Prompt_Text__c
                FROM CCC_Prompt_Template__c
                WHERE Is_Active__c = true
                LIMIT 1
            ];
            if (!templates.isEmpty()) {
                return templates[0].Prompt_Text__c;
            }
        } catch (Exception e) {
            // Query failed; fall through to fallback
        }
        return SYSTEM_PROMPT_FALLBACK;
    }

    /**
     * Get the STT prompt from Custom Metadata. If not found, return empty string (Whisper is self-prompting).
     */
    private static String getSTTPrompt() {
        try {
            List<CCC_STT_Prompt__mdt> records = [
                SELECT Prompt_Text__c
                FROM CCC_STT_Prompt__mdt
                WHERE DeveloperName = 'Default'
                LIMIT 1
            ];
            if (!records.isEmpty() && String.isNotBlank(records[0].Prompt_Text__c)) {
                return records[0].Prompt_Text__c;
            }
        } catch (Exception e) {
            // Query failed; fall through
        }
        return '';
    }

    /**
     * Create a CCC_LLM_Attempt record with raw input and initial status.
     * Returns the record ID for later updates.
     */
    private static String createAttemptRecord(String workOrderId, String rawInput, String promptTemplateId) {
        try {
            CCC_LLM_Attempt__c attempt = new CCC_LLM_Attempt__c(
                Work_Order__c = workOrderId,
                Raw_Input__c = rawInput,
                Prompt_Template_Version__c = promptTemplateId,
                SpeechToText_Status__c = null,
                OpenAI_CCC_Status__c = 'Not Attempted'
            );
            insert attempt;
            return attempt.Id;
        } catch (Exception e) {
            // If we can't create the record, log the error but don't throw
            System.debug('Error creating CCC_LLM_Attempt: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Update the attempt record with STT result.
     */
    private static void updateAttemptWithSTTResult(String attemptId, String status, String failureReason) {
        if (String.isBlank(attemptId)) return;
        try {
            update new CCC_LLM_Attempt__c(
                Id = attemptId,
                SpeechToText_Status__c = status,
                SpeechToText_Failure_Reason__c = failureReason
            );
        } catch (Exception e) {
            System.debug('Error updating STT result: ' + e.getMessage());
        }
    }

    /**
     * Update the attempt record with LLM result.
     */
    private static void updateAttemptWithLLMResult(String attemptId, String status, String failureReason,
                                                    String complaint, String cause, String correction) {
        if (String.isBlank(attemptId)) return;
        try {
            update new CCC_LLM_Attempt__c(
                Id = attemptId,
                OpenAI_CCC_Status__c = status,
                OpenAI_Failure_Reason__c = failureReason,
                Complaint__c = complaint,
                Cause__c = cause,
                Correction__c = correction
            );
        } catch (Exception e) {
            System.debug('Error updating LLM result: ' + e.getMessage());
        }
    }

    private static String getApiKey() {
        CCC_Configuration__c cfg = CCC_Configuration__c.getOrgDefaults();
        if (cfg == null || String.isBlank(cfg.OpenAI_Key__c)) {
            throw new AuraHandledException(
                'OpenAI API key not configured. Ask your Salesforce admin to set the CCC Configuration custom setting.'
            );
        }
        return cfg.OpenAI_Key__c;
    }

    private static HttpRequest buildChatRequest(String apiKey, String systemPrompt, String userText) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'model'           => OPENAI_MODEL,
            'temperature'     => 0,
            'response_format' => new Map<String, String>{ 'type' => 'json_object' },
            'messages'        => new List<Object>{
                new Map<String, String>{ 'role' => 'system', 'content' => systemPrompt },
                new Map<String, String>{ 'role' => 'user',   'content' => userText }
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

    private static HttpRequest buildWhisperRequest(String apiKey, Blob audio, String mimeType) {
        String boundary = '----CCC' + String.valueOf(Datetime.now().getTime());
        String filename = 'audio.' + extensionForMime(mimeType);

        // Multipart body: preamble + binary audio + model field + close
        String preamble =
            '--' + boundary + '\r\n' +
            'Content-Disposition: form-data; name="file"; filename="' + filename + '"\r\n' +
            'Content-Type: ' + mimeType + '\r\n\r\n';
        String middle =
            '\r\n--' + boundary + '\r\n' +
            'Content-Disposition: form-data; name="model"\r\n\r\n' +
            WHISPER_MODEL +
            '\r\n--' + boundary + '--';

        Blob body = Blob.valueOf(preamble);
        body = BlobUtils.concat(body, audio);
        body = BlobUtils.concat(body, Blob.valueOf(middle));

        HttpRequest req = new HttpRequest();
        req.setEndpoint(WHISPER_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + apiKey);
        req.setHeader('Content-Type', 'multipart/form-data; boundary=' + boundary);
        req.setTimeout(TIMEOUT_MS);
        req.setBodyAsBlob(body);
        return req;
    }

    private static String extensionForMime(String mimeType) {
        if (String.isBlank(mimeType)) return 'mp4';
        if (mimeType.contains('webm')) return 'webm';
        if (mimeType.contains('ogg'))  return 'ogg';
        if (mimeType.contains('wav'))  return 'wav';
        if (mimeType.contains('mp3'))  return 'mp3';
        return 'mp4';
    }

    private static String parseTranscript(String responseBody) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            return (String) root.get('text');
        } catch (Exception e) {
            throw new AuraHandledException('Failed to parse Whisper response: ' + e.getMessage());
        }
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

    private static Map<String, String> callAgentforce(String transcript) {
        Invocable.Action action = Invocable.Action.createCustomAction(
            'promptTemplate',
            AGENTFORCE_TEMPLATE
        );
        action.setInvocationParameter('transcript', transcript);

        List<Invocable.Action.Result> results = action.invoke();

        if (results == null || results.isEmpty() || !results[0].isSuccess()) {
            String detail = (results != null && !results.isEmpty() && results[0].getErrors() != null)
                ? String.valueOf(results[0].getErrors())
                : 'No results returned';
            throw new AuraHandledException(
                'Agentforce Prompt Builder invocation failed: ' + detail +
                '. Ensure the CCC_Extractor template is configured in Setup → Prompt Builder.'
            );
        }

        String response = (String) results[0].getOutputParameters().get('value');
        return parseCCCResponse(response);
    }

    private static Map<String, String> parseCCCResponse(String response) {
        Map<String, String> ccc = new Map<String, String>{
            'complaint'  => null,
            'cause'      => null,
            'correction' => null
        };
        if (String.isBlank(response)) return ccc;
        for (String line : response.split('\n')) {
            line = line.trim();
            if (line.startsWithIgnoreCase('COMPLAINT:')) {
                String val = line.substringAfter(':').trim();
                ccc.put('complaint', val.equalsIgnoreCase('null') ? null : val);
            } else if (line.startsWithIgnoreCase('CAUSE:')) {
                String val = line.substringAfter(':').trim();
                ccc.put('cause', val.equalsIgnoreCase('null') ? null : val);
            } else if (line.startsWithIgnoreCase('CORRECTION:')) {
                String val = line.substringAfter(':').trim();
                ccc.put('correction', val.equalsIgnoreCase('null') ? null : val);
            }
        }
        return ccc;
    }

    private static void persistRawInput(String workOrderId, String rawInput, String promptLog, String responseLog, String transcript) {
        try {
            update new WorkOrder(
                Id                  = workOrderId,
                CCC_Raw_Input__c    = rawInput,
                CCC_Prompt_Log__c   = promptLog,
                CCC_Response_Log__c = responseLog,
                CCC_Transcript__c   = transcript
            );
        } catch (Exception e) { }
    }

    private static void persistTranscript(String workOrderId, String transcript) {
        try {
            update new WorkOrder(
                Id                = workOrderId,
                CCC_Transcript__c = transcript
            );
        } catch (Exception e) { }
    }
}
