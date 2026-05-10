import { LightningElement, api, track } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import transcribeAudio from '@salesforce/apex/CCCController.transcribeAudio';
import extractCCC      from '@salesforce/apex/CCCController.extractCCC';

const STATE = {
    IDLE:              'idle',
    RECORDING:         'recording',
    TRANSCRIBING:      'transcribing',
    TRANSCRIPT_READY:  'transcript_ready',
    EXTRACTING:        'extracting',
    SUCCESS:           'success',
    ERROR:             'error',
};

const NULL_LABEL = '(not identified)';

export default class CccCapture extends LightningElement {
    @api   recordId;
    @track state        = STATE.IDLE;
    @track transcript   = '';
    @track errorMessage = '';

    _path          = null;
    _result        = {};
    _mediaRecorder = null;
    _audioChunks   = [];
    _baseMimeType  = 'audio/mp4';

    // ── State booleans ────────────────────────────────────────────────────────

    get isIdle()             { return this.state === STATE.IDLE;             }
    get isRecording()        { return this.state === STATE.RECORDING;        }
    get isTranscribing()     { return this.state === STATE.TRANSCRIBING;     }
    get isTranscriptReady()  { return this.state === STATE.TRANSCRIPT_READY; }
    get isExtracting()       { return this.state === STATE.EXTRACTING;       }
    get isSuccess()          { return this.state === STATE.SUCCESS;          }
    get isError()            { return this.state === STATE.ERROR;            }

    get isTranscriptBlank() {
        return !this.transcript || !this.transcript.trim();
    }

    // ── Extracting label ──────────────────────────────────────────────────────

    get extractingLabel() {
        if (this._path === 'openai')      return 'Running OpenAI GPT-4o…';
        if (this._path === 'agentforce')  return 'Running Agentforce Prompt Builder…';
        return 'Running both paths sequentially…';
    }

    // ── Success display helpers ───────────────────────────────────────────────

    get isSuccessSingle() { return this._path !== 'both'; }

    get providerLabel() {
        return this._path === 'openai' ? 'OpenAI GPT-4o' : 'Agentforce Prompt Builder';
    }

    get singleComplaint() {
        const v = this._path === 'openai'
            ? this._result.openai_complaint
            : this._result.af_complaint;
        return v || NULL_LABEL;
    }
    get singleCause() {
        const v = this._path === 'openai'
            ? this._result.openai_cause
            : this._result.af_cause;
        return v || NULL_LABEL;
    }
    get singleCorrection() {
        const v = this._path === 'openai'
            ? this._result.openai_correction
            : this._result.af_correction;
        return v || NULL_LABEL;
    }

    get openaiComplaint()  { return this._result.openai_complaint  || NULL_LABEL; }
    get openaiCause()      { return this._result.openai_cause      || NULL_LABEL; }
    get openaiCorrection() { return this._result.openai_correction || NULL_LABEL; }

    get agentforceError()  { return this._result.af_error || null; }
    get afComplaint()      { return this._result.af_complaint  || NULL_LABEL; }
    get afCause()          { return this._result.af_cause      || NULL_LABEL; }
    get afCorrection()     { return this._result.af_correction || NULL_LABEL; }

    // ── IDLE handler ──────────────────────────────────────────────────────────

    handleRecord() {
        this._startRecording();
    }

    // ── RECORDING handler ─────────────────────────────────────────────────────

    handleStopRecording() {
        if (this._mediaRecorder && this._mediaRecorder.state === 'recording') {
            this._mediaRecorder.stop();
        }
    }

    // ── TRANSCRIPT_READY handlers ─────────────────────────────────────────────

    handleTranscriptChange(event) {
        this.transcript = event.detail.value;
    }

    handleSendOpenAI()      { this._runExtraction('openai');      }
    handleSendAgentforce()  { this._runExtraction('agentforce');  }
    handleSendBoth()        { this._runExtraction('both');        }

    // ── SUCCESS handlers ──────────────────────────────────────────────────────

    handleDone() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleReset() {
        this._reset();
    }

    // ── Private: recording lifecycle ──────────────────────────────────────────

    async _startRecording() {
        this._audioChunks = [];
        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            this._mediaRecorder = new MediaRecorder(stream);
            this._baseMimeType  = (this._mediaRecorder.mimeType || 'audio/mp4').split(';')[0];

            this._mediaRecorder.ondataavailable = (e) => {
                if (e.data && e.data.size > 0) this._audioChunks.push(e.data);
            };
            this._mediaRecorder.onstop = () => this._onRecordingStop();
            this._mediaRecorder.start();
            this.state = STATE.RECORDING;
        } catch (err) {
            this.errorMessage = 'Microphone access denied. Allow microphone access and try again.';
            this.state = STATE.ERROR;
        }
    }

    async _onRecordingStop() {
        try {
            this._mediaRecorder.stream.getTracks().forEach(t => t.stop());
        } catch (_) { /* best-effort */ }

        this.state = STATE.TRANSCRIBING;

        const audioBlob   = new Blob(this._audioChunks, { type: this._baseMimeType });
        const base64Audio = await this._blobToBase64(audioBlob);

        try {
            this.transcript = await transcribeAudio({
                workOrderId: this.recordId,
                base64Audio,
                mimeType: this._baseMimeType,
            });

            if (!this.transcript || !this.transcript.trim()) {
                this.errorMessage = 'No speech detected. Please try again.';
                this.state = STATE.ERROR;
                return;
            }

            this.state = STATE.TRANSCRIPT_READY;
        } catch (err) {
            this.errorMessage =
                (err.body && err.body.message) || err.message || 'Transcription failed.';
            this.state = STATE.ERROR;
        }
    }

    async _runExtraction(path) {
        this._path = path;
        this.state = STATE.EXTRACTING;
        try {
            this._result = await extractCCC({
                workOrderId: this.recordId,
                transcript:  this.transcript,
                path,
            });
            this.state = STATE.SUCCESS;
        } catch (err) {
            this.errorMessage =
                (err.body && err.body.message) || err.message || 'Extraction failed.';
            this.state = STATE.ERROR;
        }
    }

    _reset() {
        this._audioChunks   = [];
        this._mediaRecorder = null;
        this._result        = {};
        this._path          = null;
        this.transcript     = '';
        this.errorMessage   = '';
        this.state          = STATE.IDLE;
    }

    // ── Private: blob → base64 ────────────────────────────────────────────────

    _blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload  = () => resolve(reader.result.split(',')[1]);
            reader.onerror = reject;
            reader.readAsDataURL(blob);
        });
    }
}
