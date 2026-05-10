import { LightningElement, api, track } from 'lwc';
import submitCCC from '@salesforce/apex/CCCController.submitCCC';

const STATE = {
    INPUT:   'input',
    LOADING: 'loading',
    SUCCESS: 'success',
    ERROR:   'error',
};

const NULL_LABEL = '(not identified)';

export default class CccCapture extends LightningElement {
    @api   recordId;
    @track rawInput     = '';
    @track state        = STATE.INPUT;
    @track result       = {};
    @track errorMessage = '';

    get isInput()   { return this.state === STATE.INPUT;   }
    get isLoading() { return this.state === STATE.LOADING; }
    get isSuccess() { return this.state === STATE.SUCCESS; }
    get isError()   { return this.state === STATE.ERROR;   }

    get isSubmitDisabled() {
        return !this.rawInput || !this.rawInput.trim();
    }

    handleInputChange(event) {
        this.rawInput = event.detail.value;
    }

    async handleSubmit() {
        this.state = STATE.LOADING;
        try {
            const ccc = await submitCCC({
                workOrderId: this.recordId,
                rawInput:    this.rawInput,
            });
            this.result = {
                complaint:  ccc.complaint  || NULL_LABEL,
                cause:      ccc.cause      || NULL_LABEL,
                correction: ccc.correction || NULL_LABEL,
            };
            this.state = STATE.SUCCESS;
        } catch (err) {
            this.errorMessage =
                (err.body && err.body.message) ||
                err.message ||
                'An unexpected error occurred.';
            this.state = STATE.ERROR;
        }
    }

    handleReset() {
        this.rawInput     = '';
        this.result       = {};
        this.errorMessage = '';
        this.state        = STATE.INPUT;
    }
}
