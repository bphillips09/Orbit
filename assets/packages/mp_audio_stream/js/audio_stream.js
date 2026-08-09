(async () => {
    class AudioWorkletProcessor{}
  
    class Processor extends AudioWorkletProcessor {

      postStatistics() {
        this.port.postMessage({
          "exhaustCount": this.exhaustCount,
          "fullCount": this.fullCount
        });
      }

      constructor() {
        super();
        
        this.maxBufferSize = 0;
        this.keepBufferSize = 0;

        this.buffer = [];
        this.exhaustCount = 0;
        this.fullCount = 0;
        this.isExhaust = false;

        this.port.onmessage = (event) => {
          if (event.data.type == "data") {
            if (this.buffer.length < this.maxBufferSize) {
              this.buffer.push(...event.data.data);
            } else {
              this.fullCount++;
            }

          } else if (event.data.type == "resetStat") {
            this.exhaustCount = 0;
            this.fullCount = 0;
          }

          this.postStatistics();
        }
      }

      process(_, outputs, __) {
        const out = outputs[0];
        const channels = outputs[0].length
  
        const playableSize = this.buffer.length;
  
        if (this.isExhaust && this.keepBufferSize > playableSize) {
          this.exhaustCount++;
          return true;
        }
  
        this.isExhaust = false;
        var copyLength = 0;

        if (this.buffer.length < out[0].length * channels) {
          copyLength = this.buffer.length;
          this.exhaustCount++;
          this.isExhaust = true;
        } else {
          copyLength = out[0].length * channels;
        }

        for (let channel=0; channel<channels; channel++) {
          var dest = 0;
          for (let source=channel; source<copyLength; source+=channels) {
            out[channel][dest++] = this.buffer[source];
          }
        }
        this.buffer = this.buffer.slice(copyLength);

        this.postStatistics();

        return true;
      }
    }
  
    var audioCtx;
    var workletNode;

    const init =  async (bufSize, waitingBufSize, channels, sampleRate) => {
      audioCtx = new AudioContext({sampleRate:sampleRate});

      const proc = Processor;
      let procCode = proc.toString();
      procCode = procCode.split("this.maxBufferSize = 0;").join(`this.maxBufferSize = ${bufSize};`); // replace
      procCode = procCode.split("this.keepBufferSize = 0;").join(`this.keepBufferSize = ${waitingBufSize}`); // replace
      const f = `data:text/javascript,${encodeURI(procCode)}; registerProcessor("${proc.name}",${proc.name});`;
      await audioCtx.audioWorklet.addModule(f);

      workletNode = new AudioWorkletNode(audioCtx, 'Processor', {outputChannelCount : [channels]});
      workletNode.port.onmessage = (event) => { window.AudioStream.stat = event.data; };
      workletNode.connect(audioCtx.destination);
        
      console.log(`mp-audio-stream initialized. sampleRate:${audioCtx.sampleRate} channels:${channels}`);
    }

    const push = async (data) => {
      const postPush = async (data) => {
        await workletNode?.port.postMessage({"type":"data", "data":data});
      }

      const stackSize = 48000
      if (data.length > stackSize) {
        await postPush(data.subarray(0,stackSize));
        await push(data.subarray(stackSize));
      } else {
        await postPush(data);
      }
    }

    window.AudioStream = {
      init: init,
  
      resume: async () => {
        if (audioCtx == null) {
          console.log("mp-audio-stream is not initialized.");
          return;
        }
        await audioCtx?.resume();
      },
  
      push: push,
  
      uninit: async () => {
        await audioCtx?.close();
        audioCtx = null;
      },

      stat: {"exhaustCount":0, "fullCount":0}, // overwritten in workletNode.port.onmessage

      resetStat: () => {
        workletNode?.port.postMessage({"type":"resetStat"});
      },
  
    };

    console.log("mp-audio-stream loaded.");
  })();
