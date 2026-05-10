@isTest
private class CCCControllerTest {

    @TestSetup
    static void setup() {
        insert new WorkOrder(Subject = 'CCC Test WO');

        CCC_Configuration__c cfg = new CCC_Configuration__c();
        cfg.SetupOwnerId  = UserInfo.getOrganizationId();
        cfg.OpenAI_Key__c = 'test-key-placeholder';
        insert cfg;
    }

    // ── v1.0 text path ────────────────────────────────────────────────────────

    @isTest
    static void testSubmitCCC_success() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CCCMock(200, buildChatSuccessBody()));

        Test.startTest();
        Map<String, String> result = CCCController.submitCCC(wo.Id, 'Truck leaking oil. Found cracked pan gasket. Replaced gasket.');
        Test.stopTest();

        System.assertEquals('Oil leak observed.',       result.get('complaint'));
        System.assertEquals('Cracked oil pan gasket.',  result.get('cause'));
        System.assertEquals('Replaced oil pan gasket.', result.get('correction'));

        WorkOrder updated = [SELECT CCC_Raw_Input__c, CCC_Complaint__c FROM WorkOrder WHERE Id = :wo.Id];
        System.assertNotEquals(null, updated.CCC_Raw_Input__c, 'Raw input should be persisted');
        System.assertNotEquals(null, updated.CCC_Complaint__c, 'Complaint should be persisted');
    }

    @isTest
    static void testSubmitCCC_partialExtraction() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        String bodyWithNulls = '{"choices":[{"message":{"role":"assistant","content":"{\\"complaint\\":\\"Brake noise\\",\\"cause\\":null,\\"correction\\":null}"}}]}';
        Test.setMock(HttpCalloutMock.class, new CCCMock(200, bodyWithNulls));

        Test.startTest();
        Map<String, String> result = CCCController.submitCCC(wo.Id, 'Heard a grinding noise when braking.');
        Test.stopTest();

        System.assertEquals('Brake noise', result.get('complaint'));
        System.assertEquals(null, result.get('cause'));
        System.assertEquals(null, result.get('correction'));
    }

    @isTest
    static void testSubmitCCC_blankInput_throws() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        try {
            CCCController.submitCCC(wo.Id, '   ');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('required'));
        }
    }

    @isTest
    static void testSubmitCCC_missingApiKey_throws() {
        delete [SELECT Id FROM CCC_Configuration__c];
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        try {
            CCCController.submitCCC(wo.Id, 'Some input');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('API key'));
        }
    }

    @isTest
    static void testSubmitCCC_llmError_rawInputPersisted() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CCCMock(500, '{"error":"server error"}'));

        Test.startTest();
        try {
            CCCController.submitCCC(wo.Id, 'Raw input that must be saved');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('HTTP 500'));
        }
        Test.stopTest();

        WorkOrder updated = [SELECT CCC_Raw_Input__c FROM WorkOrder WHERE Id = :wo.Id];
        System.assertEquals('Raw input that must be saved', updated.CCC_Raw_Input__c);
    }

    // ── v1.1 voice path: transcribeAudio ─────────────────────────────────────

    @isTest
    static void testTranscribeAudio_success() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        // Use a real small audio-like base64 payload (any bytes — mock ignores them)
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake audio bytes'));
        Test.setMock(HttpCalloutMock.class, new CCCMock(200, '{"text":"Vibration in the front end."}'));

        Test.startTest();
        String transcript = CCCController.transcribeAudio(wo.Id, fakeBase64, 'audio/mp4');
        Test.stopTest();

        System.assertEquals('Vibration in the front end.', transcript);
    }

    @isTest
    static void testTranscribeAudio_whisperError_throws() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake audio bytes'));
        Test.setMock(HttpCalloutMock.class, new CCCMock(500, '{"error":"server error"}'));

        Test.startTest();
        try {
            CCCController.transcribeAudio(wo.Id, fakeBase64, 'audio/mp4');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('HTTP 500'));
        }
        Test.stopTest();
    }

    @isTest
    static void testTranscribeAudio_blankAudio_throws() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        try {
            CCCController.transcribeAudio(wo.Id, '', 'audio/mp4');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('required'));
        }
    }

    // ── v1.1 voice path: extractCCCFromTranscript ─────────────────────────────

    @isTest
    static void testExtractCCCFromTranscript_success() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CCCMock(200, buildChatSuccessBody()));

        Test.startTest();
        Map<String, String> result = CCCController.extractCCCFromTranscript(
            wo.Id,
            'Vibration in front end. Worn wheel bearing. Replaced bearing.'
        );
        Test.stopTest();

        System.assertEquals('Oil leak observed.',       result.get('complaint'));
        System.assertEquals('Cracked oil pan gasket.',  result.get('cause'));
        System.assertEquals('Replaced oil pan gasket.', result.get('correction'));

        WorkOrder updated = [SELECT CCC_Transcript__c, CCC_Complaint__c FROM WorkOrder WHERE Id = :wo.Id];
        System.assertNotEquals(null, updated.CCC_Transcript__c, 'Transcript should be persisted');
        System.assertNotEquals(null, updated.CCC_Complaint__c,  'Complaint should be persisted');
    }

    @isTest
    static void testExtractCCCFromTranscript_llmError_transcriptSaved() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new CCCMock(500, '{"error":"server error"}'));

        Test.startTest();
        try {
            CCCController.extractCCCFromTranscript(wo.Id, 'The transcript text');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('HTTP 500'));
        }
        Test.stopTest();

        WorkOrder updated = [SELECT CCC_Transcript__c FROM WorkOrder WHERE Id = :wo.Id];
        System.assertEquals('The transcript text', updated.CCC_Transcript__c,
            'Transcript should be saved even when LLM fails');
    }

    @isTest
    static void testExtractCCCFromTranscript_blankTranscript_throws() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        try {
            CCCController.extractCCCFromTranscript(wo.Id, '');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('required'));
        }
    }

    // ── BlobUtils ─────────────────────────────────────────────────────────────

    @isTest
    static void testBlobConcat_mod0() {
        Blob result = BlobUtils.concat(Blob.valueOf('abc'), Blob.valueOf('def'));
        System.assertEquals('abcdef', result.toString());
    }

    @isTest
    static void testBlobConcat_mod1() {
        Blob result = BlobUtils.concat(Blob.valueOf('a'), Blob.valueOf('bcdef'));
        System.assertEquals('abcdef', result.toString());
    }

    @isTest
    static void testBlobConcat_mod2() {
        Blob result = BlobUtils.concat(Blob.valueOf('ab'), Blob.valueOf('cdef'));
        System.assertEquals('abcdef', result.toString());
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static String buildChatSuccessBody() {
        String innerJson = '{\\"complaint\\":\\"Oil leak observed.\\",\\"cause\\":\\"Cracked oil pan gasket.\\",\\"correction\\":\\"Replaced oil pan gasket.\\"}';
        return '{"choices":[{"message":{"role":"assistant","content":"' + innerJson + '"}}]}';
    }

    private class CCCMock implements HttpCalloutMock {
        Integer statusCode;
        String  body;
        CCCMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body       = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }
}
