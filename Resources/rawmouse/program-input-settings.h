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
/// The Windows program this process runs, from its arguments. Wine starts a program as `wine <program> …`, then
/// rewrites the arguments once it runs so the program comes first: code that reads them after Cocoa starts (a
/// game's own controller profile and keys inside a shared launcher) sees `<program> …`. Reading only the second
/// argument then took a launcher game's first command-line option, or nothing, and its own profile was skipped.
__attribute__((unused)) static const char *nokcandu_program_argument(int argc, char *const argv[]) {
    if (!argv || argc < 1) return NULL;
    const char *first = argv[0];
    if (first && first[0] && first[0] != '/') {
        size_t n = strlen(first);
        if (n >= 4 && !strcasecmp(first + n - 4, ".exe")) return first;
    }
    return argc > 1 && argv[1] && argv[1][0] != '-' ? argv[1] : NULL;
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
