public with sharing class CCCTemplateController {

    /**
     * Get all CCC_Prompt_Template__c records, ordered by creation date (newest first)
     */
    @AuraEnabled(cacheable=true)
    public static List<CCC_Prompt_Template__c> getAllTemplates() {
        return [
            SELECT Id, Name, Version_Number__c, Prompt_Text__c, Notes__c, Is_Active__c, CreatedDate
            FROM CCC_Prompt_Template__c
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Get the currently active template
     */
    @AuraEnabled(cacheable=true)
    public static CCC_Prompt_Template__c getActiveTemplate() {
        List<CCC_Prompt_Template__c> templates = [
            SELECT Id, Name, Version_Number__c, Prompt_Text__c, Notes__c, Is_Active__c, CreatedDate
            FROM CCC_Prompt_Template__c
            WHERE Is_Active__c = true
            LIMIT 1
        ];
        return templates.isEmpty() ? null : templates[0];
    }

    /**
     * Save a template (insert or update)
     */
    @AuraEnabled
    public static CCC_Prompt_Template__c saveTemplate(CCC_Prompt_Template__c template) {
        if (String.isBlank(template.Id)) {
            // New record
            insert template;
        } else {
            // Update existing
            update template;
        }
        return template;
    }

    /**
     * Set a template as active. Deactivates all others.
     */
    @AuraEnabled
    public static CCC_Prompt_Template__c setActiveTemplate(String templateId) {
        // Deactivate all others
        List<CCC_Prompt_Template__c> others = [
            SELECT Id
            FROM CCC_Prompt_Template__c
            WHERE Is_Active__c = true AND Id != :templateId
        ];
        for (CCC_Prompt_Template__c t : others) {
            t.Is_Active__c = false;
        }
        if (!others.isEmpty()) {
            update others;
        }

        // Activate the selected one
        CCC_Prompt_Template__c activeTemplate = new CCC_Prompt_Template__c(
            Id = templateId,
            Is_Active__c = true
        );
        update activeTemplate;

        // Return the updated template
        return [
            SELECT Id, Name, Version_Number__c, Prompt_Text__c, Notes__c, Is_Active__c, CreatedDate
            FROM CCC_Prompt_Template__c
            WHERE Id = :templateId
            LIMIT 1
        ];
    }
}
