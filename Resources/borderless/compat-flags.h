#include <wchar.h>
#include <wctype.h>
#ifdef _WIN32
#define nok_wcsnicmp _wcsnicmp
#else
#define nok_wcsnicmp wcsncasecmp
#endif
static int remove_admin(const wchar_t *value, wchar_t *out, size_t cap) {
    size_t used=0; int changed=0;
    while (*value) {
        while (iswspace(*value)) ++value;
        const wchar_t *start=value;
        while (*value && !iswspace(*value)) ++value;
        size_t len=(size_t)(value-start);
        if (!len) break;
        if (len==10 && !nok_wcsnicmp(start,L"RUNASADMIN",10)) {changed=1;continue;}
        if (used+len+2>cap) return 0;
        if (used) out[used++]=L' ';
        wmemcpy(out+used,start,len);used+=len;
    }
    out[used]=0;return changed;
}
