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

    // ── Success path ──────────────────────────────────────────────────────────

    @isTest
    static void testSubmitCCC_success() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new CCCMock(200, buildSuccessBody()));

        Test.startTest();
        Map<String, String> result = CCCController.submitCCC(wo.Id, 'Truck leaking oil. Found cracked pan gasket. Replaced gasket.');
        Test.stopTest();

        System.assertEquals('Oil leak observed.',       result.get('complaint'));
        System.assertEquals('Cracked oil pan gasket.',  result.get('cause'));
        System.assertEquals('Replaced oil pan gasket.', result.get('correction'));

        WorkOrder updated = [SELECT CCC_Raw_Input__c, CCC_Complaint__c, CCC_Cause__c, CCC_Correction__c FROM WorkOrder WHERE Id = :wo.Id];
        System.assertNotEquals(null, updated.CCC_Raw_Input__c,  'Raw input should be persisted');
        System.assertNotEquals(null, updated.CCC_Complaint__c,  'Complaint should be persisted');
    }

    // ── Null fields gracefully handled ────────────────────────────────────────

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

    // ── Blank input validation ────────────────────────────────────────────────

    @isTest
    static void testSubmitCCC_blankInput_throws() {
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        try {
            CCCController.submitCCC(wo.Id, '   ');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('required'), 'Error should mention required');
        }
    }

    // ── Missing API key ───────────────────────────────────────────────────────

    @isTest
    static void testSubmitCCC_missingApiKey_throws() {
        delete [SELECT Id FROM CCC_Configuration__c];
        WorkOrder wo = [SELECT Id FROM WorkOrder LIMIT 1];
        try {
            CCCController.submitCCC(wo.Id, 'Some input');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('API key'), 'Error should mention API key');
        }
    }

    // ── LLM HTTP error — raw input still saved ────────────────────────────────

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
        System.assertEquals('Raw input that must be saved', updated.CCC_Raw_Input__c,
            'Raw input should be saved even when LLM call fails');
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static String buildSuccessBody() {
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
