#ifndef NOKCANDU_PROGRAM_INPUT_SETTINGS_H
#define NOKCANDU_PROGRAM_INPUT_SETTINGS_H
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
static bool nokcandu_same_program_path(const char *a, const char *b) {
    while (*a && *b) {
        unsigned char x=(unsigned char)*a++, y=(unsigned char)*b++;
        if (x=='/') x='\\'; if (y=='/') y='\\';
        if (tolower(x)!=tolower(y)) return false;
    }
    return !*a && !*b;
}
// Exact program paths take priority; a basename entry is emitted only when unambiguous.
static bool nokcandu_program_input(const char *list, const char *program, char *out, size_t size) {
    if (!list || !program || !out || size<2) return false;
    FILE *f=fopen(list,"r"); if(!f)return false;
    const char *base=program;
    for(const char *p=program;*p;p++)if(*p=='/'||*p=='\\')base=p+1;
    char line[8192],fallback[4096]=""; bool found=false;
    while(fgets(line,sizeof line,f)) {
        line[strcspn(line,"\r\n")]=0;
        char *tab=strchr(line,'\t');if(!tab||tab[1]!='/')continue;*tab=0;
        if(strlen(tab+1)>=size)continue;
        bool full=strchr(line,'/')||strchr(line,'\\')||strchr(line,':');
        if(full && nokcandu_same_program_path(line,program)){strcpy(out,tab+1);found=true;break;}
        if(!full&&!strcasecmp(line,base)&&strlen(tab+1)<sizeof fallback)strcpy(fallback,tab+1);
    }
    fclose(f);
    if(!found&&fallback[0]){strcpy(out,fallback);found=true;}
    return found;
}
#endif
