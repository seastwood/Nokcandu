/* Manual Wine switch test. No audio file is written: samples are reduced to levels then discarded. */
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
int main(int argc, char **argv) {
    const char *flag = getenv("NOKCANDU_NO_MICROPHONE");
    int enabled = flag && !strcmp(flag,"0");
    UINT inputs = waveInGetNumDevs();
    printf("MIC_SWITCH state=%s inputs=%u\n",enabled?"on":"off",inputs); fflush(stdout);
    for(UINT i=0;i<inputs;i++) {
        WAVEINCAPSA caps;
        if(waveInGetDevCapsA(i,&caps,sizeof(caps))==MMSYSERR_NOERROR) printf("Input %u: %s\n",i,caps.szPname);
    }
    UINT selected=WAVE_MAPPER;
    if(argc>1 && strcmp(argv[1],"default")) {
        char *end=NULL;unsigned long value=strtoul(argv[1],&end,10);
        if(!end || *end || value>0xffffffffUL){printf("MIC_SWITCH invalid_device\n");return 5;}
        selected=(UINT)value;
    }
    WAVEFORMATEX format = {WAVE_FORMAT_PCM,1,16000,32000,2,16,0};
    HANDLE event = CreateEventA(NULL,TRUE,FALSE,NULL);
    HWAVEIN input = NULL;
    MMRESULT opened = waveInOpen(&input,selected,&format,(DWORD_PTR)event,0,CALLBACK_EVENT);
    printf("MIC_SWITCH open=%u\n",opened); fflush(stdout);
    if(!enabled) {
        if(opened==MMSYSERR_NOERROR) waveInClose(input);
        CloseHandle(event);
        printf("MIC_SWITCH off_blocked=%s\n",opened!=MMSYSERR_NOERROR?"yes":"NO");
        return opened!=MMSYSERR_NOERROR?0:1;
    }
    if(opened!=MMSYSERR_NOERROR) { CloseHandle(event); return 2; }
    UINT actual=selected;waveInGetID(input,&actual);printf("MIC_SWITCH selected_input=%u\n",actual);
    const DWORD capacity=16000*4;
    short *samples=(short*)calloc(capacity,sizeof(short));
    if(!samples){waveInClose(input);CloseHandle(event);return 3;}
    WAVEHDR header;memset(&header,0,sizeof(header));header.lpData=(LPSTR)samples;header.dwBufferLength=capacity*sizeof(short);
    MMRESULT prepared=waveInPrepareHeader(input,&header,sizeof(header));
    MMRESULT added=prepared==MMSYSERR_NOERROR?waveInAddBuffer(input,&header,sizeof(header)):prepared;
    ResetEvent(event);
    MMRESULT started=added==MMSYSERR_NOERROR?waveInStart(input):added;
    DWORD waited=started==MMSYSERR_NOERROR?WaitForSingleObject(event,12000):WAIT_FAILED;
    waveInStop(input);waveInReset(input);
    DWORD count=header.dwBytesRecorded/sizeof(short);double energy=0;int peak=0;
    if(count>capacity)count=capacity;
    for(DWORD i=0;i<count;i++){int sample=samples[i];int absolute=sample<0?-sample:sample;if(absolute>peak)peak=absolute;double scaled=(double)sample/32768.;energy+=scaled*scaled;}
    printf("MIC_SWITCH prepared=%u added=%u started=%u wait=%lu samples=%lu peak=%d rms=%.8f\n",prepared,added,started,(unsigned long)waited,(unsigned long)count,peak,count?sqrt(energy/count):0);
    printf("MIC_SWITCH raw_audio_saved=no\n");fflush(stdout);
    if(prepared==MMSYSERR_NOERROR)waveInUnprepareHeader(input,&header,sizeof(header));
    waveInClose(input);CloseHandle(event);free(samples);
    return started==MMSYSERR_NOERROR&&count>0?0:4;
}
