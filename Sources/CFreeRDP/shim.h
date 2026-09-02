//
// shim.h — minimal C-header surface from FreeRDP + WinPR that we expose to Swift.
//
// Only include the public C headers needed for our v1 wrapper:
//   - freerdp lifecycle (freerdp_new, freerdp_connect, freerdp_disconnect, freerdp_free)
//   - command-line arg parsing (freerdp_parse_args) for hostname/port/auth/clipboard options
//   - clipboard format IDs (CF_TEXT, CF_UNICODETEXT, ...) used in CLIPRDR
//   - GDI software renderer (gdi_init/gdi_free) — required even before Milestone 2:
//     it initializes the update pipeline (pointer/bitmap caches, primary surface).
//     Without it the first server pointer update segfaults in update_pointer_new()
//     on a NULL cache (observed in crash reports).
//
// Full virtual channel registration and custom graphics callbacks still belong to
// later milestones (M2/M4 of the plan).
//

#ifndef SIMPLERDP_SHIM_H
#define SIMPLERDP_SHIM_H

#include <freerdp/freerdp.h>
#include <freerdp/settings.h>
#include <freerdp/settings_keys.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/addin.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/codec/color.h>
#include <freerdp/input.h>
#include <freerdp/event.h>
#include <winpr/collections.h>
#include <winpr/user.h>

// gdi_init() takes a PIXEL_FORMAT_* constant, but those are built from the
// function-like FREERDP_PIXEL_FORMAT() macro, which Swift's C importer cannot
// see. This wrapper hides the constant so Swift can call it from its
// PostConnect callback closure.
static inline BOOL simplerdp_post_connect(freerdp* instance)
{
    return gdi_init(instance, PIXEL_FORMAT_BGRA32);
}

// Mirror of the sample client's tf_desktop_resize: reallocate the GDI primary
// surface when the server negotiates a new desktop size mid-session.
static inline BOOL simplerdp_desktop_resize(rdpContext* context)
{
    if (!context || !context->gdi || !context->settings)
        return FALSE;
    return gdi_resize(context->gdi,
                      freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth),
                      freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight));
}

// GDI framebuffer accessors for the EndPaint callback. In FreeRDP 3.x the
// primary buffer is TOP-DOWN row-major (gdi_GetPointer computes
// data[y * scanline + x * bpp]), so consumers can copy rows straight across.
// Nil-checks live here in C so Swift never walks a NULL chain.
static inline const BYTE* simplerdp_gdi_primary_buffer(const freerdp* instance)
{
    if (!instance || !instance->context || !instance->context->gdi)
        return NULL;
    return instance->context->gdi->primary_buffer;
}

static inline INT32 simplerdp_gdi_width(const freerdp* instance)
{
    if (!instance || !instance->context || !instance->context->gdi)
        return 0;
    return instance->context->gdi->width;
}

static inline INT32 simplerdp_gdi_height(const freerdp* instance)
{
    if (!instance || !instance->context || !instance->context->gdi)
        return 0;
    return instance->context->gdi->height;
}

static inline UINT32 simplerdp_gdi_stride(const freerdp* instance)
{
    if (!instance || !instance->context || !instance->context->gdi)
        return 0;
    return instance->context->gdi->stride;
}

#endif /* SIMPLERDP_SHIM_H */