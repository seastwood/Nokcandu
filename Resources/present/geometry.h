// Geometry shared by presentation and input: one mapping between the game's own coordinates (its fullscreen
// window, in points) and where its picture is shown on the Mac's screen. Plain C, no architecture-specific
// code, so it builds for arm64 and x86_64 alike (and can be unit-tested on its own).
#ifndef NOKCANDU_PRESENT_GEOMETRY_H
#define NOKCANDU_PRESENT_GEOMETRY_H
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

typedef struct {
    CGRect game;      // the game's window, global top-left points (what Wine and the game believe)
    CGRect display;   // where its picture appears, global top-left points (inside the frame window)
    double scale;     // display size / game size
    bool valid;
} NokPresentGeometry;

/// Fit: the largest picture that keeps the game's shape, centred in `content`.
static inline void nok_present_update(NokPresentGeometry *g, CGRect game, CGRect content) {
    g->game = game;
    g->valid = game.size.width > 0 && game.size.height > 0 && content.size.width > 0 && content.size.height > 0;
    if (!g->valid) return;
    double sx = content.size.width / game.size.width, sy = content.size.height / game.size.height;
    double s = sx < sy ? sx : sy;
    double w = game.size.width * s, h = game.size.height * s;
    g->scale = s;
    g->display = CGRectMake(content.origin.x + (content.size.width - w) / 2, content.origin.y + (content.size.height - h) / 2, w, h);
}

/// Screen point -> the game's point (outside the picture maps beyond the game's edges, like the real cursor).
static inline CGPoint nok_present_to_game(const NokPresentGeometry *g, CGPoint p) {
    return CGPointMake(g->game.origin.x + (p.x - g->display.origin.x) / g->scale,
                       g->game.origin.y + (p.y - g->display.origin.y) / g->scale);
}

/// The game's point -> screen point.
static inline CGPoint nok_present_to_screen(const NokPresentGeometry *g, CGPoint p) {
    return CGPointMake(g->display.origin.x + (p.x - g->game.origin.x) * g->scale,
                       g->display.origin.y + (p.y - g->game.origin.y) * g->scale);
}

/// Window server transform for a Wine window whose real (untransformed) frame is `window`: maps screen points
/// to the window's own points, so the window appears where its part of the game picture is shown.
static inline CGAffineTransform nok_present_window_transform(const NokPresentGeometry *g, CGRect window) {
    double s = g->scale;
    // A screen point p shows window point q where q = gamePoint(p) - window origin.
    double tx = g->game.origin.x - g->display.origin.x / s - window.origin.x;
    double ty = g->game.origin.y - g->display.origin.y / s - window.origin.y;
    return CGAffineTransformMake(1 / s, 0, 0, 1 / s, tx, ty);
}
#endif
