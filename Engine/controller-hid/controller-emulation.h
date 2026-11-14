/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Nokcandu: a Switch Pro Controller (USB 057e:2009) or DualShock 4 (USB 054c:05c4) emulated from any SDL game
 * controller, when the environment's controller profile asks for it (Nokcandu's helper exports
 * nokcandu_presented_controller: 2 DualShock 4, 3 Switch Pro). The Xbox identity needs none of this (Wine's own
 * gamepad already has its layout).
 *
 * The protocol (descriptors, input reports, replies to the Pro's USB commands and subcommands, the DS4's feature
 * reports, rumble and light requests) is Nokcandu's shared virtual-controller core, virtualpad.c, the same code
 * that drives Nokcandu's Mac virtual controllers; build.sh copies it here from Sources/NokcanduPadEngine. This file
 * only connects it to Wine's SDL bus: state from the controller's events (so a profile's remapping applies),
 * reports out through Wine's event queue, rumble and the light bar back to SDL.
 * Included by bus_sdl.c inside its SDL_H section. */

#include <dlfcn.h>
#include <time.h>
#include "virtualpad.c"

struct nk_pad
{
    struct unix_device unix_device;
    struct list entry;
    SDL_Joystick *joystick;
    SDL_GameController *controller;
    SDL_JoystickID id;
    BOOL started;
    UINT64 last_report_ms;
    vp_device core;
    vp_state state;
    BYTE next_finger;
};

static struct list nk_pad_list = LIST_INIT(nk_pad_list);
static int (*nk_presented)(void *joystick);
static int (*nk_set_sensor)(SDL_GameController *, int, int);
static int (*nk_set_led)(SDL_Joystick *, Uint8, Uint8, Uint8);

static inline struct nk_pad *nk_pad_from(struct unix_device *iface) { return CONTAINING_RECORD(iface, struct nk_pad, unix_device); }

static UINT64 nk_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (UINT64)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* What Nokcandu's helper presents this controller as (0 when the helper isn't there). */
static int nk_presentation(SDL_Joystick *joystick)
{
    static BOOL looked;
    if (!looked) { looked = TRUE; nk_presented = dlsym(RTLD_DEFAULT, "nokcandu_presented_controller"); }
    return nk_presented ? nk_presented(joystick) : 0;
}

static void nk_pad_reply(void *ctx, const uint8_t *report, size_t length)
{
    struct nk_pad *p = ctx;
    if (p->started) bus_event_queue_input_report(&event_queue, &p->unix_device, (BYTE *)report, length);
}

static void nk_pad_send(struct nk_pad *p)
{
    BYTE r[64];
    size_t n = vp_input_report(&p->core, &p->state, r, sizeof r);
    if (n) nk_pad_reply(p, r, n);
    p->last_report_ms = nk_ms();
}

/* Rumble and light requests the game made, passed to the real controller. */
static void nk_pad_feedback(struct nk_pad *p)
{
    if (p->core.rumble_changed && pSDL_JoystickRumble)
    {
        BOOL on = p->core.rumble_strong || p->core.rumble_weak;
        /* The DS4 keeps a level until changed; the Pro repeats it with every command. */
        pSDL_JoystickRumble(p->joystick, p->core.rumble_strong, p->core.rumble_weak, on ? (p->core.kind == VP_DS4 ? 5000 : 200) : 0);
        p->core.rumble_changed = FALSE;
    }
    if (p->core.light_changed && nk_set_led)
    {
        nk_set_led(p->joystick, p->core.light[0], p->core.light[1], p->core.light[2]);
        p->core.light_changed = FALSE;
    }
}

static void nk_pad_destroy(struct unix_device *iface) {}

static NTSTATUS nk_pad_start(struct unix_device *iface)
{
    struct nk_pad *p = nk_pad_from(iface);
    pthread_mutex_lock(&sdl_cs);
    p->started = TRUE;
    pthread_mutex_unlock(&sdl_cs);
    return STATUS_SUCCESS;
}

static void nk_pad_stop(struct unix_device *iface)
{
    struct nk_pad *p = nk_pad_from(iface);
    pthread_mutex_lock(&sdl_cs);
    p->started = FALSE;
    list_remove(&p->entry);
    pthread_mutex_unlock(&sdl_cs);
    if (p->controller) pSDL_GameControllerClose(p->controller);
    pSDL_JoystickClose(p->joystick);
}

static NTSTATUS nk_pad_get_report_descriptor(struct unix_device *iface, BYTE *buffer, UINT length, UINT *out_length)
{
    struct nk_pad *p = nk_pad_from(iface);
    size_t size = 0;
    const uint8_t *d = vp_descriptor(p->core.kind, &size);
    *out_length = size;
    if (length < size) return STATUS_BUFFER_TOO_SMALL;
    memcpy(buffer, d, size);
    return STATUS_SUCCESS;
}

static void nk_pad_set_output_report(struct unix_device *iface, HID_XFER_PACKET *packet, IO_STATUS_BLOCK *io)
{
    struct nk_pad *p = nk_pad_from(iface);
    pthread_mutex_lock(&sdl_cs);
    vp_output(&p->core, &p->state, packet->reportBuffer, packet->reportBufferLen, nk_pad_reply, p);
    nk_pad_feedback(p);
    pthread_mutex_unlock(&sdl_cs);
    io->Information = packet->reportBufferLen;
    io->Status = STATUS_SUCCESS;
}

static void nk_pad_get_feature_report(struct unix_device *iface, HID_XFER_PACKET *packet, IO_STATUS_BLOCK *io)
{
    struct nk_pad *p = nk_pad_from(iface);
    BYTE r[64];
    size_t n = vp_feature(&p->core, packet->reportId, r, sizeof r);
    if (!n) { io->Information = 0; io->Status = STATUS_NOT_SUPPORTED; return; }
    if (n > packet->reportBufferLen) n = packet->reportBufferLen;
    memcpy(packet->reportBuffer, r, n);
    io->Information = n;
    io->Status = STATUS_SUCCESS;
}

static void nk_pad_set_feature_report(struct unix_device *iface, HID_XFER_PACKET *packet, IO_STATUS_BLOCK *io)
{
    io->Information = packet->reportBufferLen;
    io->Status = STATUS_SUCCESS;
}

static const struct raw_device_vtbl nk_pad_vtbl =
{
    nk_pad_destroy, nk_pad_start, nk_pad_stop, nk_pad_get_report_descriptor, nk_pad_set_output_report,
    nk_pad_get_feature_report, nk_pad_set_feature_report,
};

/* Called from sdl_add_device for a game controller: TRUE when it became an emulated controller. */
static BOOL nk_pad_add(SDL_Joystick *joystick, SDL_GameController *controller, SDL_JoystickID id, struct device_desc *desc)
{
    struct nk_pad *p;
    int kind = controller ? nk_presentation(joystick) : 0;
    if (kind != VP_DS4 && kind != VP_SWITCH_PRO) return FALSE;
    if (!(p = raw_device_create(&nk_pad_vtbl, sizeof(*p)))) return FALSE;
    if (!nk_set_sensor) nk_set_sensor = dlsym(sdl_handle, "SDL_GameControllerSetSensorEnabled");
    if (!nk_set_led) nk_set_led = dlsym(sdl_handle, "SDL_JoystickSetLED");
    if (nk_set_sensor) { nk_set_sensor(controller, SDL_SENSOR_GYRO, 1); nk_set_sensor(controller, SDL_SENSOR_ACCEL, 1); }
    p->joystick = joystick;
    p->controller = controller;
    p->id = id;
    vp_init(&p->core, kind, (uint8_t)id);
    for (int i = 0; i < SDL_CONTROLLER_AXIS_MAX && i < 6; i++) p->state.axes[i] = pSDL_GameControllerGetAxis(controller, i);
    p->state.accel[1] = 9.80665f;               /* lying flat until the first motion reading */
    p->state.finger[0].id = 0; p->state.finger[1].id = 1; p->next_finger = 2;
    list_add_tail(&nk_pad_list, &p->entry);

    desc->vid = vp_vendor(kind);
    desc->pid = vp_product(kind);
    desc->version = kind == VP_DS4 ? 0x0100 : 0x0200;
    desc->is_gamepad = FALSE;                   /* like the real ones: HID, not XInput */
    desc->is_hidraw = FALSE;
    ntdll_umbstowcs(vp_name(kind), strlen(vp_name(kind)) + 1, desc->product, ARRAY_SIZE(desc->product));
    ntdll_umbstowcs(vp_manufacturer(kind), strlen(vp_manufacturer(kind)) + 1, desc->manufacturer, ARRAY_SIZE(desc->manufacturer));
    TRACE("emulating %s for SDL id %d\n", vp_name(kind), id);
    bus_event_queue_device_created(&event_queue, &p->unix_device, desc);
    return TRUE;
}

static struct nk_pad *nk_pad_find(SDL_JoystickID id)
{
    struct nk_pad *p;
    LIST_FOR_EACH_ENTRY(p, &nk_pad_list, struct nk_pad, entry) if (p->id == id) return p;
    return NULL;
}

/* Called from process_device_event (sdl_cs held): TRUE when the event belonged to an emulated controller. */
static BOOL nk_pad_event(SDL_Event *event)
{
    struct nk_pad *p;
    switch (event->type)
    {
    case SDL_JOYDEVICEREMOVED:
        if (!(p = nk_pad_find(((SDL_JoyDeviceEvent *)event)->which))) return FALSE;
        bus_event_queue_device_removed(&event_queue, &p->unix_device);
        return TRUE;
    case SDL_CONTROLLERBUTTONDOWN:
    case SDL_CONTROLLERBUTTONUP:
        if (!(p = nk_pad_find(event->cbutton.which))) return FALSE;
        if (event->cbutton.button < 32)
        {
            if (event->cbutton.state) p->state.buttons |= 1u << event->cbutton.button;
            else p->state.buttons &= ~(1u << event->cbutton.button);
        }
        nk_pad_send(p);                         /* buttons go out at once */
        return TRUE;
    case SDL_CONTROLLERAXISMOTION:
        if (!(p = nk_pad_find(event->caxis.which))) return FALSE;
        if (event->caxis.axis < 6) p->state.axes[event->caxis.axis] = event->caxis.value;
        return TRUE;                            /* with the next periodic report */
    case SDL_CONTROLLERSENSORUPDATE:
        if (!(p = nk_pad_find(event->csensor.which))) return FALSE;
        if (event->csensor.sensor == SDL_SENSOR_GYRO) memcpy(p->state.gyro, event->csensor.data, sizeof p->state.gyro);
        else if (event->csensor.sensor == SDL_SENSOR_ACCEL) memcpy(p->state.accel, event->csensor.data, sizeof p->state.accel);
        return TRUE;
    case SDL_CONTROLLERTOUCHPADDOWN:
    case SDL_CONTROLLERTOUCHPADMOTION:
    case SDL_CONTROLLERTOUCHPADUP:
    {
        int f = event->ctouchpad.finger;
        if (!(p = nk_pad_find(event->ctouchpad.which))) return FALSE;
        if (f < 0 || f > 1) return TRUE;
        if (event->type == SDL_CONTROLLERTOUCHPADDOWN && !p->state.finger[f].down) p->state.finger[f].id = p->next_finger++ & 0x7f;
        p->state.finger[f].down = event->type != SDL_CONTROLLERTOUCHPADUP;
        p->state.finger[f].x = event->ctouchpad.x;
        p->state.finger[f].y = event->ctouchpad.y;
        return TRUE;
    }
    default:
        if (event->type >= SDL_JOYAXISMOTION && event->type <= SDL_JOYBUTTONUP)
            return nk_pad_find(((SDL_JoyButtonEvent *)event)->which) != NULL;   /* the raw joystick side of the same device */
        return FALSE;
    }
}

/* Called from sdl_bus_wait after each event or timeout: reports as often as the real controller (4 ms DS4, 8 ms
 * Pro), limited by Wine's loop (at most about 10 ms). */
static void nk_pad_tick(void)
{
    struct nk_pad *p;
    UINT64 now = nk_ms();
    pthread_mutex_lock(&sdl_cs);
    LIST_FOR_EACH_ENTRY(p, &nk_pad_list, struct nk_pad, entry)
        if (p->started && now - p->last_report_ms >= (UINT64)vp_report_interval_ms(p->core.kind)) nk_pad_send(p);
    pthread_mutex_unlock(&sdl_cs);
}
