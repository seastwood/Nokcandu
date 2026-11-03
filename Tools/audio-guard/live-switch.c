/* Manual live test: one Windows PID, bounded 180s, memory-only samples.
 * The caller changes the managed game's Microphone switch while this runs.
 * A control file containing 'stop' ends the diagnostic sooner. */
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    setvbuf(stdout,NULL,_IONBF,0);
    printf("MIC_SWITCH live_pid=%lu inputs=%u raw_audio_saved=no\n",GetCurrentProcessId(),waveInGetNumDevs());
    WAVEFORMATEX format={WAVE_FORMAT_PCM,1,16000,32000,2,16,0};
    HWAVEIN input=NULL;HANDLE event=CreateEventA(NULL,TRUE,FALSE,NULL);
    short samples[16000];WAVEHDR header;memset(&header,0,sizeof(header));
    header.lpData=(LPSTR)samples;header.dwBufferLength=sizeof(samples);
    DWORD start=GetTickCount();int tick=0;
    while(GetTickCount()-start<180000) {
        char command[16]={0};FILE *f=fopen("C:\\NokcanduMicCheck\\live-command","r");
        if(f){fgets(command,sizeof(command),f);fclose(f);}if(!strncmp(command,"stop",4))break;
        if(!input){
            MMRESULT result=waveInOpen(&input,WAVE_MAPPER,&format,(DWORD_PTR)event,0,CALLBACK_EVENT);
            printf("MIC_SWITCH tick=%d open=%u\n",tick++,result);
            if(result){input=NULL;Sleep(1000);continue;}
            if(waveInPrepareHeader(input,&header,sizeof(header))){waveInClose(input);input=NULL;break;}
        }
        memset(samples,0,sizeof(samples));header.dwBytesRecorded=0;header.dwFlags &= ~WHDR_DONE;
        ResetEvent(event);MMRESULT added=waveInAddBuffer(input,&header,sizeof(header));
        MMRESULT started=added?added:waveInStart(input);
        DWORD wait=started?WAIT_FAILED:WaitForSingleObject(event,2500);
        unsigned count=wait==WAIT_OBJECT_0?header.dwBytesRecorded/sizeof(short):0;int peak=0;
        for(unsigned i=0;i<count&&i<16000;i++){int a=samples[i]<0?-samples[i]:samples[i];if(a>peak)peak=a;}
        printf("MIC_SWITCH tick=%d started=%u wait=%lu samples=%u peak=%d\n",tick++,started,wait,count,peak);
        // On timeout the queued buffer remains pending: wait for resume rather
        // than adding it twice. Reset only when explicitly ending this stream.
        while(wait==WAIT_TIMEOUT&&GetTickCount()-start<180000){
            f=fopen("C:\\NokcanduMicCheck\\live-command","r");memset(command,0,sizeof(command));
            if(f){fgets(command,sizeof(command),f);fclose(f);}if(!strncmp(command,"stop",4))goto done;
            wait=WaitForSingleObject(event,1000);
            printf("MIC_SWITCH tick=%d pending_wait=%lu\n",tick++,wait);
        }
    }
done:
    if(input){waveInStop(input);waveInReset(input);waveInUnprepareHeader(input,&header,sizeof(header));waveInClose(input);}
    CloseHandle(event);return 0;
}
