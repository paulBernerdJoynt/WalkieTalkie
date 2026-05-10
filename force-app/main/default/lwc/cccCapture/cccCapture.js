import { LightningElement, api, track } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import transcribeAudio          from '@salesforce/apex/CCCController.transcribeAudio';
import extractCCCFromTranscript from '@salesforce/apex/CCCController.extractCCCFromTranscript';

const STATE = {
    IDLE:               'idle',
    RECORDING:          'recording',
    TRANSCRIBING:       'transcribing',
    TRANSCRIPT_REVIEW:  'transcript_review',
    EXTRACTING:         'extracting',
    SUCCESS:            'success',
    ERROR:              'error',
};

const NULL_LABEL = '(not identified)';

export default class CccCapture extends LightningElement {
    @api   recordId;
    @track state        = STATE.IDLE;
    @track transcript   = '';
    @track result       = {};
    @track errorMessage = '';

    _mode          = null;   // 'review' | 'extract'
    _mediaRecorder = null;
    _audioChunks   = [];
    _baseMimeType  = 'audio/mp4';

    // ── State booleans ────────────────────────────────────────────────────────

    get isIdle()             { return this.state === STATE.IDLE;              }
    get isRecording()        { return this.state === STATE.RECORDING;         }
    get isTranscribing()     { return this.state === STATE.TRANSCRIBING;      }
    get isTranscriptReview() { return this.state === STATE.TRANSCRIPT_REVIEW; }
    get isExtracting()       { return this.state === STATE.EXTRACTING;        }
    get isSuccess()          { return this.state === STATE.SUCCESS;           }
    get isError()            { return this.state === STATE.ERROR;             }

    get isTranscriptBlank() {
        return !this.transcript || !this.transcript.trim();
    }

    // ── IDLE handlers: choose mode before recording ───────────────────────────

    handleRecordWithReview() {
        this._startRecording('review');
    }

    handleRecordDirect() {
        this._startRecording('extract');
    }

    // ── RECORDING handler ─────────────────────────────────────────────────────

    handleStopRecording() {
        if (this._mediaRecorder && this._mediaRecorder.state === 'recording') {
            this._mediaRecorder.stop();
        }
    }

    // ── TRANSCRIPT_REVIEW handlers ────────────────────────────────────────────

    handleTranscriptChange(event) {
        this.transcript = event.detail.value;
    }

    handleExtractCCC() {
        this._runExtraction();
    }

    handleReRecord() {
        this._reset();
    }

    // ── SUCCESS handlers ──────────────────────────────────────────────────────

    handleDone() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleReset() {
        this._reset();
    }

    // ── Private: recording lifecycle ──────────────────────────────────────────

    async _startRecording(mode) {
        this._mode        = mode;
        this._audioChunks = [];

        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            this._mediaRecorder = new MediaRecorder(stream);
            this._baseMimeType  = (this._mediaRecorder.mimeType || 'audio/mp4').split(';')[0];

            this._mediaRecorder.ondataavailable = (e) => {
                if (e.data && e.data.size > 0) {
                    this._audioChunks.push(e.data);
                }
            };

            this._mediaRecorder.onstop = () => {
                this._onRecordingStop();
            };

            this._mediaRecorder.start();
            this.state = STATE.RECORDING;
        } catch (err) {
            this.errorMessage = 'Microphone access denied. Allow microphone access and try again.';
            this.state = STATE.ERROR;
        }
    }

    async _onRecordingStop() {
        // Release the microphone
        try {
            this._mediaRecorder.stream.getTracks().forEach(t => t.stop());
        } catch (_) { /* best-effort */ }

        this.state = STATE.TRANSCRIBING;

        const audioBlob  = new Blob(this._audioChunks, { type: this._baseMimeType });
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

            if (this._mode === 'review') {
                this.state = STATE.TRANSCRIPT_REVIEW;
            } else {
                await this._runExtraction();
            }
        } catch (err) {
            this.errorMessage =
                (err.body && err.body.message) ||
                err.message ||
                'Transcription failed. Please try again.';
            this.state = STATE.ERROR;
        }
    }

    async _runExtraction() {
        this.state = STATE.EXTRACTING;
        try {
            const ccc = await extractCCCFromTranscript({
                workOrderId: this.recordId,
                transcript:  this.transcript,
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
                'CCC extraction failed. Please try again.';
            this.state = STATE.ERROR;
        }
    }

    _reset() {
        this._audioChunks   = [];
        this._mediaRecorder = null;
        this.transcript     = '';
        this.result         = {};
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
