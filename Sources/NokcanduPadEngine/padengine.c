// Controller remapping engine. See padengine.h.
//
// Profile text: one setting per line, words separated by spaces, "key=value" options.
//   nokpad 1
//   gyro out=mouse|lstick|rstick|off on=1 min=6 max=14 lo=0 hi=75 smooth=4 tight=2 invx=0 invy=0 yaw=yaw|roll|both
//        stickfull=300 stickmin=0.1 cal=auto
//   stick 0|1 mode=pad|mouse|flick|keys|none to=0|1 dz=0.15 outer=0.95 sens=1500 power=1.5 flick360=4000
//        flicktime=0.1 keys=<up>,<down>,<left>,<right> (Mac key codes) invy=0
//   trigger 0|1 mode=pad|none soft=0.3 full=0.95
//   bind <layer> <input> press=<outs> tap=<outs> hold=<outs> double=<outs> turbo=<ms> sim=<input> simout=<outs>
//        holdtime=0.2 doubletime=0.22
// <outs>: comma-separated: pad:<button> trig:l|r key:<code> mouse:left|right|middle|back|forward wheel:up|down
//         gyro:on|off|toggle layer:hold:<n> layer:toggle:<n> none
// Layer 0 is the base. A button with no binding in any active layer stays itself (a controller button).
#include "padengine.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#define MAX_LAYERS 8
#define MAX_OUTS 6
#define MAX_TIMERS 64
#define KEYS 128
#define PULSE 0.03          // a tap's outputs stay down this long
#define SIM_WINDOW 0.05

enum { O_NONE, O_PAD, O_TRIG, O_KEY, O_MOUSE, O_WHEEL, O_GYRO_ON, O_GYRO_OFF, O_GYRO_TOGGLE, O_LAYER_HOLD, O_LAYER_TOGGLE };
typedef struct { unsigned char kind; short code; } out_t;
typedef struct { out_t o[MAX_OUTS]; int n; } outs_t;
typedef struct {
    bool set;
    outs_t press, tap, hold, dbl, sim;
    int sim_with;          // -1 none
    double turbo;          // seconds; 0 off
    double hold_time, double_time;
} binding_t;

enum { S_PAD, S_MOUSE, S_FLICK, S_KEYS, S_NONE };
typedef struct {
    int mode, to;
    double dz, outer, sens, power, flick360, flicktime;
    int keys[4];
    bool invy;
    // state
    double x, y;                 // −1…1, y up
    bool flicking; double flick_left, flick_rate, last_angle; bool in_flick;
    int keys_down[4];
    double rest_x, rest_y;
} stick_t;

enum { G_OFF, G_MOUSE, G_LSTICK, G_RSTICK };
enum { Y_YAW, Y_ROLL, Y_BOTH };

typedef struct { double at; int kind; int a, b; } timer_t_;
enum { T_RELEASE_OUTS, T_HOLD, T_DOUBLE_WAIT, T_TURBO, T_SIM_WAIT };

// What a held input is doing (captured at press, so a layer change can't strand a key).
enum { P_IDLE, P_PRESS, P_WAIT_HOLD, P_HOLDING, P_WAIT_DOUBLE, P_DOUBLE, P_SIM_PENDING, P_SIM, P_LATE };
typedef struct {
    int phase;
    const binding_t *b;
    double since;
    outs_t active;              // outputs held down for this input
    bool passthrough;
} press_t;

struct pe_engine {
    pe_sink sink;
    binding_t bind[MAX_LAYERS][PE_INPUTS];
    bool layer_toggled[MAX_LAYERS];
    int layer_holds[MAX_LAYERS];
    press_t press[PE_INPUTS];
    bool physical[PE_INPUTS];
    // outputs (reference counts)
    int pad_ref[PE_PAD_BUTTONS], trig_ref[2], key_ref[KEYS], mouse_ref[PE_MOUSE_BUTTONS];
    int axis_out[PE_AXES];
    int raw_axis[PE_AXES];
    stick_t stick[2];
    int trig_mode[2]; double trig_soft[2], trig_full[2];
    // gyro
    int gyro_out, gyro_yaw; bool gyro_default, gyro_toggled; int gyro_on_holds, gyro_off_holds;
    double g_min, g_max, g_lo, g_hi, g_smooth, g_tight, g_stickfull, g_stickmin;
    bool g_invx, g_invy, g_autocal, uses_gyro;
    double cal_x, cal_y, cal_z, still_since, last_gyro;
    double smooth_buf[16][2]; int smooth_i;
    double g_rest_x, g_rest_y, gyro_stick_x, gyro_stick_y;
    double last_tick;
    timer_t_ timers[MAX_TIMERS]; int ntimers;
    double m_rest_x, m_rest_y;
    outs_t pulse_store[MAX_TIMERS];      // outputs of taps waiting to be released
};

static const char *input_names[PE_INPUTS] = {
    "a", "b", "x", "y", "back", "guide", "start", "ls", "rs", "lb", "rb", "up", "down", "left", "right", "misc",
    "paddle1", "paddle2", "paddle3", "paddle4", "touchpad", "lt", "rt", "ltfull", "rtfull"
};
int pe_input_named(const char *n) {
    for (int i = 0; i < PE_INPUTS; i++) if (!strcmp(n, input_names[i])) return i;
    return -1;
}
const char *pe_input_name(int i) { return i >= 0 && i < PE_INPUTS ? input_names[i] : "?"; }

// MARK: Parsing

static bool parse_out(const char *s, out_t *o) {
    char buf[48]; strncpy(buf, s, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    char *c = strchr(buf, ':');
    char *v = c ? c + 1 : NULL;
    if (c) *c = 0;
    o->code = 0;
    if (!strcmp(buf, "none")) { o->kind = O_NONE; return true; }
    if (!v) return false;
    if (!strcmp(buf, "pad")) { int i = pe_input_named(v); if (i < 0 || i >= PE_PAD_BUTTONS) return false; o->kind = O_PAD; o->code = i; return true; }
    if (!strcmp(buf, "trig")) { o->kind = O_TRIG; o->code = v[0] == 'r'; return true; }
    if (!strcmp(buf, "key")) { int k = atoi(v); if (k < 0 || k >= KEYS) return false; o->kind = O_KEY; o->code = k; return true; }
    if (!strcmp(buf, "mouse")) {
        static const char *m[] = {"left", "right", "middle", "back", "forward"};
        for (int i = 0; i < PE_MOUSE_BUTTONS; i++) if (!strcmp(v, m[i])) { o->kind = O_MOUSE; o->code = i; return true; }
        return false;
    }
    if (!strcmp(buf, "wheel")) { o->kind = O_WHEEL; o->code = strcmp(v, "down") ? 1 : -1; return true; }
    if (!strcmp(buf, "gyro")) { o->kind = !strcmp(v, "on") ? O_GYRO_ON : !strcmp(v, "off") ? O_GYRO_OFF : O_GYRO_TOGGLE; return true; }
    if (!strcmp(buf, "layer")) {
        char *c2 = strchr(v, ':'); if (!c2) return false; *c2 = 0;
        int n = atoi(c2 + 1); if (n < 1 || n >= MAX_LAYERS) return false;
        o->kind = !strcmp(v, "toggle") ? O_LAYER_TOGGLE : O_LAYER_HOLD; o->code = n; return true;
    }
    return false;
}
static void parse_outs(const char *s, outs_t *outs) {
    outs->n = 0;
    char buf[256]; strncpy(buf, s, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    char *save, *t = strtok_r(buf, ",", &save);
    while (t && outs->n < MAX_OUTS) { out_t o; if (parse_out(t, &o)) outs->o[outs->n++] = o; t = strtok_r(NULL, ",", &save); }
}
static double opt_d(const char *v, double d) { return v ? atof(v) : d; }

pe_engine *pe_create(const char *text, pe_sink sink) {
    if (!text || strncmp(text, "nokpad ", 7)) return NULL;
    pe_engine *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->sink = sink;
    for (int s = 0; s < 2; s++) {
        stick_t *k = &e->stick[s];
        k->mode = S_PAD; k->to = s; k->dz = 0.12; k->outer = 0.95; k->sens = 1500; k->power = 1.5;
        k->flick360 = 4000; k->flicktime = 0.1; k->keys[0] = 13; k->keys[1] = 1; k->keys[2] = 0; k->keys[3] = 2;  // W S A D
        e->trig_soft[s] = 0.3; e->trig_full[s] = 0.95;
    }
    e->gyro_out = G_OFF; e->gyro_default = true; e->g_min = 8; e->g_max = 8; e->g_lo = 0; e->g_hi = 75;
    e->g_smooth = 0; e->g_tight = 0; e->g_stickfull = 300; e->g_stickmin = 0.1; e->g_autocal = true;
    char *copy = strdup(text), *lsave;
    for (char *line = strtok_r(copy, "\n", &lsave); line; line = strtok_r(NULL, "\n", &lsave)) {
        char *words[24]; int nw = 0; char *wsave;
        for (char *w = strtok_r(line, " \t\r", &wsave); w && nw < 24; w = strtok_r(NULL, " \t\r", &wsave)) words[nw++] = w;
        if (!nw) continue;
        // options
        const char *opt_k[24], *opt_v[24]; int no = 0;
        for (int i = 1; i < nw; i++) { char *eq = strchr(words[i], '='); if (eq) { *eq = 0; opt_k[no] = words[i]; opt_v[no] = eq + 1; no++; } }
        #define OPT(name) ({ const char *_r = NULL; for (int _i = 0; _i < no; _i++) if (!strcmp(opt_k[_i], name)) _r = opt_v[_i]; _r; })
        if (!strcmp(words[0], "gyro")) {
            const char *o = OPT("out");
            if (o) e->gyro_out = !strcmp(o, "mouse") ? G_MOUSE : !strcmp(o, "lstick") ? G_LSTICK : !strcmp(o, "rstick") ? G_RSTICK : G_OFF;
            const char *y = OPT("yaw");
            if (y) e->gyro_yaw = !strcmp(y, "roll") ? Y_ROLL : !strcmp(y, "both") ? Y_BOTH : Y_YAW;
            e->gyro_default = opt_d(OPT("on"), 1) != 0;
            e->g_min = opt_d(OPT("min"), e->g_min); e->g_max = opt_d(OPT("max"), e->g_min);
            e->g_lo = opt_d(OPT("lo"), e->g_lo); e->g_hi = opt_d(OPT("hi"), e->g_hi);
            e->g_smooth = opt_d(OPT("smooth"), 0); e->g_tight = opt_d(OPT("tight"), 0);
            e->g_invx = opt_d(OPT("invx"), 0) != 0; e->g_invy = opt_d(OPT("invy"), 0) != 0;
            e->g_stickfull = opt_d(OPT("stickfull"), 300); e->g_stickmin = opt_d(OPT("stickmin"), 0.1);
            const char *c = OPT("cal"); e->g_autocal = !c || strcmp(c, "off");
        } else if (!strcmp(words[0], "stick") && nw > 1) {
            int s = atoi(words[1]); if (s < 0 || s > 1) continue;
            stick_t *k = &e->stick[s];
            const char *m = OPT("mode");
            if (m) k->mode = !strcmp(m, "mouse") ? S_MOUSE : !strcmp(m, "flick") ? S_FLICK : !strcmp(m, "keys") ? S_KEYS : !strcmp(m, "none") ? S_NONE : S_PAD;
            k->to = (int)opt_d(OPT("to"), s) ? 1 : 0;
            k->dz = opt_d(OPT("dz"), k->dz); k->outer = opt_d(OPT("outer"), k->outer);
            k->sens = opt_d(OPT("sens"), k->sens); k->power = opt_d(OPT("power"), k->power);
            k->flick360 = opt_d(OPT("flick360"), k->flick360); k->flicktime = opt_d(OPT("flicktime"), k->flicktime);
            k->invy = opt_d(OPT("invy"), 0) != 0;
            const char *ks = OPT("keys");
            if (ks) sscanf(ks, "%d,%d,%d,%d", &k->keys[0], &k->keys[1], &k->keys[2], &k->keys[3]);
        } else if (!strcmp(words[0], "trigger") && nw > 1) {
            int t = atoi(words[1]); if (t < 0 || t > 1) continue;
            const char *m = OPT("mode"); if (m) e->trig_mode[t] = !strcmp(m, "none") ? 1 : 0;
            e->trig_soft[t] = opt_d(OPT("soft"), e->trig_soft[t]); e->trig_full[t] = opt_d(OPT("full"), e->trig_full[t]);
        } else if (!strcmp(words[0], "bind") && nw > 2) {
            int l = atoi(words[1]), in = pe_input_named(words[2]);
            if (l < 0 || l >= MAX_LAYERS || in < 0) continue;
            binding_t *b = &e->bind[l][in];
            memset(b, 0, sizeof *b);
            b->set = true; b->sim_with = -1; b->hold_time = 0.2; b->double_time = 0.22;
            const char *v;
            if ((v = OPT("press"))) parse_outs(v, &b->press);
            if ((v = OPT("tap"))) parse_outs(v, &b->tap);
            if ((v = OPT("hold"))) parse_outs(v, &b->hold);
            if ((v = OPT("double"))) parse_outs(v, &b->dbl);
            if ((v = OPT("simout"))) parse_outs(v, &b->sim);
            if ((v = OPT("sim"))) b->sim_with = pe_input_named(v);
            b->turbo = opt_d(OPT("turbo"), 0) / 1000.0;
            b->hold_time = opt_d(OPT("holdtime"), b->hold_time); b->double_time = opt_d(OPT("doubletime"), b->double_time);
            // tap with nothing else behaves as press
            if (b->tap.n && !b->hold.n && !b->dbl.n && !b->press.n) { b->press = b->tap; b->tap.n = 0; }
        }
        #undef OPT
    }
    free(copy);
    e->uses_gyro = e->gyro_out != G_OFF;
    for (int i = 0; i < 2; i++) e->stick[i].last_angle = NAN;
    return e;
}

void pe_destroy(pe_engine *e) { free(e); }
bool pe_uses_gyro(const pe_engine *e) { return e && e->uses_gyro; }

// MARK: Outputs

static void timer_add(pe_engine *e, double at, int kind, int a, int b) {
    if (e->ntimers >= MAX_TIMERS) return;
    e->timers[e->ntimers++] = (timer_t_){ at, kind, a, b };
}
static void timers_cancel(pe_engine *e, int kind, int a) {
    for (int i = 0; i < e->ntimers; i++)
        if (e->timers[i].kind == kind && e->timers[i].a == a) { e->timers[i] = e->timers[--e->ntimers]; i--; }
}

static void emit_axis(pe_engine *e, int axis, int v) {
    if (v < -32768) v = -32768; if (v > 32767) v = 32767;
    if (e->axis_out[axis] == v) return;
    e->axis_out[axis] = v;
    if (e->sink.pad_axis) e->sink.pad_axis(e->sink.ctx, axis, v);
}
static void update_triggers(pe_engine *e);

static void out_set(pe_engine *e, out_t o, bool down) {
    int d = down ? 1 : -1;
    switch (o.kind) {
    case O_PAD: {
        int r = e->pad_ref[o.code] += d; if (r < 0) e->pad_ref[o.code] = r = 0;
        if ((down && r == 1) || (!down && r == 0)) if (e->sink.pad_button) e->sink.pad_button(e->sink.ctx, o.code, down);
        break; }
    case O_TRIG: { int r = e->trig_ref[o.code] += d; if (r < 0) e->trig_ref[o.code] = 0; update_triggers(e); break; }
    case O_KEY: {
        int r = e->key_ref[o.code] += d; if (r < 0) e->key_ref[o.code] = r = 0;
        if ((down && r == 1) || (!down && r == 0)) if (e->sink.key) e->sink.key(e->sink.ctx, o.code, down);
        break; }
    case O_MOUSE: {
        int r = e->mouse_ref[o.code] += d; if (r < 0) e->mouse_ref[o.code] = r = 0;
        if ((down && r == 1) || (!down && r == 0)) if (e->sink.mouse_button) e->sink.mouse_button(e->sink.ctx, o.code, down);
        break; }
    case O_WHEEL: if (down && e->sink.wheel) e->sink.wheel(e->sink.ctx, o.code); break;
    case O_GYRO_ON: e->gyro_on_holds += d; if (e->gyro_on_holds < 0) e->gyro_on_holds = 0; break;
    case O_GYRO_OFF: e->gyro_off_holds += d; if (e->gyro_off_holds < 0) e->gyro_off_holds = 0; break;
    case O_GYRO_TOGGLE: if (down) e->gyro_toggled = !e->gyro_toggled; break;
    case O_LAYER_HOLD: e->layer_holds[o.code] += d; if (e->layer_holds[o.code] < 0) e->layer_holds[o.code] = 0; break;
    case O_LAYER_TOGGLE: if (down) e->layer_toggled[o.code] = !e->layer_toggled[o.code]; break;
    default: break;
    }
}
static void outs_set(pe_engine *e, const outs_t *o, bool down) {
    if (down) for (int i = 0; i < o->n; i++) out_set(e, o->o[i], true);
    else for (int i = o->n - 1; i >= 0; i--) out_set(e, o->o[i], false);
}
// Down now, up after a short pulse (taps). Stored in a timer by value.
static void pulse(pe_engine *e, const outs_t *o, double now) {
    outs_set(e, o, true);
    int slot = -1;
    for (int i = 0; i < MAX_TIMERS; i++) { bool used = false; for (int t = 0; t < e->ntimers; t++) if (e->timers[t].kind == T_RELEASE_OUTS && e->timers[t].a == i) used = true; if (!used) { slot = i; break; } }
    if (slot < 0) { outs_set(e, o, false); return; }
    e->pulse_store[slot] = *o;
    timer_add(e, now + PULSE, T_RELEASE_OUTS, slot, 0);
}

// MARK: Layers and lookup

static bool layer_active(const pe_engine *e, int l) { return l == 0 || e->layer_holds[l] > 0 || e->layer_toggled[l]; }
static const binding_t *lookup(const pe_engine *e, int in) {
    for (int l = MAX_LAYERS - 1; l >= 0; l--) if (layer_active(e, l) && e->bind[l][in].set) return &e->bind[l][in];
    return NULL;
}
static bool trigger_bound(const pe_engine *e, int t) {
    return lookup(e, PE_LT + t) || lookup(e, PE_LT_FULL + t);
}

// MARK: Buttons

static void input_down(pe_engine *e, int in, double now);
static void input_up(pe_engine *e, int in, double now);

static void begin_press(pe_engine *e, int in, const binding_t *b, double now) {
    press_t *p = &e->press[in];
    // A binding that only has a simultaneous-press part leaves the button as itself otherwise.
    if (b && !b->press.n && !b->tap.n && !b->hold.n && !b->dbl.n) b = NULL;
    p->b = b; p->since = now; p->passthrough = false;
    if (!b) {
        p->phase = P_PRESS; p->passthrough = true;
        if (in < PE_PAD_BUTTONS) { out_t o = { O_PAD, (short)in }; out_set(e, o, true); }
        return;
    }
    if (b->hold.n || (b->tap.n && b->press.n == 0 && b->dbl.n == 0)) {
        p->phase = P_WAIT_HOLD;
        if (b->press.n) { outs_set(e, &b->press, true); p->active = b->press; } else p->active.n = 0;
        timer_add(e, now + b->hold_time, T_HOLD, in, 0);
        return;
    }
    if (b->dbl.n) {     // tap waits to see if a second press follows
        p->phase = P_WAIT_DOUBLE;
        if (b->press.n) { outs_set(e, &b->press, true); p->active = b->press; } else p->active.n = 0;
        return;
    }
    p->phase = P_PRESS;
    p->active = b->press;
    outs_set(e, &b->press, true);
    if (b->turbo > 0) timer_add(e, now + b->turbo, T_TURBO, in, 1);
}

static void input_down(pe_engine *e, int in, double now) {
    press_t *p = &e->press[in];
    if (p->phase == P_WAIT_DOUBLE && p->b && p->b->dbl.n && now - p->since <= p->b->double_time) {
        // second press: the double binding
        timers_cancel(e, T_DOUBLE_WAIT, in);
        p->phase = P_DOUBLE; p->active = p->b->dbl;
        outs_set(e, &p->b->dbl, true);
        return;
    }
    if (p->phase == P_WAIT_DOUBLE) {     // too late for a double: the pending tap fires first
        timers_cancel(e, T_DOUBLE_WAIT, in);
        if (p->b && p->b->tap.n) pulse(e, &p->b->tap, now);
        p->phase = P_IDLE;
    }
    if (p->phase != P_IDLE) return;
    const binding_t *b = lookup(e, in);
    // Simultaneous press: wait briefly for the partner.
    if (b && b->sim_with >= 0) {
        int partner = b->sim_with;
        press_t *q = &e->press[partner];
        if (q->phase == P_SIM_PENDING && now - q->since <= SIM_WINDOW) {
            timers_cancel(e, T_SIM_WAIT, partner);
            const binding_t *qb = q->b;
            const outs_t *so = b->sim.n ? &b->sim : (qb ? &qb->sim : &b->sim);
            p->phase = P_SIM; q->phase = P_SIM; p->b = b;
            p->active = *so; q->active.n = 0;
            outs_set(e, so, true);
            return;
        }
        p->phase = P_SIM_PENDING; p->b = b; p->since = now;
        timer_add(e, now + SIM_WINDOW, T_SIM_WAIT, in, 0);
        return;
    }
    // A partner may be pending on us even though our own binding doesn't name it.
    for (int other = 0; other < PE_INPUTS; other++) {
        press_t *q = &e->press[other];
        if (q->phase == P_SIM_PENDING && q->b && q->b->sim_with == in && now - q->since <= SIM_WINDOW) {
            timers_cancel(e, T_SIM_WAIT, other);
            p->phase = P_SIM; q->phase = P_SIM; p->b = b;
            p->active = q->b->sim; q->active.n = 0;
            outs_set(e, &q->b->sim, true);
            return;
        }
    }
    begin_press(e, in, b, now);
}

static void input_up(pe_engine *e, int in, double now) {
    press_t *p = &e->press[in];
    switch (p->phase) {
    case P_IDLE: return;
    case P_SIM_PENDING:                  // released before the partner came: a normal quick press
        timers_cancel(e, T_SIM_WAIT, in);
        p->phase = P_IDLE;
        begin_press(e, in, p->b, now);
        input_up(e, in, now);
        return;
    case P_WAIT_HOLD:
        timers_cancel(e, T_HOLD, in);
        outs_set(e, &p->active, false);
        if (p->b->dbl.n) { p->phase = P_WAIT_DOUBLE; p->since = now; p->active.n = 0; timer_add(e, now + p->b->double_time, T_DOUBLE_WAIT, in, 0); return; }
        if (p->b->tap.n) pulse(e, &p->b->tap, now);
        p->phase = P_IDLE;
        return;
    case P_WAIT_DOUBLE:
        outs_set(e, &p->active, false); p->active.n = 0;
        p->since = now;
        timer_add(e, now + p->b->double_time, T_DOUBLE_WAIT, in, 0);
        return;                          // stays waiting
    default:
        timers_cancel(e, T_TURBO, in);
        if (p->passthrough) { if (in < PE_PAD_BUTTONS) { out_t o = { O_PAD, (short)in }; out_set(e, o, false); } }
        else outs_set(e, &p->active, false);
        p->active.n = 0; p->phase = P_IDLE; p->passthrough = false;
        return;
    }
}

void pe_button(pe_engine *e, int button, bool down, double now) {
    if (!e || button < 0 || button >= PE_PAD_BUTTONS) return;
    if (e->physical[button] == down) return;
    e->physical[button] = down;
    pe_tick(e, now);
    if (down) input_down(e, button, now); else input_up(e, button, now);
}

// MARK: Triggers

static void update_triggers(pe_engine *e) {
    for (int t = 0; t < 2; t++) {
        int v = 0;
        if (e->trig_ref[t] > 0) v = 32767;
        else if (e->trig_mode[t] == 0 && !trigger_bound(e, t)) v = e->raw_axis[PE_AXIS_LT + t];
        emit_axis(e, PE_AXIS_LT + t, v);
    }
}
static void trigger_input(pe_engine *e, int t, double now) {
    double v = e->raw_axis[PE_AXIS_LT + t] / 32767.0;
    int soft = PE_LT + t, full = PE_LT_FULL + t;
    bool sdown = v >= e->trig_soft[t], fdown = v >= e->trig_full[t];
    // Pressing: soft pull, then full. Letting go: full, then soft.
    if (sdown && !e->physical[soft]) { e->physical[soft] = true; input_down(e, soft, now); }
    if (fdown != e->physical[full]) { e->physical[full] = fdown; if (fdown) input_down(e, full, now); else input_up(e, full, now); }
    if (!sdown && e->physical[soft]) { e->physical[soft] = false; input_up(e, soft, now); }
}

// MARK: Sticks

static void stick_shape(const stick_t *k, double x, double y, double *ox, double *oy, double *mag) {
    double m = sqrt(x * x + y * y);
    if (m <= k->dz) { *ox = *oy = 0; *mag = 0; return; }
    double r = (m - k->dz) / (k->outer - k->dz); if (r > 1) r = 1;
    *ox = x / m * r; *oy = y / m * r; *mag = r;
}
static void update_pad_sticks(pe_engine *e) {
    double sx[2] = {0, 0}, sy[2] = {0, 0};
    for (int s = 0; s < 2; s++) {
        stick_t *k = &e->stick[s];
        if (k->mode != S_PAD) continue;
        double x, y, m; stick_shape(k, k->x, k->y, &x, &y, &m);
        sx[k->to] += x; sy[k->to] += k->invy ? -y : y;
    }
    sx[0] += e->gyro_stick_x * (e->gyro_out == G_LSTICK); sy[0] += e->gyro_stick_y * (e->gyro_out == G_LSTICK);
    sx[1] += e->gyro_stick_x * (e->gyro_out == G_RSTICK); sy[1] += e->gyro_stick_y * (e->gyro_out == G_RSTICK);
    for (int s = 0; s < 2; s++) {
        double x = fmax(-1, fmin(1, sx[s])), y = fmax(-1, fmin(1, sy[s]));
        emit_axis(e, s ? PE_AXIS_RX : PE_AXIS_LX, (int)lround(x * 32767));
        emit_axis(e, s ? PE_AXIS_RY : PE_AXIS_LY, (int)lround(-y * 32767));     // SDL: y down
    }
}
static void mouse_out(pe_engine *e, double dx, double dy) {
    e->m_rest_x += dx; e->m_rest_y += dy;
    int x = (int)e->m_rest_x, y = (int)e->m_rest_y;
    if (!x && !y) return;
    e->m_rest_x -= x; e->m_rest_y -= y;
    if (e->sink.mouse_move) e->sink.mouse_move(e->sink.ctx, x, y);
}
static double wrap180(double a) { while (a > 180) a -= 360; while (a < -180) a += 360; return a; }
static void stick_keys(pe_engine *e, stick_t *k) {
    double m = sqrt(k->x * k->x + k->y * k->y);
    bool want[4] = { false, false, false, false };
    if (m > fmax(k->dz, 0.4)) {
        double a = atan2(k->x, k->y) * 180 / M_PI;        // 0 up, 90 right
        want[0] = fabs(a) < 67.5; want[1] = fabs(a) > 112.5; want[3] = a > 22.5 && a < 157.5; want[2] = a < -22.5 && a > -157.5;
    }
    for (int i = 0; i < 4; i++) if (want[i] != (k->keys_down[i] != 0)) {
        k->keys_down[i] = want[i];
        out_t o = { O_KEY, (short)k->keys[i] }; out_set(e, o, want[i]);
    }
}
static void stick_flick(pe_engine *e, stick_t *k, double now) {
    double m = sqrt(k->x * k->x + k->y * k->y);
    double a = atan2(k->x, k->y) * 180 / M_PI;
    if (!k->in_flick && m >= 0.9) {
        k->in_flick = true; k->last_angle = a;
        k->flick_left = a / 360.0 * k->flick360;
        k->flick_rate = k->flicktime > 0 ? k->flick_left / k->flicktime : 0;
        if (k->flicktime <= 0) { mouse_out(e, k->flick_left, 0); k->flick_left = 0; }
        k->flicking = k->flick_left != 0;
    } else if (k->in_flick && m < 0.7) {
        k->in_flick = false; k->last_angle = NAN;
    } else if (k->in_flick && m >= 0.7) {
        double d = wrap180(a - k->last_angle);
        k->last_angle = a;
        mouse_out(e, d / 360.0 * k->flick360, 0);
    }
    (void)now;
}
static void sticks_continuous(pe_engine *e, double dt) {
    for (int s = 0; s < 2; s++) {
        stick_t *k = &e->stick[s];
        if (k->mode == S_MOUSE) {
            double x, y, m; stick_shape(k, k->x, k->y, &x, &y, &m);
            if (m > 0) {
                double speed = k->sens * pow(m, k->power) * dt;
                mouse_out(e, x / m * speed, -(k->invy ? -y : y) / m * speed);
            }
        } else if (k->mode == S_FLICK && k->flicking) {
            double step = k->flick_rate * dt;
            if (fabs(step) >= fabs(k->flick_left)) { step = k->flick_left; k->flicking = false; }
            k->flick_left -= step;
            mouse_out(e, step, 0);
        }
    }
}

void pe_axis(pe_engine *e, int axis, int value, double now) {
    if (!e || axis < 0 || axis >= PE_AXES) return;
    pe_tick(e, now);
    e->raw_axis[axis] = value;
    if (axis == PE_AXIS_LT || axis == PE_AXIS_RT) { int t = axis - PE_AXIS_LT; trigger_input(e, t, now); update_triggers(e); return; }
    int s = axis >= PE_AXIS_RX;
    stick_t *k = &e->stick[s];
    k->x = e->raw_axis[s ? PE_AXIS_RX : PE_AXIS_LX] / 32767.0;
    k->y = -e->raw_axis[s ? PE_AXIS_RY : PE_AXIS_LY] / 32767.0;       // y up
    if (k->mode == S_KEYS) stick_keys(e, k);
    else if (k->mode == S_FLICK) stick_flick(e, k, now);
    update_pad_sticks(e);
}

// MARK: Gyro

static bool gyro_enabled(const pe_engine *e) {
    if (e->gyro_off_holds > 0) return false;
    if (e->gyro_on_holds > 0) return true;
    return e->gyro_default != e->gyro_toggled;
}

void pe_gyro(pe_engine *e, float gx, float gy, float gz, double now) {
    if (!e || e->gyro_out == G_OFF) return;
    pe_tick(e, now);
    double dt = e->last_gyro > 0 ? now - e->last_gyro : 0;
    e->last_gyro = now;
    if (dt <= 0 || dt > 0.1) dt = 0;
    double x = gx * 180 / M_PI, y = gy * 180 / M_PI, z = gz * 180 / M_PI;     // degrees per second
    // Calibration: while the controller lies still, learn its resting drift.
    if (e->g_autocal) {
        double m = sqrt((x - e->cal_x) * (x - e->cal_x) + (y - e->cal_y) * (y - e->cal_y) + (z - e->cal_z) * (z - e->cal_z));
        if (m < 1.5) {
            if (!e->still_since) e->still_since = now;
            if (now - e->still_since > 1.0) { double f = 0.02; e->cal_x += (x - e->cal_x) * f; e->cal_y += (y - e->cal_y) * f; e->cal_z += (z - e->cal_z) * f; }
        } else e->still_since = 0;
    }
    x -= e->cal_x; y -= e->cal_y; z -= e->cal_z;
    double yaw = e->gyro_yaw == Y_ROLL ? -z : e->gyro_yaw == Y_BOTH ? (y - z) : y;   // left +
    double ox = -yaw, oy = -x;                       // right +, down + (mouse)
    if (e->g_invx) ox = -ox;
    if (e->g_invy) oy = -oy;
    double mag = sqrt(ox * ox + oy * oy);
    // Smoothing for small movements (steadier aim), full response for big ones.
    if (e->g_smooth > 0) {
        e->smooth_buf[e->smooth_i][0] = ox; e->smooth_buf[e->smooth_i][1] = oy; e->smooth_i = (e->smooth_i + 1) % 16;
        double ax = 0, ay = 0; for (int i = 0; i < 16; i++) { ax += e->smooth_buf[i][0]; ay += e->smooth_buf[i][1]; }
        ax /= 16; ay /= 16;
        double w = mag >= 2 * e->g_smooth ? 1 : mag <= e->g_smooth ? 0 : (mag - e->g_smooth) / e->g_smooth;
        ox = ox * w + ax * (1 - w); oy = oy * w + ay * (1 - w);
        mag = sqrt(ox * ox + oy * oy);
    }
    // Tightening: very small movements are hand shake, scale them down.
    if (e->g_tight > 0 && mag < e->g_tight && mag > 0) { double f = mag / e->g_tight; ox *= f; oy *= f; mag *= f; }
    bool on = gyro_enabled(e);
    if (e->gyro_out == G_MOUSE) {
        if (!on || dt == 0) return;
        double sens = e->g_min;
        if (e->g_max != e->g_min && e->g_hi > e->g_lo) {
            double f = (mag - e->g_lo) / (e->g_hi - e->g_lo); f = fmax(0, fmin(1, f));
            sens = e->g_min + (e->g_max - e->g_min) * f;
        }
        mouse_out(e, ox * sens * dt, oy * sens * dt);
    } else {
        double sx = 0, sy = 0;
        if (on && mag > 0) {
            double r = mag / e->g_stickfull; if (r > 1) r = 1;
            double out = e->g_stickmin + (1 - e->g_stickmin) * r;
            sx = ox / mag * out * (mag > 0.5); sy = -oy / mag * out * (mag > 0.5);
        }
        e->gyro_stick_x = sx; e->gyro_stick_y = sy;
        update_pad_sticks(e);
    }
}

// MARK: Timers

void pe_tick(pe_engine *e, double now) {
    if (!e) return;
    double dt = e->last_tick > 0 ? now - e->last_tick : 0;
    if (dt > 0.1) dt = 0.1;
    if (dt > 0) sticks_continuous(e, dt);
    e->last_tick = now;
    bool again = true;
    while (again) {
        again = false;
        for (int i = 0; i < e->ntimers; i++) {
            if (e->timers[i].at > now) continue;
            timer_t_ t = e->timers[i];
            e->timers[i] = e->timers[--e->ntimers];
            again = true;
            press_t *p = t.kind == T_RELEASE_OUTS ? NULL : &e->press[t.a];
            switch (t.kind) {
            case T_RELEASE_OUTS: outs_set(e, &e->pulse_store[t.a], false); break;
            case T_HOLD:
                if (p->phase == P_WAIT_HOLD) {
                    p->phase = P_HOLDING;
                    outs_set(e, &p->active, false);
                    p->active = p->b->hold;
                    outs_set(e, &p->b->hold, true);
                }
                break;
            case T_DOUBLE_WAIT:
                if (p->phase == P_WAIT_DOUBLE) {
                    p->phase = P_IDLE;
                    if (p->b->tap.n) pulse(e, &p->b->tap, t.at);
                    else if (!p->b->press.n && e->physical[t.a]) begin_press(e, t.a, NULL, t.at);
                }
                break;
            case T_TURBO:
                if (p->phase == P_PRESS && p->b && p->b->turbo > 0) {
                    bool down = t.b == 0;
                    outs_set(e, &p->active, down);
                    timer_add(e, t.at + p->b->turbo / 2, T_TURBO, t.a, down ? 1 : 0);
                }
                break;
            case T_SIM_WAIT:
                if (p->phase == P_SIM_PENDING) { p->phase = P_IDLE; begin_press(e, t.a, p->b, t.at); }
                break;
            }
            break;
        }
    }
}

double pe_next_deadline(const pe_engine *e) {
    if (!e) return 0;
    double d = 0;
    for (int i = 0; i < e->ntimers; i++) if (!d || e->timers[i].at < d) d = e->timers[i].at;
    bool continuous = false;
    for (int s = 0; s < 2; s++) {
        const stick_t *k = &e->stick[s];
        if (k->mode == S_MOUSE && sqrt(k->x * k->x + k->y * k->y) > k->dz) continuous = true;
        if (k->mode == S_FLICK && k->flicking) continuous = true;
    }
    if (continuous) { double c = e->last_tick + 0.004; if (!d || c < d) d = c; }
    return d;
}

void pe_release_all(pe_engine *e, double now) {
    if (!e) return;
    for (int i = 0; i < PE_INPUTS; i++) if (e->physical[i] || e->press[i].phase != P_IDLE) {
        e->physical[i] = false;
        press_t *p = &e->press[i];
        if (p->passthrough && i < PE_PAD_BUTTONS) { out_t o = { O_PAD, (short)i }; out_set(e, o, false); }
        else outs_set(e, &p->active, false);
        p->active.n = 0; p->phase = P_IDLE; p->passthrough = false;
    }
    for (int i = 0; i < e->ntimers; i++) if (e->timers[i].kind == T_RELEASE_OUTS) outs_set(e, &e->pulse_store[e->timers[i].a], false);
    e->ntimers = 0;
    for (int s = 0; s < 2; s++) { stick_t *k = &e->stick[s]; k->x = k->y = 0; if (k->mode == S_KEYS) stick_keys(e, k); k->in_flick = k->flicking = false; }
    for (int a = 0; a < PE_AXES; a++) e->raw_axis[a] = 0;
    e->gyro_stick_x = e->gyro_stick_y = 0;
    for (int b = 0; b < PE_PAD_BUTTONS; b++) if (e->pad_ref[b]) { e->pad_ref[b] = 1; out_t o = { O_PAD, (short)b }; out_set(e, o, false); }
    for (int k = 0; k < KEYS; k++) if (e->key_ref[k]) { e->key_ref[k] = 1; out_t o = { O_KEY, (short)k }; out_set(e, o, false); }
    for (int m = 0; m < PE_MOUSE_BUTTONS; m++) if (e->mouse_ref[m]) { e->mouse_ref[m] = 1; out_t o = { O_MOUSE, (short)m }; out_set(e, o, false); }
    e->trig_ref[0] = e->trig_ref[1] = 0;
    memset(e->layer_holds, 0, sizeof e->layer_holds);
    e->gyro_on_holds = e->gyro_off_holds = 0;
    update_triggers(e);
    update_pad_sticks(e);
    (void)now;
}
