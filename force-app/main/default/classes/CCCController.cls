public with sharing class CCCController {

    private static final String OPENAI_ENDPOINT  = 'https://api.openai.com/v1/chat/completions';
    private static final String WHISPER_ENDPOINT = 'https://api.openai.com/v1/audio/transcriptions';
    private static final String OPENAI_MODEL     = 'gpt-4o';
    private static final String WHISPER_MODEL    = 'whisper-1';
    private static final Integer TIMEOUT_MS      = 30000;

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

    // ── v1.0 text path ───────────────────────────────────────────────────────

    @AuraEnabled
    public static Map<String, String> submitCCC(String workOrderId, String rawInput) {
        if (String.isBlank(workOrderId)) throw new AuraHandledException('Work Order ID is required.');
        if (String.isBlank(rawInput))    throw new AuraHandledException('Input text is required.');

        String apiKey    = getApiKey();
        String promptLog = '[SYSTEM PROMPT]\n' + SYSTEM_PROMPT + '\n\n[USER INPUT]\n' + rawInput;

        HttpRequest  req = buildChatRequest(apiKey, rawInput);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            persistRawInput(workOrderId, rawInput, promptLog, null, null);
            throw new AuraHandledException('LLM connection failed — raw input saved. (' + e.getMessage() + ')');
        }

        if (res.getStatusCode() != 200) {
            persistRawInput(workOrderId, rawInput, promptLog, res.getBody(), null);
            throw new AuraHandledException('LLM returned HTTP ' + res.getStatusCode() + ' — raw input saved.');
        }

        Map<String, String> ccc = parseResponse(res.getBody());

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
        String promptLog = '[SYSTEM PROMPT]\n' + SYSTEM_PROMPT + '\n\n[USER INPUT]\n' + transcript;

        HttpRequest  req = buildChatRequest(apiKey, transcript);
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (CalloutException e) {
            persistTranscript(workOrderId, transcript);
            throw new AuraHandledException('LLM connection failed — transcript saved. (' + e.getMessage() + ')');
        }

        if (res.getStatusCode() != 200) {
            persistTranscript(workOrderId, transcript);
            throw new AuraHandledException('LLM returned HTTP ' + res.getStatusCode() + ' — transcript saved.');
        }

        Map<String, String> ccc = parseResponse(res.getBody());

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

    private static String getApiKey() {
        CCC_Configuration__c cfg = CCC_Configuration__c.getOrgDefaults();
        if (cfg == null || String.isBlank(cfg.OpenAI_Key__c)) {
            throw new AuraHandledException(
                'OpenAI API key not configured. Ask your Salesforce admin to set the CCC Configuration custom setting.'
            );
        }
        return cfg.OpenAI_Key__c;
    }

    private static HttpRequest buildChatRequest(String apiKey, String userText) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'model'           => OPENAI_MODEL,
            'temperature'     => 0,
            'response_format' => new Map<String, String>{ 'type' => 'json_object' },
            'messages'        => new List<Object>{
                new Map<String, String>{ 'role' => 'system', 'content' => SYSTEM_PROMPT },
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
