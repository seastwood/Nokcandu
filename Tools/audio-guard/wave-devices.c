/* Run only with NOKCANDU_NO_MICROPHONE=1 and Nokcandu's guard injected.
 * Enumerates endpoints; never opens, records or plays an audio stream. */
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
int main(void) {
    UINT inputs = waveInGetNumDevs(), outputs = waveOutGetNumDevs();
    printf("Microphone-off endpoint check: inputs=%u, outputs=%u\n", inputs, outputs);
    if (inputs != 0 || outputs == 0) return 1;
    WAVEFORMATEX format = {WAVE_FORMAT_PCM, 2, 44100, 176400, 4, 16, 0};
    HWAVEOUT out = NULL;
    MMRESULT result = waveOutOpen(&out, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL);
    printf("Output-only stream open=%u (no buffers queued)\n", result);
    if (result != MMSYSERR_NOERROR) return 2;
    return waveOutClose(out) == MMSYSERR_NOERROR ? 0 : 3;
}
