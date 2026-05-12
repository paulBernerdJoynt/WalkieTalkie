public with sharing class CCCController {

    private class ParseResult {
        String  inputQuality;
        String  complaint;
        Decimal complaintConfidence;
        String  complaintSource;
        String  complaintNote;
        String  cause;
        Decimal causeConfidence;
        String  causeSource;
        String  causeNote;
        String  correction;
        Decimal correctionConfidence;
        String  correctionSource;
        String  correctionNote;
        String  rawResponse;
        Boolean parseError       = false;
        String  parseErrorReason;
    }

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

        // ── SOQL only — no DML before callouts ────────────────────────────────
        String systemPrompt    = getActivePrompt();
        String activeTemplateId = getActiveTemplateId();

        WorkOrder wo = new WorkOrder(
            Id                    = workOrderId,
            CCC_Raw_Transcript__c = transcript
        );
        Map<String, String> result = new Map<String, String>{ 'path' => path };

        // Build attempt record in memory; insert after all callouts
        CCC_LLM_Attempt__c attempt = new CCC_LLM_Attempt__c(
            Work_Order__c              = workOrderId,
            Raw_Input__c               = transcript,
            Prompt_Template_Version__c = activeTemplateId,
            OpenAI_CCC_Status__c       = 'Not Attempted'
        );

        // ── HTTP callout (OpenAI) ─────────────────────────────────────────────
        if (path == 'openai' || path == 'both') {
            String apiKey    = getApiKey();
            String promptLog = '[SYSTEM PROMPT]\n' + systemPrompt + '\n\n[USER INPUT]\n' + transcript;
            HttpRequest  req = buildChatRequest(apiKey, systemPrompt, transcript);
            HttpResponse res;
            try {
                res = new Http().send(req);
            } catch (CalloutException e) {
                // Callout was attempted — DML is now safe
                attempt.SpeechToText_Status__c    = 'Success';
                attempt.OpenAI_CCC_Status__c      = 'Failure';
                attempt.OpenAI_Failure_Reason__c  = truncate('Network: ' + e.getMessage(), 255);
                insert attempt;
                throw new AuraHandledException('OpenAI connection failed. Attempt: ' + attempt.Id + ' (' + e.getMessage() + ')');
            }
            if (res.getStatusCode() != 200) {
                attempt.SpeechToText_Status__c   = 'Success';
                attempt.OpenAI_CCC_Status__c     = 'Failure';
                attempt.OpenAI_Failure_Reason__c = 'HTTP ' + res.getStatusCode();
                insert attempt;
                throw new AuraHandledException('OpenAI returned HTTP ' + res.getStatusCode() + '. Attempt: ' + attempt.Id);
            }
            ParseResult parsed = parseResponse(res.getBody());
            wo.CCC_Prompt_Log__c   = promptLog;
            wo.CCC_Response_Log__c = res.getBody();
            wo.CCC_Complaint__c    = parsed.complaint;
            wo.CCC_Cause__c        = parsed.cause;
            wo.CCC_Correction__c   = parsed.correction;
            result.put('openai_complaint',  parsed.complaint);
            result.put('openai_cause',      parsed.cause);
            result.put('openai_correction', parsed.correction);
            attempt.SpeechToText_Status__c = 'Success';
            attempt.CCC_Raw_Response__c    = parsed.rawResponse;
            if (parsed.parseError) {
                attempt.OpenAI_CCC_Status__c    = 'Failure';
                attempt.OpenAI_Failure_Reason__c = parsed.parseErrorReason;
            } else {
                attempt.OpenAI_CCC_Status__c         = 'Success';
                attempt.Complaint__c                  = parsed.complaint;
                attempt.Cause__c                      = parsed.cause;
                attempt.Correction__c                 = parsed.correction;
                attempt.CCC_Input_Quality__c          = parsed.inputQuality;
                attempt.CCC_Complaint_Confidence__c   = parsed.complaintConfidence;
                attempt.CCC_Complaint_Source__c       = parsed.complaintSource;
                attempt.CCC_Complaint_Note__c         = parsed.complaintNote;
                attempt.CCC_Cause_Confidence__c       = parsed.causeConfidence;
                attempt.CCC_Cause_Source__c           = parsed.causeSource;
                attempt.CCC_Cause_Note__c             = parsed.causeNote;
                attempt.CCC_Correction_Confidence__c  = parsed.correctionConfidence;
                attempt.CCC_Correction_Source__c      = parsed.correctionSource;
                attempt.CCC_Correction_Note__c        = parsed.correctionNote;
            }
        }

        // ── Invocable.Action (Agentforce / Einstein LLM Gateway) ─────────────
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
                if (path == 'agentforce') throw new AuraHandledException(e.getMessage());
                result.put('af_error', e.getMessage());
            }
        }

        // ── DML: all at once after all callouts ───────────────────────────────
        insert attempt;
        update wo;
        return result;
    }

    // ── v1.0 text path ───────────────────────────────────────────────────────

    @AuraEnabled
    public static Map<String, String> submitCCC(String workOrderId, String rawInput) {
        if (String.isBlank(workOrderId)) throw new AuraHandledException('Work Order ID is required.');
        if (String.isBlank(rawInput))    throw new AuraHandledException('Input text is required.');

        // ── SOQL only — no DML before callout ─────────────────────────────────
        String apiKey       = getApiKey();
        String systemPrompt = getActivePrompt();
        String activeTemplateId = getActiveTemplateId();
        String promptLog    = '[SYSTEM PROMPT]\n' + systemPrompt + '\n\n[USER INPUT]\n' + rawInput;

        CCC_LLM_Attempt__c attempt = new CCC_LLM_Attempt__c(
            Work_Order__c              = workOrderId,
            Raw_Input__c               = rawInput,
            Prompt_Template_Version__c = activeTemplateId,
            OpenAI_CCC_Status__c       = 'Not Attempted'
        );

        // ── HTTP callout ───────────────────────────────────────────────────────
        HttpRequest  req = buildChatRequest(apiKey, systemPrompt, rawInput);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            attempt.SpeechToText_Status__c   = 'Success';
            attempt.OpenAI_CCC_Status__c     = 'Failure';
            attempt.OpenAI_Failure_Reason__c = truncate('Network: ' + e.getMessage(), 255);
            insert attempt;
            persistRawInput(workOrderId, rawInput, promptLog, null, null);
            throw new AuraHandledException('LLM connection failed — raw input saved. (' + e.getMessage() + ')');
        }

        if (res.getStatusCode() != 200) {
            attempt.SpeechToText_Status__c   = 'Success';
            attempt.OpenAI_CCC_Status__c     = 'Failure';
            attempt.OpenAI_Failure_Reason__c = 'HTTP ' + res.getStatusCode();
            insert attempt;
            persistRawInput(workOrderId, rawInput, promptLog, res.getBody(), null);
            throw new AuraHandledException('LLM returned HTTP ' + res.getStatusCode() + ' — raw input saved. Attempt: ' + attempt.Id);
        }

        ParseResult parsed = parseResponse(res.getBody());

        // ── DML: all at once after callout ─────────────────────────────────────
        attempt.SpeechToText_Status__c  = 'Success';
        attempt.CCC_Raw_Response__c     = parsed.rawResponse;
        if (parsed.parseError) {
            attempt.OpenAI_CCC_Status__c    = 'Failure';
            attempt.OpenAI_Failure_Reason__c = parsed.parseErrorReason;
        } else {
            attempt.OpenAI_CCC_Status__c         = 'Success';
            attempt.Complaint__c                  = parsed.complaint;
            attempt.Cause__c                      = parsed.cause;
            attempt.Correction__c                 = parsed.correction;
            attempt.CCC_Input_Quality__c          = parsed.inputQuality;
            attempt.CCC_Complaint_Confidence__c   = parsed.complaintConfidence;
            attempt.CCC_Complaint_Source__c       = parsed.complaintSource;
            attempt.CCC_Complaint_Note__c         = parsed.complaintNote;
            attempt.CCC_Cause_Confidence__c       = parsed.causeConfidence;
            attempt.CCC_Cause_Source__c           = parsed.causeSource;
            attempt.CCC_Cause_Note__c             = parsed.causeNote;
            attempt.CCC_Correction_Confidence__c  = parsed.correctionConfidence;
            attempt.CCC_Correction_Source__c      = parsed.correctionSource;
            attempt.CCC_Correction_Note__c        = parsed.correctionNote;
        }
        insert attempt;

        update new WorkOrder(
            Id                  = workOrderId,
            CCC_Raw_Input__c    = rawInput,
            CCC_Prompt_Log__c   = promptLog,
            CCC_Response_Log__c = res.getBody(),
            CCC_Complaint__c    = parsed.complaint,
            CCC_Cause__c        = parsed.cause,
            CCC_Correction__c   = parsed.correction
        );

        return new Map<String, String>{
            'complaint'  => parsed.complaint,
            'cause'      => parsed.cause,
            'correction' => parsed.correction
        };
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

        // ── SOQL only — no DML before callout ─────────────────────────────────
        String apiKey       = getApiKey();
        String systemPrompt = getActivePrompt();
        String activeTemplateId = getActiveTemplateId();
        String promptLog    = '[SYSTEM PROMPT]\n' + systemPrompt + '\n\n[USER INPUT]\n' + transcript;

        CCC_LLM_Attempt__c attempt = new CCC_LLM_Attempt__c(
            Work_Order__c              = workOrderId,
            Raw_Input__c               = transcript,
            Prompt_Template_Version__c = activeTemplateId,
            SpeechToText_Status__c     = 'Success',
            OpenAI_CCC_Status__c       = 'Not Attempted'
        );

        // ── HTTP callout ───────────────────────────────────────────────────────
        HttpRequest  req = buildChatRequest(apiKey, systemPrompt, transcript);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            attempt.OpenAI_CCC_Status__c     = 'Failure';
            attempt.OpenAI_Failure_Reason__c = truncate('Network: ' + e.getMessage(), 255);
            insert attempt;
            persistTranscript(workOrderId, transcript);
            throw new AuraHandledException('LLM connection failed — transcript saved. Attempt: ' + attempt.Id + ' (' + e.getMessage() + ')');
        }

        if (res.getStatusCode() != 200) {
            attempt.OpenAI_CCC_Status__c     = 'Failure';
            attempt.OpenAI_Failure_Reason__c = 'HTTP ' + res.getStatusCode();
            insert attempt;
            persistTranscript(workOrderId, transcript);
            throw new AuraHandledException('LLM returned HTTP ' + res.getStatusCode() + ' — transcript saved. Attempt: ' + attempt.Id);
        }

        ParseResult parsed = parseResponse(res.getBody());

        // ── DML: all at once after callout ─────────────────────────────────────
        attempt.CCC_Raw_Response__c = parsed.rawResponse;
        if (parsed.parseError) {
            attempt.OpenAI_CCC_Status__c    = 'Failure';
            attempt.OpenAI_Failure_Reason__c = parsed.parseErrorReason;
        } else {
            attempt.OpenAI_CCC_Status__c         = 'Success';
            attempt.Complaint__c                  = parsed.complaint;
            attempt.Cause__c                      = parsed.cause;
            attempt.Correction__c                 = parsed.correction;
            attempt.CCC_Input_Quality__c          = parsed.inputQuality;
            attempt.CCC_Complaint_Confidence__c   = parsed.complaintConfidence;
            attempt.CCC_Complaint_Source__c       = parsed.complaintSource;
            attempt.CCC_Complaint_Note__c         = parsed.complaintNote;
            attempt.CCC_Cause_Confidence__c       = parsed.causeConfidence;
            attempt.CCC_Cause_Source__c           = parsed.causeSource;
            attempt.CCC_Cause_Note__c             = parsed.causeNote;
            attempt.CCC_Correction_Confidence__c  = parsed.correctionConfidence;
            attempt.CCC_Correction_Source__c      = parsed.correctionSource;
            attempt.CCC_Correction_Note__c        = parsed.correctionNote;
        }
        insert attempt;

        update new WorkOrder(
            Id                  = workOrderId,
            CCC_Raw_Input__c    = transcript,
            CCC_Transcript__c   = transcript,
            CCC_Prompt_Log__c   = promptLog,
            CCC_Response_Log__c = res.getBody(),
            CCC_Complaint__c    = parsed.complaint,
            CCC_Cause__c        = parsed.cause,
            CCC_Correction__c   = parsed.correction
        );

        return new Map<String, String>{
            'complaint'  => parsed.complaint,
            'cause'      => parsed.cause,
            'correction' => parsed.correction
        };
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    private static String getActiveTemplateId() {
        try {
            List<CCC_Prompt_Template__c> t = [
                SELECT Id FROM CCC_Prompt_Template__c WHERE Is_Active__c = true LIMIT 1
            ];
            return t.isEmpty() ? null : t[0].Id;
        } catch (Exception e) { return null; }
    }

    private static String truncate(String s, Integer maxLen) {
        return (s != null && s.length() > maxLen) ? s.left(maxLen) : s;
    }

    /**
     * Get the active CCC_Prompt_Template__c prompt text. Falls back to hardcoded constant.
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

    private static ParseResult parseResponse(String responseBody) {
        ParseResult result = new ParseResult();
        result.rawResponse = responseBody;
        try {
            Map<String, Object> root    = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object>        choices = (List<Object>) root.get('choices');
            Map<String, Object> choice  = (Map<String, Object>) choices[0];
            Map<String, Object> message = (Map<String, Object>) choice.get('message');
            String              content = (String) message.get('content');

            Map<String, Object> parsed;
            try {
                parsed = (Map<String, Object>) JSON.deserializeUntyped(content);
            } catch (Exception parseEx) {
                result.parseError       = true;
                result.parseErrorReason = 'Malformed JSON response';
                result.inputQuality     = 'insufficient';
                return result;
            }

            result.inputQuality         = validateInputQuality((String) parsed.get('input_quality'));
            result.complaint            = extractFieldValue(parsed, 'complaint');
            result.complaintConfidence  = extractConfidence(parsed, 'complaint');
            result.complaintSource      = extractSubkey(parsed, 'complaint', 'source');
            result.complaintNote        = extractSubkey(parsed, 'complaint', 'note');
            result.cause                = extractFieldValue(parsed, 'cause');
            result.causeConfidence      = extractConfidence(parsed, 'cause');
            result.causeSource          = extractSubkey(parsed, 'cause', 'source');
            result.causeNote            = extractSubkey(parsed, 'cause', 'note');
            result.correction           = extractFieldValue(parsed, 'correction');
            result.correctionConfidence = extractConfidence(parsed, 'correction');
            result.correctionSource     = extractSubkey(parsed, 'correction', 'source');
            result.correctionNote       = extractSubkey(parsed, 'correction', 'note');
        } catch (Exception e) {
            result.parseError       = true;
            result.parseErrorReason = 'Malformed JSON response';
            result.inputQuality     = 'insufficient';
        }
        return result;
    }

    private static String extractFieldValue(Map<String, Object> parsed, String key) {
        Object val = parsed.get(key);
        if (val == null)           return null;
        if (val instanceof String) return (String) val;
        Object v = ((Map<String, Object>) val).get('value');
        return v != null ? String.valueOf(v) : null;
    }

    private static Decimal extractConfidence(Map<String, Object> parsed, String key) {
        Object val = parsed.get(key);
        if (val == null || val instanceof String) return null;
        Object c = ((Map<String, Object>) val).get('confidence');
        if (c == null) return null;
        Decimal conf = (Decimal) c;
        if (conf < 0) conf = 0;
        if (conf > 1) conf = 1;
        return conf;
    }

    private static String extractSubkey(Map<String, Object> parsed, String fieldKey, String subkey) {
        Object val = parsed.get(fieldKey);
        if (val == null || val instanceof String) return null;
        Object s = ((Map<String, Object>) val).get(subkey);
        return s != null ? String.valueOf(s) : null;
    }

    private static String validateInputQuality(String iq) {
        if (iq == 'clear' || iq == 'fragmented' || iq == 'insufficient') return iq;
        return 'fragmented';
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
