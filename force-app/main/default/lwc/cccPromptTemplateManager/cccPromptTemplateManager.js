import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import CCC_PROMPT_TEMPLATE_OBJECT from '@salesforce/schema/CCC_Prompt_Template__c';
import getAllTemplates from '@salesforce/apex/CCCTemplateController.getAllTemplates';
import saveTemplate from '@salesforce/apex/CCCTemplateController.saveTemplate';
import setActiveTemplate from '@salesforce/apex/CCCTemplateController.setActiveTemplate';

export default class CccPromptTemplateManager extends LightningElement {
    objectApiName = CCC_PROMPT_TEMPLATE_OBJECT;
    @track templates = [];
    @track selectedTemplate = null;
    @track selectedTemplateId = null;
    @track isLoading = false;
    @track isEditing = false;
    @track editingTemplate = {};

    attemptColumns = [
        { label: 'Attempt #', fieldName: 'Name', type: 'text' },
        { label: 'Raw Input', fieldName: 'Raw_Input__c', type: 'text', wrapText: true },
        { label: 'STT Status', fieldName: 'SpeechToText_Status__c', type: 'text' },
        { label: 'LLM Status', fieldName: 'OpenAI_CCC_Status__c', type: 'text' },
        { label: 'Created', fieldName: 'CreatedDate', type: 'date' }
    ];

    @wire(getAllTemplates)
    wiredTemplates(result) {
        this.isLoading = true;
        if (result.data) {
            this.templates = result.data;
            if (this.templates.length > 0 && !this.selectedTemplate) {
                this.selectTemplate(this.templates[0].Id);
            }
            this.isLoading = false;
        } else if (result.error) {
            this.showError('Error loading templates: ' + result.error.body.message);
            this.isLoading = false;
        }
    }

    selectTemplate(templateId) {
        const template = this.templates.find(t => t.Id === templateId);
        if (template) {
            this.selectedTemplate = template;
            this.selectedTemplateId = templateId;
            this.editingTemplate = { ...template };
            this.isEditing = false;
        }
    }

    handleSelectTemplate(event) {
        this.selectTemplate(event.detail.value);
    }

    handleEdit() {
        this.isEditing = true;
        this.editingTemplate = { ...this.selectedTemplate };
    }

    handleCancel() {
        this.isEditing = false;
        this.editingTemplate = {};
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this.editingTemplate[field] = event.target.value;
    }

    handleCheckboxChange(event) {
        this.editingTemplate.Is_Active__c = event.target.checked;
    }

    handleSave() {
        this.isLoading = true;
        saveTemplate({ template: this.editingTemplate })
            .then((result) => {
                this.selectedTemplate = result;
                this.selectedTemplateId = result.Id;
                this.editingTemplate = { ...result };
                this.isEditing = false;
                this.isLoading = false;
                this.showSuccess('Template saved successfully');
                return this.refreshTemplates();
            })
            .catch((error) => {
                this.showError('Error saving template: ' + error.body.message);
                this.isLoading = false;
            });
    }

    handleSetActive() {
        this.isLoading = true;
        setActiveTemplate({ templateId: this.selectedTemplate.Id })
            .then((result) => {
                this.selectedTemplate = result;
                this.selectedTemplateId = result.Id;
                this.editingTemplate = { ...result };
                this.isLoading = false;
                this.showSuccess('Template set as active');
                return this.refreshTemplates();
            })
            .catch((error) => {
                this.showError('Error setting active template: ' + error.body.message);
                this.isLoading = false;
            });
    }

    refreshTemplates() {
        return getAllTemplates()
            .then((result) => {
                this.templates = result;
            })
            .catch((error) => {
                this.showError('Error refreshing templates: ' + error.body.message);
            });
    }

    showSuccess(message) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Success', message, variant: 'success' }));
    }

    showError(message) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Error', message, variant: 'error' }));
    }

    get hasTemplates() {
        return this.templates && this.templates.length > 0;
    }

    get isActiveTemplate() {
        return this.selectedTemplate && this.selectedTemplate.Is_Active__c;
    }

    get canSetActive() {
        return !this.isEditing && !this.isActiveTemplate;
    }

    get templateOptions() {
        return this.templates.map(t => ({
            label: t.Is_Active__c ? `${t.Name} v${t.Version_Number__c} ★` : `${t.Name} v${t.Version_Number__c}`,
            value: t.Id
        }));
    }
}
