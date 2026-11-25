// The Sims 2's launch window, laid out like the other ports' (The Sims, Dungeon Siege, Diablo II, Delta Force): the
// game's logo, the Window row as a card per choice, a tile for each group of settings (Display, Graphics, Detail,
// Camera, Updates) that opens it as a panel, Saves and Game Files, Quit and Play. Choices are remembered in
// <data>/launcher.plist and passed to the game as environment (main.m, the renderer, runtime/win32/sims2_options.c).
// Dressed as the game is: frames of its own intro and the store's screenshots drifting and crossfading behind it,
// plumbobs rising and turning, soft lights drifting, the Sims in a rounded blue frame with a plumbob over it, the menus'
// blue panels and a green Play; drawn at 60 fps (the still part drawn once, again only when it changes).
// Art (<data>/art, else Contents/Resources/art; tools/sims2_art.py at install): logo.png, backdrop.jpg and shot.jpg
// (the library banner) from the Steam store page, portrait.jpg (the library capsule), slide-<n>.jpg (the store's
// screenshots), intro-<n>.jpg (frames of the player's own intro movie). Nothing from the game is stored in this
// project; without the art the window writes the title.
// Development: DS_LAUNCHER_SHOT=<png> renders the window (twice its size) and returns (DS_LAUNCHER_OPEN=<group> a group
// opened, DS_LAUNCHER_FOCUS=<n> the keyboard focus on place n, DS_LAUNCHER_TIME=<s> the animation's clock,
// DS_LAUNCHER_TIMING=1 what a frame costs, or in the window frames a second); DS_LAUNCHER_HOME=<folder> the
// launcher's settings and art from there instead of the data folder; DS_LAUNCHER_PLAY=1 presses Play once it is up.
#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include "../runtime/edition.h"

// ---------------------------------------------------------------- settings
typedef struct { NSString *value, *label, *note; } Choice;
@interface DSRow : NSObject
@property NSString *title, *key; @property NSArray<NSDictionary *> *choices; @property NSInteger index;
@property (copy) void (^activate)(void);     /* a row that runs something instead of cycling (Updates) */
@end
@implementation DSRow @end

static NSColor *rgb(double r, double g, double b, double a) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
static NSColor *gold(void) { return rgb(0.52, 0.92, 0.36, 1); }      /* the plumbob's green */
static NSColor *parchment(void) { return rgb(0.97, 0.97, 1.00, 1); }
static NSColor *dim(void) { return rgb(0.68, 0.76, 0.90, 1); }
static NSColor *ember(double a) { return rgb(0.45, 0.90, 0.35, a); } /* the plumbob's glow */
static NSColor *blood(double a) { return rgb(0.08, 0.20, 0.48, a); } /* the menus' blue */
static NSFont *cp(CGFloat size, BOOL bold)                            /* the menus' rounded capitals */
{
    NSFont *f = [NSFont fontWithName:bold ? @"ArialRoundedMTBold" : @"AvenirNext-Medium" size:size];
    return f ?: [NSFont systemFontOfSize:size weight:bold ? NSFontWeightBold : NSFontWeightRegular];
}
static NSFont *book(CGFloat size, BOOL italic)   /* the blurb and the notes */
{
    return [NSFont fontWithName:italic ? @"AvenirNext-Italic" : @"AvenirNext-Regular" size:size] ?: [NSFont systemFontOfSize:size];
}
static double hash01(double x) { double s = sin(x * 12.9898) * 43758.5453; return s - floor(s); }   /* a fixed random number in 0..1 */

// ---------------------------------------------------------------- pictures
/* an image drawn to fill r (cropped to its shape), zoomed by z about a point (fx, fy in 0..1 of the picture, from the top) */
static NSImageInterpolation fill_interp = NSImageInterpolationHigh;   /* (the moving backdrop: Medium, cheaper per frame) */
static void draw_fill_z(NSImage *img, NSRect r, CGFloat alpha, CGFloat z, CGFloat fx, CGFloat fy)
{
    if (!img) return; NSSize s = img.size; if (s.width <= 0 || s.height <= 0) return;
    CGFloat k = MAX(r.size.width / s.width, r.size.height / s.height) * z, w = r.size.width / k, h = r.size.height / k;
    CGFloat x = (s.width - w) * fx, y = (s.height - h) * (1 - fy);                      /* (image space is bottom-up) */
    [img drawInRect:r fromRect:NSMakeRect(x, y, w, h) operation:NSCompositingOperationSourceOver fraction:alpha respectFlipped:YES hints:@{NSImageHintInterpolation: @(fill_interp)}];
}
/* a picture of size points at scale pixels per point, drawn by draw() the way the window draws (top-down) */
static NSImage *offscreen(NSSize size, CGFloat scale, void (^draw)(void))
{
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)ceil(size.width * scale) pixelsHigh:(NSInteger)ceil(size.height * scale)
                                                                 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace] ?: rep;   /* (as the window's: no conversion per frame) */
    rep.size = size;
    CGContextRef cg = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep].CGContext;
    [NSGraphicsContext saveGraphicsState];
    CGContextTranslateCTM(cg, 0, size.height); CGContextScaleCTM(cg, 1, -1);
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES]];
    draw();
    [NSGraphicsContext restoreGraphicsState];
    NSImage *img = [[NSImage alloc] initWithSize:size]; [img addRepresentation:rep];
    return img;
}
/* a picture made ready to draw every frame: decoded once, at most maxw pixels wide */
static NSImage *ready(NSImage *img, CGFloat maxw)
{
    if (!img || img.size.width < 16) return nil;
    NSSize s = img.size; NSInteger pw = 0, ph = 0;                     /* (its pixels: a JPEG at 300 dpi is small in points) */
    for (NSImageRep *r in img.representations) if (r.pixelsWide > pw) { pw = r.pixelsWide; ph = r.pixelsHigh; }
    if (pw > 0 && ph > 0) s = NSMakeSize(pw, ph);
    CGFloat k = MIN(1.0, maxw / s.width);
    return offscreen(NSMakeSize(round(s.width * k), round(s.height * k)), 1, ^{
        [img drawInRect:NSMakeRect(0, 0, round(s.width * k), round(s.height * k)) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES
                  hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}]; });
}

// ---------------------------------------------------------------- the view
/* The window, dressed as the game is: frames of its own intro and the store's screenshots drifting and crossfading
 * behind it, plumbobs rising and turning, soft lights drifting out of focus, its own logo, the Sims in a rounded blue
 * frame with a plumbob over it, the menus' blue panels and a green Play. The Window row is a card per choice; each group
 * of settings is a tile (Display, Graphics, Detail, Camera, Updates) that opens as a panel, Back where Quit was. Once
 * Play is pressed the window stays up, Play reading STARTING…, until the game's own window is on screen. */
@interface DSSection : NSObject
@property NSString *title; @property NSArray<DSRow *> *rows;
@property (copy) void (^activate)(void); @property (copy) NSString *(^summary)(void);
@end
@implementation DSSection @end

@interface DSLaunchView : NSView
@property NSArray<DSRow *> *top; @property NSArray<DSSection *> *sections; @property NSInteger open;   /* the open group, -1 none */
@property NSInteger focus; @property NSInteger hover; @property NSInteger pressed; @property BOOL keyed;   /* keyed: the focus ring shows */
@property NSImage *banner, *stone, *logo, *wood, *woodHover, *woodDown; @property NSString *note;
@property NSArray<NSImage *> *scenes, *cards; @property NSImage *portrait; @property CGFloat portraitFx, portraitFy, portraitZ;
@property double t; @property NSMutableDictionary *cache; @property NSInteger artGen;   /* pictures drawn once (cleared when the art changes) */
@property (copy) void (^onPlay)(void); @property (copy) void (^onQuit)(void); @property (copy) void (^onChange)(void);
@property (copy) void (^onSaves)(void); @property (copy) void (^onFiles)(void);
@property BOOL starting;   /* Play pressed: the game is starting; the window takes no more input */
@end
static void plumbob(NSPoint c, CGFloat h, CGFloat turn, CGFloat alpha);

/* hit codes: rows in an open group 10*row + 0 (left arrow) / 1 (value) / 2 (right arrow); the cards, the tiles */
enum { HIT_NONE = -1, HIT_PLAY = 100, HIT_QUIT = 101, HIT_BACK = 102, HIT_SAVES = 103, HIT_FILES = 104, HIT_SECTION = 200, HIT_CARD = 300 };
/* the keyboard's places at the top level: the cards (0), the tiles (1..), then Saves, Game Files, Quit, Play */
enum { NBOTTOM = 4 };

@implementation DSLaunchView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (NSArray<DSRow *> *)rows { return self.open >= 0 ? self.sections[self.open].rows : self.top; }
- (NSInteger)firstTile { return (NSInteger)self.top.count; }
- (NSInteger)firstBottom { return (NSInteger)self.top.count + (NSInteger)self.sections.count; }
- (NSInteger)items { return self.open >= 0 ? (NSInteger)self.rows.count : self.firstBottom + NBOTTOM; }   /* what the keyboard moves between */
/* ---- layout (points; the view is 980 x 660) ---- */
- (CGFloat)scale { return self.window ? self.window.backingScaleFactor : 2; }
- (NSRect)titleBox { return NSMakeRect(48, 26, 504, 150); }
- (NSRect)portraitRect { return NSMakeRect(self.bounds.size.width - 48 - 300, 50, 300, 372); }
- (NSRect)cardRect:(NSInteger)k { NSInteger n = MAX(1, (NSInteger)self.top.firstObject.choices.count); CGFloat gap = 14, w = (504 - (n - 1) * gap) / n; return NSMakeRect(48 + k * (w + gap), 300, w, 122); }
- (NSRect)sectionRect:(NSInteger)i { NSInteger n = MAX(1, (NSInteger)self.sections.count); CGFloat gap = 12, w = (self.bounds.size.width - 96 - (n - 1) * gap) / n; return NSMakeRect(48 + i * (w + gap), 462, w, 84); }
- (NSRect)savesRect { return NSMakeRect(48, 576, 112, 40); }
- (NSRect)filesRect { return NSMakeRect(48 + 122, 576, 136, 40); }
- (NSRect)playRect { CGFloat W = self.bounds.size.width; return NSMakeRect(W - 48 - 236, 566, 236, 58); }
- (NSRect)quitRect { CGFloat W = self.bounds.size.width; return NSMakeRect(W - 48 - 236 - 14 - 176, 568, 176, 54); }
- (NSRect)flyRect { NSRect b = self.bounds; return NSMakeRect(48, 34, b.size.width - 96, 516); }   /* an open group's panel, above Back and Play */
- (NSRect)rowRect:(NSInteger)k { NSRect f = self.flyRect; return NSMakeRect(f.origin.x + 44, f.origin.y + 80 + 68 * k, f.size.width - 88, 60); }
- (NSRect)arrow:(NSInteger)k right:(BOOL)right { NSRect r = [self rowRect:k]; return NSMakeRect(right ? NSMaxX(r) - 34 : NSMaxX(r) - 340, r.origin.y + 4, 30, 30); }
- (NSRect)valueRect:(NSInteger)k { NSRect r = [self rowRect:k]; return NSMakeRect(NSMaxX(r) - 304, r.origin.y + 7, 266, 30); }
/* the rect of a keyboard place at the top level */
- (NSRect)placeRect:(NSInteger)f
{
    if (f < self.firstTile) return NSUnionRect([self cardRect:0], [self cardRect:(NSInteger)self.top.firstObject.choices.count - 1]);
    if (f < self.firstBottom) return [self sectionRect:f - self.firstTile];
    switch (f - self.firstBottom) { case 0: return self.savesRect; case 1: return self.filesRect; case 2: return self.quitRect; default: return self.playRect; }
}
- (NSInteger)hit:(NSPoint)p
{
    if (NSPointInRect(p, self.playRect)) return HIT_PLAY;
    if (NSPointInRect(p, self.quitRect)) return self.open >= 0 ? HIT_BACK : HIT_QUIT;
    if (self.open < 0) {
        if (NSPointInRect(p, self.savesRect)) return HIT_SAVES;
        if (NSPointInRect(p, self.filesRect)) return HIT_FILES;
        for (NSInteger i = 0; i < (NSInteger)self.sections.count; i++) if (NSPointInRect(p, [self sectionRect:i])) return HIT_SECTION + i;
        for (NSInteger k = 0; k < (NSInteger)self.top.firstObject.choices.count; k++) if (NSPointInRect(p, [self cardRect:k])) return HIT_CARD + k;
        return HIT_NONE;
    }
    for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
        if (NSPointInRect(p, [self arrow:k right:NO])) return 10 * k;
        if (NSPointInRect(p, [self arrow:k right:YES])) return 10 * k + 2;
        if (NSPointInRect(p, [self valueRect:k])) return 10 * k + 1;
    }
    if (!NSPointInRect(p, self.flyRect)) return HIT_BACK;            /* a click outside the panel closes it */
    return HIT_NONE;
}
- (void)openSection:(NSInteger)i
{
    DSSection *s = self.sections[i]; self.focus = self.firstTile + i;
    if (s.activate) { s.activate(); self.needsDisplay = YES; return; }
    self.open = i; self.focus = 0; self.hover = HIT_NONE; self.needsDisplay = YES;
}
- (void)closeSection { if (self.open < 0) return; self.focus = self.firstTile + self.open; self.open = -1; self.hover = HIT_NONE; self.needsDisplay = YES; }
- (void)chooseCard:(NSInteger)k
{
    DSRow *r = self.top.firstObject; if (!r || k == r.index) return;
    r.index = k; self.needsDisplay = YES; if (self.onChange) self.onChange();
}
- (void)updateTrackingAreas
{
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e { if (self.starting) return; NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != self.hover) { self.hover = h; self.needsDisplay = YES; } }
- (void)mouseDown:(NSEvent *)e { if (self.starting) return; self.pressed = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; self.keyed = NO; self.needsDisplay = YES; }
- (void)mouseUp:(NSEvent *)e
{
    if (self.starting) return;
    NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]], p = self.pressed; self.pressed = HIT_NONE; self.needsDisplay = YES;
    if (h != p || h == HIT_NONE) return;
    [self press:h];
}
- (void)press:(NSInteger)h
{
    if (h == HIT_PLAY) { if (self.onPlay) self.onPlay(); return; }
    if (h == HIT_QUIT) { if (self.onQuit) self.onQuit(); return; }
    if (h == HIT_BACK) { [self closeSection]; return; }
    if (h == HIT_SAVES) { if (self.onSaves) self.onSaves(); return; }
    if (h == HIT_FILES) { if (self.onFiles) self.onFiles(); return; }
    if (h >= HIT_CARD) { self.focus = 0; [self chooseCard:h - HIT_CARD]; return; }
    if (h >= HIT_SECTION) { [self openSection:h - HIT_SECTION]; return; }
    NSInteger k = h / 10; self.focus = k;
    if (self.rows[k].activate) { self.rows[k].activate(); self.needsDisplay = YES; return; }
    [self step:k by:(h % 10 == 0) ? -1 : 1];
}
- (void)step:(NSInteger)k by:(NSInteger)dir
{
    DSRow *r = self.rows[k]; NSInteger n = (NSInteger)r.choices.count;
    if (r.activate) { r.activate(); self.needsDisplay = YES; return; }
    r.index = (r.index + dir + n) % n; self.needsDisplay = YES;
    if (self.onChange) self.onChange();
}
/* one step from the keyboard or a controller. An open group: up and down move between its rows, left and right change
 * the row. The top level: the cards (left and right choose), the tiles and the buttons along their rows (round), up and
 * down to the nearest of the next row. Return: the cards play, a tile opens, a button presses. */
enum { NAV_LEFT = 1, NAV_RIGHT, NAV_UP, NAV_DOWN, NAV_OK, NAV_BACK, NAV_PLAY };
- (void)nav:(int)n
{
    if (self.starting) return;
    self.keyed = YES; self.needsDisplay = YES;
    if (n == NAV_PLAY) { if (self.onPlay) self.onPlay(); return; }
    if (self.open >= 0) {
        NSInteger rc = (NSInteger)self.rows.count;
        switch (n) {
        case NAV_BACK: [self closeSection]; return;
        case NAV_UP: self.focus = (self.focus + rc - 1) % rc; return;
        case NAV_DOWN: self.focus = (self.focus + 1) % rc; return;
        case NAV_LEFT: case NAV_RIGHT: [self step:self.focus by:n == NAV_LEFT ? -1 : 1]; return;
        case NAV_OK: if (self.rows[self.focus].activate) { self.rows[self.focus].activate(); return; } [self closeSection]; return;
        }
        return;
    }
    NSInteger f = self.focus, t0 = self.firstTile, b0 = self.firstBottom, end = b0 + NBOTTOM;
    int row = f < t0 ? 0 : f < b0 ? 1 : 2;
    switch (n) {
    case NAV_BACK: if (self.onQuit) self.onQuit(); return;
    case NAV_OK:
        if (row == 0) { if (self.onPlay) self.onPlay(); return; }
        if (row == 1) { [self openSection:f - t0]; return; }
        { static const NSInteger codes[NBOTTOM] = {HIT_SAVES, HIT_FILES, HIT_QUIT, HIT_PLAY}; [self press:codes[f - b0]]; } return;
    case NAV_LEFT: case NAV_RIGHT: {
        NSInteger d = n == NAV_LEFT ? -1 : 1;
        if (row == 0) { DSRow *r = self.top.firstObject; NSInteger c = (NSInteger)r.choices.count; [self chooseCard:(r.index + d + c) % c]; return; }
        NSInteger lo = row == 1 ? t0 : b0, hi = row == 1 ? b0 : end;
        self.focus = lo + (f - lo + d + (hi - lo)) % (hi - lo); return; }
    case NAV_UP: case NAV_DOWN: {
        int to = row + (n == NAV_DOWN ? 1 : -1); if (to < 0 || to > 2) return;
        NSInteger lo = to == 0 ? 0 : to == 1 ? t0 : b0, hi = to == 0 ? t0 : to == 1 ? b0 : end, best = lo; CGFloat x = NSMidX([self placeRect:f]), bd = 1e9;
        for (NSInteger i = lo; i < hi; i++) { CGFloat dd = fabs(NSMidX([self placeRect:i]) - x); if (dd < bd) { bd = dd; best = i; } }
        self.focus = best; return; }
    }
}
- (void)keyDown:(NSEvent *)e
{
    if (self.starting) return;
    switch (e.keyCode) {
    case 0x24: case 0x4c: case 0x31: [self nav:NAV_OK]; return;       /* Return, Enter, Space */
    case 0x35: [self nav:NAV_BACK]; return;                            /* Escape */
    case 0x7e: [self nav:NAV_UP]; return;
    case 0x7d: [self nav:NAV_DOWN]; return;
    case 0x7b: [self nav:NAV_LEFT]; return;
    case 0x7c: [self nav:NAV_RIGHT]; return;
    case 0x23: [self nav:NAV_PLAY]; return;                            /* P */
    }
    [super keyDown:e];
}
static void draw_text(NSString *s, NSFont *f, NSColor *c, NSRect r, NSTextAlignment al, NSShadow *sh)
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = al; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *a = [@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps} mutableCopy];
    if (sh) a[NSShadowAttributeName] = sh;
    [s drawInRect:r withAttributes:a];
}
static CGFloat ktext(NSString *s, NSFont *f, NSColor *c, CGFloat kern, NSPoint at, NSTextAlignment al)   /* kerned, one line; its width */
{
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSKernAttributeName: @(kern)}];
    CGFloat w = a.size.width - kern;
    [a drawAtPoint:NSMakePoint(al == NSTextAlignmentCenter ? at.x - w / 2 : al == NSTextAlignmentRight ? at.x - w : at.x, at.y)];
    return w;
}
static void corner(NSPoint c, CGFloat sx, CGFloat sy, CGFloat len, NSColor *col);
static NSShadow *drop(CGFloat blur, CGFloat a) { NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:a]; sh.shadowOffset = NSMakeSize(0, -1.5); sh.shadowBlurRadius = blur; return sh; }
- (void)drawTitle:(NSRect)r
{
    /* the name when the logo isn't there: white letters, a blue rim, a drop shadow */
    NSString *t = @"THE SIMS 2"; NSFont *f = cp(58, YES);
    NSDictionary *at = @{NSFontAttributeName: f, NSKernAttributeName: @3};
    NSSize sz = [t sizeWithAttributes:at]; NSPoint o = NSMakePoint(NSMidX(r) - sz.width / 2, NSMidY(r) - sz.height / 2 - 2);
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.85]; sh.shadowOffset = NSMakeSize(0, -3); sh.shadowBlurRadius = 5;
    NSMutableDictionary *rim = [at mutableCopy]; rim[NSStrokeColorAttributeName] = rgb(0.80, 0.12, 0.14, 1); rim[NSStrokeWidthAttributeName] = @(9); rim[NSShadowAttributeName] = sh;
    rim[NSForegroundColorAttributeName] = rgb(0.80, 0.12, 0.14, 1);
    [t drawAtPoint:o withAttributes:rim];
    /* silver fill: the glyphs as a clip, a vertical gradient through it */
    NSImage *mask = [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect dst) {
        NSMutableDictionary *m = [at mutableCopy]; m[NSForegroundColorAttributeName] = NSColor.whiteColor; [t drawAtPoint:NSZeroPoint withAttributes:m];
        NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0.98 alpha:1], 0.0, [NSColor colorWithWhite:0.72 alpha:1], 0.45,
                         [NSColor colorWithWhite:0.42 alpha:1], 0.5, [NSColor colorWithWhite:0.86 alpha:1], 0.8, [NSColor colorWithWhite:0.6 alpha:1], 1.0, nil];
        [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationSourceIn];
        [g drawInRect:dst angle:90];
        return YES;
    }];
    [mask drawInRect:NSMakeRect(o.x, o.y, sz.width, sz.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}
/* a button of the game's menus: a rounded blue lozenge with a light rim (Play: green), lighter when pointed at */
- (void)drawButton:(NSRect)r title:(NSString *)title code:(NSInteger)code primary:(BOOL)primary
{
    BOOL foc = self.keyed && self.open < 0 && [self placeRect:self.focus].origin.x == r.origin.x && [self placeRect:self.focus].origin.y == r.origin.y;
    NSImage *img = self.pressed == code ? (self.woodDown ?: self.wood) : self.hover == code || foc ? (self.woodHover ?: self.wood) : self.wood;
    if (img) [img drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    else {
        CGFloat lift = self.pressed == code ? -0.04 : self.hover == code || foc ? 0.06 : 0;
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1) xRadius:r.size.height / 2 - 1 yRadius:r.size.height / 2 - 1];
        NSGradient *g = primary ? [[NSGradient alloc] initWithColorsAndLocations:rgb(0.50 + lift, 0.88 + lift, 0.38 + lift, 1), 0.0, rgb(0.22, 0.62, 0.18, 1), 0.6, rgb(0.12, 0.42, 0.10, 1), 1.0, nil]
                                : [[NSGradient alloc] initWithColorsAndLocations:rgb(0.30 + lift, 0.48 + lift, 0.85 + lift, 1), 0.0, rgb(0.14, 0.28, 0.62, 1), 0.6, rgb(0.08, 0.18, 0.44, 1), 1.0, nil];
        [g drawInBezierPath:p angle:self.pressed == code ? 90 : -90];
        [rgb(1, 1, 1, 0.45) setStroke]; p.lineWidth = 1.5; [p stroke];
        [(foc ? NSColor.whiteColor : rgb(0.02, 0.06, 0.18, 0.9)) setStroke]; NSBezierPath *o = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, -0.5, -0.5) xRadius:r.size.height / 2 yRadius:r.size.height / 2]; o.lineWidth = foc ? 2 : 1; [o stroke];
    }
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; sh.shadowOffset = NSMakeSize(0, -1.5); sh.shadowBlurRadius = 2;
    NSColor *c = NSColor.whiteColor;
    /* the capitals centred on the button (the line's own box sits them high: it leaves room below for descenders) */
    NSFont *f = cp(primary ? 25 : 20, YES); NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSShadowAttributeName: sh, NSKernAttributeName: @(primary ? 3 : 2)};
    NSSize sz = [title sizeWithAttributes:at];
    [title drawAtPoint:NSMakePoint(NSMidX(r) - sz.width / 2, round(NSMidY(r) + f.capHeight / 2 - f.ascender)) withAttributes:at];
}
- (void)drawArrow:(NSRect)r right:(BOOL)right lit:(BOOL)lit
{
    NSBezierPath *p = [NSBezierPath bezierPath]; CGFloat x0 = r.origin.x + 7, x1 = NSMaxX(r) - 7, y0 = r.origin.y + 6, y1 = NSMaxY(r) - 6, ym = NSMidY(r);
    if (right) { [p moveToPoint:NSMakePoint(x0, y0)]; [p lineToPoint:NSMakePoint(x1, ym)]; [p lineToPoint:NSMakePoint(x0, y1)]; }
    else { [p moveToPoint:NSMakePoint(x1, y0)]; [p lineToPoint:NSMakePoint(x0, ym)]; [p lineToPoint:NSMakePoint(x1, y1)]; }
    [p closePath];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:lit ? 1.0 : 0.88 alpha:1] endingColor:[NSColor colorWithWhite:lit ? 0.7 : 0.45 alpha:1]];
    [g drawInBezierPath:p angle:90];
    [rgb(0.08, 0.18, 0.44, 1) setStroke]; p.lineWidth = 1.5; [p stroke];
}
static void rivet(CGFloat x, CGFloat y, CGFloat s)
{
    NSRect d = NSMakeRect(x - s, y - s, 2 * s, 2 * s);
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:rgb(0.98, 0.86, 0.55, 1), 0.0, rgb(0.62, 0.42, 0.16, 1), 0.6, rgb(0.25, 0.15, 0.05, 1), 1.0, nil];
    [g drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:d] relativeCenterPosition:NSMakePoint(-0.35, 0.35)];
}
/* a riveted iron band around a plaque, like the frames of the game's menus */
- (void)drawIronFrame:(NSRect)r
{
    NSBezierPath *outer = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 3, 3)];
    outer.lineWidth = 7; [[NSColor colorWithWhite:0.08 alpha:1] setStroke]; [outer stroke];
    outer.lineWidth = 5; [rgb(0.45, 0.46, 0.47, 1) setStroke]; [outer stroke];
    NSBezierPath *hi = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 1.5, 1.5)]; hi.lineWidth = 1; [[NSColor colorWithWhite:0.78 alpha:0.8] setStroke]; [hi stroke];
    NSBezierPath *lo = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 6, 6)]; lo.lineWidth = 1.2; [[NSColor colorWithWhite:0.05 alpha:0.9] setStroke]; [lo stroke];
    for (CGFloat x = r.origin.x + 14; x <= NSMaxX(r) - 13; x += (r.size.width - 28) / 8) { rivet(x, r.origin.y + 3.5, 4); rivet(x, NSMaxY(r) - 3.5, 4); }
    for (CGFloat y = r.origin.y + 14 + (r.size.height - 28) / 6; y < NSMaxY(r) - 20; y += (r.size.height - 28) / 6) { rivet(r.origin.x + 3.5, y, 4); rivet(NSMaxX(r) - 3.5, y, 4); }
}
/* a gilded corner: an L of brass with a stud, as the game's inventory and dialogue frames have */
static void corner(NSPoint c, CGFloat sx, CGFloat sy, CGFloat len, NSColor *col)
{
    NSBezierPath *p = [NSBezierPath bezierPath]; p.lineWidth = 2; p.lineCapStyle = NSLineCapStyleSquare;
    [p moveToPoint:NSMakePoint(c.x, c.y + sy * len)]; [p lineToPoint:c]; [p lineToPoint:NSMakePoint(c.x + sx * len, c.y)];
    [col setStroke]; [p stroke];
    NSBezierPath *d = [NSBezierPath bezierPath]; CGFloat s = 3.6, x = c.x + sx * 6, y = c.y + sy * 6;
    [d moveToPoint:NSMakePoint(x, y - s)]; [d lineToPoint:NSMakePoint(x + s, y)]; [d lineToPoint:NSMakePoint(x, y + s)]; [d lineToPoint:NSMakePoint(x - s, y)]; [d closePath];
    [col setFill]; [d fill];
}
/* a panel of the game's menus: rounded, a translucent blue, a light rim */
- (void)plate:(NSRect)r lit:(CGFloat)lit edge:(NSColor *)edge
{
    NSBezierPath *rr = [NSBezierPath bezierPathWithRoundedRect:r xRadius:10 yRadius:10];
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:rgb(0.12, 0.24, 0.55, 0.86), 0.0, rgb(0.05, 0.11, 0.30, 0.90), 1.0, nil];
    [g drawInBezierPath:rr angle:-90];
    [rgb(1, 1, 1, 0.30) setStroke]; NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1.5, 1.5) xRadius:9 yRadius:9]; rim.lineWidth = 1; [rim stroke];
    if (lit > 0) { [ember(0.16 * lit) setFill]; [rr fill]; }
    [(edge ?: rgb(0.02, 0.06, 0.18, 0.9)) setStroke]; rr.lineWidth = edge ? 2 : 1; [rr stroke];
    return;
    if (lit > 0) {
        NSGradient *w = [[NSGradient alloc] initWithColorsAndLocations:ember(0.30 * lit), 0.0, blood(0.08 * lit), 1.0, nil];
        [w drawInRect:r angle:-90];
    }
    [(edge ?: [gold() colorWithAlphaComponent:0.38]) setStroke];
    NSBezierPath *p = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)]; p.lineWidth = edge ? 1.5 : 1; [p stroke];
    [[gold() colorWithAlphaComponent:0.12] setStroke];
    NSBezierPath *q = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 4.5, 4.5)]; q.lineWidth = 1; [q stroke];
    NSColor *cc = edge ?: [gold() colorWithAlphaComponent:0.75];
    for (int k = 0; k < 4; k++) corner(NSMakePoint(k % 2 ? NSMaxX(r) - 2 : r.origin.x + 2, k / 2 ? NSMaxY(r) - 2 : r.origin.y + 2), k % 2 ? -1 : 1, k / 2 ? -1 : 1, 12, cc);
}
/* a thin brass rule with a diamond in the middle */
static void rule(CGFloat x0, CGFloat x1, CGFloat y, CGFloat alpha)
{
    CGFloat m = (x0 + x1) / 2;
    [[[NSGradient alloc] initWithColors:@[rgb(0.62, 0.78, 1.0, 0), rgb(0.62, 0.78, 1.0, alpha)]] drawInRect:NSMakeRect(x0, y - 0.5, m - 9 - x0, 1) angle:0];
    [[[NSGradient alloc] initWithColors:@[rgb(0.62, 0.78, 1.0, alpha), rgb(0.62, 0.78, 1.0, 0)]] drawInRect:NSMakeRect(m + 9, y - 0.5, x1 - m - 9, 1) angle:0];
    NSBezierPath *d = [NSBezierPath bezierPath];
    [d moveToPoint:NSMakePoint(m, y - 4.5)]; [d lineToPoint:NSMakePoint(m + 4.5, y)]; [d lineToPoint:NSMakePoint(m, y + 4.5)]; [d lineToPoint:NSMakePoint(m - 4.5, y)]; [d closePath];
    [rgb(0.52, 0.92, 0.36, alpha) setFill]; [d fill];
}
/* ---- the moving part ---- */
/* the backdrop: the slides, each drifting from when it starts fading in until it has faded out (no jump at a handover);
 * a wide one (the key art) pans across */
- (void)backdrop
{
    NSArray<NSImage *> *sc = self.scenes; NSUInteger n = sc.count; NSRect b = self.bounds; double tt = MAX(0.0, self.t);
    if (!n) return;
    double per = 8.5, fadeT = 1.8;
    void (^slide)(NSUInteger, double, CGFloat) = ^(NSUInteger j, double local, CGFloat a) {
        NSImage *im = sc[j % n]; double p = local / (per + fadeT), aspect = im.size.width / MAX(1.0, im.size.height);
        CGFloat dir = (j % 2) ? 1 : -1, amp = aspect > 2.2 ? 0.40 : 0.10;
        draw_fill_z(im, b, a, (CGFloat)(1.04 + 0.07 * p), (CGFloat)(0.5 + dir * amp * (p - 0.5)), (CGFloat)(0.45 + 0.05 * (p - 0.5)));
    };
    if (n == 1) { draw_fill_z(sc[0], b, 1, (CGFloat)(1.08 + 0.035 * sin(tt * 0.11)), (CGFloat)(0.5 + 0.06 * sin(tt * 0.07)), 0.45); return; }
    NSUInteger k = (NSUInteger)(tt / per); double local = tt - (double)k * per;
    if (local < fadeT && k > 0) { slide(k - 1, local + per, 1); slide(k, local, (CGFloat)(local / fadeT)); }
    else slide(k, local, 1);
}
/* a soft round glow (mist, the fire, a spark's halo), drawn once small: it is drawn scaled up, and blurry is right */
- (NSImage *)sprite:(NSString *)key colors:(NSArray<NSColor *> *)cols
{
    NSImage *c = self.cache[key]; if (c) return c;
    c = offscreen(NSMakeSize(128, 128), 1, ^{
        [[[NSGradient alloc] initWithColors:cols] drawFromCenter:NSMakePoint(64, 64) radius:0 toCenter:NSMakePoint(64, 64) radius:64 options:0]; });
    self.cache[key] = c; return c;
}
static void draw_sprite(NSImage *img, NSPoint c, CGFloat rx, CGFloat ry, CGFloat alpha)
{
    if (alpha <= 0.002) return;
    [img drawInRect:NSMakeRect(c.x - rx, c.y - ry, 2 * rx, 2 * ry) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:MIN(1, alpha) respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationLow)}];
}
/* the window's grade, drawn once: a red wash, dark on the left for the title, dark under the tiles, round the edges */
- (NSImage *)grade
{
    NSImage *c = self.cache[@"grade"]; if (c) return c;
    NSRect b = self.bounds;
    c = offscreen(b.size, 1, ^{
        [rgb(0.10, 0.22, 0.50, 0.14) setFill]; NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
        NSGradient *side = [[NSGradient alloc] initWithColorsAndLocations:rgb(0.02, 0.05, 0.14, 0.74), 0.0, rgb(0.02, 0.05, 0.14, 0.40), 0.45, rgb(0.02, 0.05, 0.14, 0.06), 0.78, rgb(0.02, 0.05, 0.14, 0.02), 1.0, nil];
        [side drawInRect:b angle:0];
        NSGradient *low = [[NSGradient alloc] initWithColorsAndLocations:rgb(0, 0, 0, 0.18), 0.0, rgb(0, 0, 0, 0.0), 0.36, rgb(0.02, 0.05, 0.14, 0.42), 0.64, rgb(0.02, 0.05, 0.14, 0.90), 0.84, rgb(0.02, 0.05, 0.14, 0.96), 1.0, nil];
        [low drawInRect:b angle:-90];
        NSGradient *vig = [[NSGradient alloc] initWithStartingColor:rgb(0, 0, 0, 0) endingColor:rgb(0, 0, 0, 0.5)];
        [vig drawInRect:b relativeCenterPosition:NSMakePoint(0.15, 0.1)];
    });
    self.cache[@"grade"] = c; return c;
}
/* the title, its fire behind it, drawn once: the game's own logo, else its name in silver and copper */
- (NSImage *)title
{
    NSImage *c = self.cache[@"title"]; if (c) return c;
    NSRect box = self.titleBox, out = NSInsetRect(box, -40, -40);
    c = offscreen(out.size, self.scale, ^{
        NSRect bx = NSOffsetRect(box, -out.origin.x, -out.origin.y);
        if (self.logo) {
            NSSize s = self.logo.size; CGFloat w = bx.size.width, h = w * s.height / s.width; if (h > bx.size.height) { h = bx.size.height; w = h * s.width / s.height; }
            NSShadow *sh = [NSShadow new]; sh.shadowColor = rgb(0, 0, 0, 0.9); sh.shadowBlurRadius = 8; sh.shadowOffset = NSMakeSize(0, -3); [sh set];
            [self.logo drawInRect:NSMakeRect(NSMidX(bx) - w / 2, NSMidY(bx) - h / 2, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        } else [self drawTitle:bx];
    });
    self.cache[@"title"] = c; return c;
}
/* the portrait in its frame (the frame drawn once, in the still part) */
- (void)drawPortrait:(NSRect)in
{
    [NSGraphicsContext saveGraphicsState]; NSRectClip(in);
    [rgb(0.03, 0.07, 0.18, 1) setFill]; NSRectFill(in);
    if (self.portrait) draw_fill_z(self.portrait, in, 1, (CGFloat)(self.portraitZ + 0.02 * sin(self.t * 0.21)), (CGFloat)(self.portraitFx + 0.01 * sin(self.t * 0.13)), self.portraitFy);
    else if (self.logo) {                                              /* no picture: the logo, in the fire */
        draw_sprite([self sprite:@"fire" colors:@[ember(1), blood(0.5), rgb(0, 0, 0, 0)]], NSMakePoint(NSMidX(in), NSMidY(in)), 200, 200, 0.5);
        NSSize s = self.logo.size; CGFloat w = in.size.width - 30, h = w * s.height / s.width;
        [self.logo drawInRect:NSMakeRect(NSMidX(in) - w / 2, NSMidY(in) - h / 2 - 20, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    NSGradient *foot = [[NSGradient alloc] initWithColorsAndLocations:rgb(0, 0, 0, 0), 0.62, rgb(0.03, 0.08, 0.22, 0.94), 1.0, nil];
    [foot drawInRect:in angle:90];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)setNeedsArt { [self.cache removeAllObjects]; self.artGen++; self.needsDisplay = YES; }
/* what the still part of the window depends on: when it changes, the still part is drawn again */
- (NSString *)signature
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"%ld|%ld|%ld|%ld|%d|%@|%ld|%.0f", (long)self.open, (long)self.focus, (long)self.hover, (long)self.pressed,
                          self.keyed, self.note ?: @"", (long)self.artGen, self.scale];
    for (DSRow *r in self.top) [s appendFormat:@"|%ld", (long)r.index];
    for (DSSection *sec in self.sections) { [s appendFormat:@"|%@", sec.summary ? sec.summary() : @""]; for (DSRow *r in sec.rows) [s appendFormat:@",%ld%@", (long)r.index, r.choices[r.index][@"label"]]; }
    return s;
}
static int frames_drawn;   /* (DS_LAUNCHER_TIMING: frames a second, in the window) */
- (void)drawRect:(NSRect)dirty
{
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height; double T = self.t; frames_drawn++;
    if (!self.cache) self.cache = [NSMutableDictionary dictionary];
    if (![self.cache[@"scale"] isEqual:@(self.scale)]) { [self.cache removeAllObjects]; self.cache[@"scale"] = @(self.scale); }   /* (another display) */
    [rgb(0.03, 0.07, 0.18, 1) setFill]; NSRectFill(b);
    /* the backdrop under the grade */
    fill_interp = NSImageInterpolationMedium; [self backdrop]; fill_interp = NSImageInterpolationHigh;
    [self.grade drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationLow)}];
    /* soft light rolling across; a glow behind the portrait and the title */
    NSImage *mist = [self sprite:@"mist" colors:@[rgb(0.45, 0.62, 0.95, 1), rgb(0.35, 0.50, 0.85, 0.4), rgb(0.3, 0.4, 0.8, 0)]];
    for (int i = 0; i < 7; i++) {
        double sp = 0.5 + hash01(i * 3.1), y = H * (0.35 + 0.55 * hash01(i * 7.7)), r = 150 + 170 * hash01(i * 1.3);
        double x = fmod(hash01(i * 5.9) * (W + 2 * r) + T * 8 * sp, W + 2 * r) - r;
        draw_sprite(mist, NSMakePoint(x, y + 12 * sin(T * 0.2 + i)), r, r * 0.6, 0.13 + 0.05 * sin(T * 0.3 + i));
    }
    NSImage *fire = [self sprite:@"fire" colors:@[ember(1), blood(0.5), rgb(0, 0, 0, 0)]];
    NSRect pr = self.portraitRect; double flick = 0.5 + 0.3 * sin(T * 2.1) + 0.2 * sin(T * 5.3 + 1.3);
    draw_sprite(fire, NSMakePoint(NSMidX(pr), NSMaxY(pr) - 20), 380, 380, 0.22 + 0.10 * flick);
    draw_sprite(fire, NSMakePoint(NSMidX(self.titleBox), NSMidY(self.titleBox) + 6), 330, 110, 0.20 + 0.08 * sin(T * 1.3));
    /* plumbobs rising and turning, a glow round each; soft lights out of focus */
    NSImage *halo = [self sprite:@"halo" colors:@[ember(0.9), ember(0.25), rgb(0, 0, 0, 0)]];
    NSImage *glint = [self sprite:@"glint" colors:@[rgb(1.0, 0.98, 0.85, 1), rgb(0.85, 0.90, 1.0, 0.28), rgb(0, 0, 0, 0)]];
    for (int i = 0; i < 12; i++) {
        double sx = hash01(i * 3.33 + 1), sy = hash01(i * 4.21 + 9), sp = 0.4 + hash01(i * 0.91 + 5);
        double y = H + 30 - fmod(sy * (H + 60) + T * 14 * sp, H + 60), x = sx * W + 24 * sin(T * 0.5 * sp + i);
        double life = MIN(1.0, (H + 30 - y) / 80) * MIN(1.0, (y + 30) / 120); CGFloat hgt = (CGFloat)(9 + 9 * hash01(i * 7.7));
        draw_sprite(halo, NSMakePoint(x, y), hgt * 1.6, hgt * 1.6, 0.35 * life);
        plumbob(NSMakePoint(x, y), hgt, (CGFloat)(T * (0.8 + sp) + i), (CGFloat)(0.75 * life));
    }
    for (int i = 0; i < 46; i++) {
        double sx = hash01(i * 1.618 + 2), sy = hash01(i * 2.414 + 7), sp = 0.3 + hash01(i * 0.577 + 3);
        double y = fmod(sy * (H + 40) - T * 9 * sp, H + 40); if (y < 0) y += H + 40; y -= 20;
        double x = fmod(sx * (W + 40) + 14 * sin(T * 0.5 * sp + i * 1.7), W + 40) - 20;
        double tw = pow(fabs(sin(T * (0.5 + sp) + i * 2.3)), 4), a = 0.10 + 0.5 * tw;
        draw_sprite(glint, NSMakePoint(x, y), 6 + 10 * hash01(i * 3.1), 6 + 10 * hash01(i * 3.1), a * 0.45);
    }
    /* the portrait (its frame is in the still part); the title, its glow breathing */
    [self drawPortrait:NSInsetRect(pr, 13, 13)];
    NSRect tout = NSInsetRect(self.titleBox, -40, -40);
    [self.title drawInRect:tout fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    /* the still part: plates, cards, tiles, buttons, words, an open group's panel (drawn again only when what it shows changes) */
    NSString *sig = self.signature;
    if (!self.cache[@"ui"] || ![self.cache[@"uiSig"] isEqual:sig]) { self.cache[@"ui"] = offscreen(b.size, self.scale, ^{ [self drawStill]; }); self.cache[@"uiSig"] = sig; }
    [(NSImage *)self.cache[@"ui"] drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    /* Play: its fire breathing behind the wooden bar */
    {
        NSRect p = self.playRect; BOOL lit = self.hover == HIT_PLAY || (self.keyed && self.open < 0 && self.focus == self.firstBottom + 3);
        draw_sprite(fire, NSMakePoint(NSMidX(p), NSMidY(p)), p.size.width * 0.75, p.size.height * 1.1, lit ? 0.55 : 0.28 + 0.10 * sin(T * 2.0));
        [self drawButton:p title:self.starting ? @"STARTING…" : @"PLAY" code:HIT_PLAY primary:YES];
    }
}
/* the still part of the window (into a picture: see drawRect) */
- (void)drawStill
{
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height;
    NSShadow *sh = drop(2, 0.9);
    BOOL top = self.open < 0; NSInteger foc = self.keyed && top ? self.focus : HIT_NONE, hov = top ? self.hover : HIT_NONE;
    /* the portrait's frame: iron, riveted, a brass rule and the place on a plaque at its foot; its window left clear */
    {
        NSRect pr = self.portraitRect, in = NSInsetRect(pr, 13, 13);
        [NSGraphicsContext saveGraphicsState];
        NSShadow *s2 = [NSShadow new]; s2.shadowColor = rgb(0, 0, 0, 0.85); s2.shadowBlurRadius = 18; s2.shadowOffset = NSMakeSize(0, -6); [s2 set];
        [rgb(0.04, 0.08, 0.22, 1) setFill]; [[NSBezierPath bezierPathWithRoundedRect:pr xRadius:16 yRadius:16] fill];
        [NSGraphicsContext restoreGraphicsState];
        NSBezierPath *rp = [NSBezierPath bezierPathWithRoundedRect:pr xRadius:16 yRadius:16];
        [[[NSGradient alloc] initWithColorsAndLocations:rgb(0.40, 0.58, 0.95, 1), 0.0, rgb(0.16, 0.30, 0.68, 1), 0.5, rgb(0.08, 0.17, 0.44, 1), 1.0, nil] drawInBezierPath:rp angle:-70];
        [rgb(1, 1, 1, 0.55) setStroke]; NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(pr, 2, 2) xRadius:14 yRadius:14]; rim.lineWidth = 1.5; [rim stroke];
        [rgb(0.02, 0.06, 0.18, 1) setStroke]; rp.lineWidth = 1.5; [rp stroke];
        NSRectFillUsingOperation(in, NSCompositingOperationClear);
        [rgb(0, 0, 0, 0.9) setStroke]; NSBezierPath *f1 = [NSBezierPath bezierPathWithRect:NSInsetRect(in, -1, -1)]; f1.lineWidth = 2; [f1 stroke];
        plumbob(NSMakePoint(NSMidX(pr), pr.origin.y - 2), 22, 0.4, 1);
        rule(in.origin.x + 24, NSMaxX(in) - 24, NSMaxY(in) - 42, 0.85);
        ktext(@"PLEASANTVIEW", cp(14, YES), parchment(), 3, NSMakePoint(NSMidX(in), NSMaxY(in) - 34), NSTextAlignmentCenter);
    }
    /* under the title: the makers, the year, the tale */
    rule(60, 540, 190, 0.6);
    [NSGraphicsContext saveGraphicsState]; [sh set];
    ktext(@"MAXIS  ·  2004  ·  THE LEGACY COLLECTION", cp(12.5, YES), gold(), 2.6, NSMakePoint(300, 200), NSTextAlignmentCenter);
    { NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter; ps.lineSpacing = 3;
      [@"Make your Sims, build their homes and live their lives, from birth to old age: University, Nightlife, Seasons and the rest."
          drawWithRect:NSMakeRect(66, 224, 468, 48) options:NSStringDrawingUsesLineFragmentOrigin
          attributes:@{NSFontAttributeName: book(15.5, YES), NSForegroundColorAttributeName: rgb(0.92, 0.95, 1.0, 0.96), NSParagraphStyleAttributeName: ps}]; }
    [NSGraphicsContext restoreGraphicsState];
    /* the Game row: a card per choice (the game, the Test Lab) */
    DSRow *mode = self.top.firstObject;
    ktext(mode.title.uppercaseString, cp(12, YES), [gold() colorWithAlphaComponent:0.85], 4, NSMakePoint(48, 280), NSTextAlignmentLeft);
    for (NSInteger k = 0; k < (NSInteger)mode.choices.count; k++) {
        NSRect r = [self cardRect:k]; BOOL sel = k == mode.index, hv = hov == HIT_CARD + k, fc = foc == 0 && sel; NSDictionary *ch = mode.choices[k];
        if (sel) {
            [NSGraphicsContext saveGraphicsState]; NSShadow *gl = [NSShadow new]; gl.shadowColor = ember(0.6); gl.shadowBlurRadius = 16; [gl set];
            [rgb(0.04, 0.10, 0.26, 1) setFill]; [[NSBezierPath bezierPathWithRoundedRect:r xRadius:10 yRadius:10] fill]; [NSGraphicsContext restoreGraphicsState];
        }
        [self plate:r lit:sel ? 0.5 : hv ? 0.4 : 0 edge:fc ? parchment() : sel ? gold() : hv ? [gold() colorWithAlphaComponent:0.75] : nil];
        NSRect ir = NSMakeRect(r.origin.x + 7, r.origin.y + 7, r.size.width - 14, 70);
        [NSGraphicsContext saveGraphicsState]; NSRectClip(ir);
        [rgb(0.02, 0.05, 0.14, 1) setFill]; NSRectFill(ir);
        NSImage *art = k < (NSInteger)self.cards.count ? self.cards[k] : nil;
        if ([art isKindOfClass:NSImage.class]) draw_fill_z(art, ir, 1, 1.0, 0.5, 0.45);
        [[[NSGradient alloc] initWithColors:@[rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.45)]] drawInRect:ir angle:90];
        if (!sel) { [rgb(0, 0, 0, hv ? 0.18 : 0.40) setFill]; NSRectFillUsingOperation(ir, NSCompositingOperationSourceOver); }
        [NSGraphicsContext restoreGraphicsState];
        [[gold() colorWithAlphaComponent:sel ? 0.7 : 0.3] setStroke]; NSBezierPath *fr = [NSBezierPath bezierPathWithRect:NSInsetRect(ir, -0.5, -0.5)]; fr.lineWidth = 1; [fr stroke];
        draw_text([ch[@"label"] uppercaseString], cp(14, YES), sel ? parchment() : dim(), NSMakeRect(r.origin.x + 6, r.origin.y + 82, r.size.width - 12, 18), NSTextAlignmentCenter, sh);
        draw_text(ch[@"note"] ?: @"", book(10.5, YES), sel ? rgb(0.86, 0.92, 1.0, 1) : dim(), NSMakeRect(r.origin.x + 14, r.origin.y + 101, r.size.width - 28, 16), NSTextAlignmentCenter, nil);
    }
    /* the settings: a tile per group, its first choice large, the rest under it */
    ktext(@"SETTINGS", cp(12, YES), [gold() colorWithAlphaComponent:0.85], 4, NSMakePoint(48, 442), NSTextAlignmentLeft);
    for (NSInteger i = 0; i < (NSInteger)self.sections.count; i++) {
        DSSection *s = self.sections[i]; NSRect r = [self sectionRect:i]; BOOL hv = hov == HIT_SECTION + i, fc = foc == self.firstTile + i;
        NSString *big, *small;
        if (s.summary) { NSString *sum = s.summary(); NSRange d = [sum rangeOfString:@" · "];
                         big = d.location == NSNotFound ? sum : [sum substringToIndex:d.location]; small = d.location == NSNotFound ? @"" : [sum substringFromIndex:NSMaxRange(d)]; }
        else { NSMutableArray *l = [NSMutableArray array]; for (DSRow *row in s.rows) [l addObject:row.choices[row.index][@"label"]];
               big = l.firstObject ?: @""; small = l.count > 1 ? [[l subarrayWithRange:NSMakeRange(1, l.count - 1)] componentsJoinedByString:@" · "] : (s.rows.firstObject.choices[s.rows.firstObject.index][@"note"] ?: @""); }
        [self plate:r lit:hv || fc ? 1 : 0 edge:fc ? parchment() : hv ? gold() : nil];
        ktext(s.title.uppercaseString, cp(12, YES), gold(), 2.5, NSMakePoint(r.origin.x + 15, r.origin.y + 12), NSTextAlignmentLeft);
        draw_text(big, cp(17, YES), parchment(), NSMakeRect(r.origin.x + 15, r.origin.y + 31, r.size.width - 26, 22), NSTextAlignmentLeft, sh);
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
        [small drawWithRect:NSMakeRect(r.origin.x + 15, r.origin.y + 55, r.size.width - 24, 26) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                 attributes:@{NSFontAttributeName: book(10.5, NO), NSForegroundColorAttributeName: dim(), NSParagraphStyleAttributeName: ps}];
    }
    /* Saves and Game Files; Quit (Play is drawn live) */
    rule(48, W - 48, 558, 0.35);
    NSArray *small = @[@"SAVES", @"GAME FILES"]; NSArray *codes = @[@(HIT_SAVES), @(HIT_FILES)];
    for (NSInteger k = 0; k < 2; k++) {
        NSRect r = k ? self.filesRect : self.savesRect; NSInteger code = [codes[k] integerValue]; BOOL hv = hov == code, fc = foc == self.firstBottom + k;
        [self plate:r lit:hv || fc ? 0.6 : 0 edge:fc ? parchment() : hv ? gold() : nil];
        ktext(small[k], cp(13, YES), hv || fc ? parchment() : dim(), 2, NSMakePoint(NSMidX(r), r.origin.y + 12), NSTextAlignmentCenter);
    }
    /* an open group: a panel over the window, framed in iron */
    if (!top) {
        [rgb(0.0, 0.02, 0.08, 0.62) setFill]; NSRectFillUsingOperation(NSMakeRect(0, 0, W, 556), NSCompositingOperationSourceOver);
        NSRect f = self.flyRect;
        [NSGraphicsContext saveGraphicsState]; NSShadow *s2 = [NSShadow new]; s2.shadowColor = rgb(0, 0, 0, 0.9); s2.shadowBlurRadius = 24; [s2 set];
        [rgb(0.06, 0.13, 0.34, 0.97) setFill]; NSRectFill(NSInsetRect(f, 6, 6)); [NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithWhite:0 alpha:0.35] setFill]; NSRectFillUsingOperation(NSInsetRect(f, 6, 6), NSCompositingOperationSourceOver);
        [rgb(1, 1, 1, 0.4) setStroke]; NSBezierPath *fr2 = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(f, 3, 3) xRadius:14 yRadius:14]; fr2.lineWidth = 2; [fr2 stroke];
        for (int k = 0; k < 0; k++) corner(NSMakePoint(k % 2 ? NSMaxX(f) - 14 : f.origin.x + 14, k / 2 ? NSMaxY(f) - 14 : f.origin.y + 14), k % 2 ? -1 : 1, k / 2 ? -1 : 1, 26, [gold() colorWithAlphaComponent:0.85]);
        ktext(self.sections[self.open].title.uppercaseString, cp(26, YES), gold(), 5, NSMakePoint(NSMidX(f), f.origin.y + 26), NSTextAlignmentCenter);
        rule(f.origin.x + 60, NSMaxX(f) - 60, f.origin.y + 66, 0.7);
        for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
            DSRow *row = self.rows[k]; NSRect r = [self rowRect:k]; NSDictionary *ch = row.choices[row.index];
            if (k == self.focus) { [ember(0.14) setFill]; NSRectFillUsingOperation(NSInsetRect(r, -12, -3), NSCompositingOperationSourceOver);
                                   [[gold() colorWithAlphaComponent:self.keyed ? 0.7 : 0.25] setStroke]; NSBezierPath *fb = [NSBezierPath bezierPathWithRect:NSInsetRect(r, -11.5, -2.5)]; fb.lineWidth = 1; [fb stroke]; }
            draw_text(row.title.uppercaseString, cp(18, YES), gold(), NSMakeRect(r.origin.x, r.origin.y + 8, 300, 26), NSTextAlignmentLeft, sh);
            [self drawArrow:[self arrow:k right:NO] right:NO lit:self.hover == 10 * k];
            [self drawArrow:[self arrow:k right:YES] right:YES lit:self.hover == 10 * k + 2];
            draw_text(ch[@"label"], cp(18, NO), self.hover == 10 * k + 1 ? NSColor.whiteColor : parchment(), [self valueRect:k], NSTextAlignmentCenter, sh);
            draw_text(ch[@"note"] ?: @"", book(12, YES), dim(), NSMakeRect(NSMaxX(r) - 360, r.origin.y + 38, 360, 18), NSTextAlignmentCenter, nil);
            if (k + 1 < (NSInteger)self.rows.count) { [rgb(0.55, 0.70, 1.0, 0.25) setFill]; NSRectFillUsingOperation(NSMakeRect(r.origin.x, NSMaxY(r) + 3, r.size.width, 1), NSCompositingOperationSourceOver); }
        }
    }
    [self drawButton:self.quitRect title:top ? @"QUIT" : @"BACK" code:top ? HIT_QUIT : HIT_BACK primary:NO];
    NSString *hint = self.note.length ? self.note : !top ? @"Left and right change a row  ·  up and down move  ·  Esc goes back"
                   : @"Click a card or a tile  ·  arrows move  ·  Return chooses  ·  P plays  ·  Esc quits";
    draw_text(hint, book(12.5, NO), dim(), NSMakeRect(48, H - 30, W - 96 - 250, 18), NSTextAlignmentLeft, nil);
    ktext(@"NATIVE FOR APPLE SILICON  ·  METAL", cp(10, NO), [dim() colorWithAlphaComponent:0.85], 3, NSMakePoint(W - 48, H - 27), NSTextAlignmentRight);
}
@end

/* the plumbob: a green diamond (two pyramids, lit on one side), turning */
static void plumbob(NSPoint c, CGFloat h, CGFloat turn, CGFloat alpha)
{
    CGFloat w = h * 0.42 * (0.55 + 0.45 * fabs(cos(turn))), mid = c.x + h * 0.42 * 0.35 * sin(turn);
    NSPoint top = NSMakePoint(c.x, c.y - h), bot = NSMakePoint(c.x, c.y + h), l = NSMakePoint(c.x - w, c.y), r = NSMakePoint(c.x + w, c.y), m = NSMakePoint(mid, c.y);
    NSBezierPath *a = [NSBezierPath bezierPath]; [a moveToPoint:top]; [a lineToPoint:l]; [a lineToPoint:m]; [a closePath];
    NSBezierPath *b = [NSBezierPath bezierPath]; [b moveToPoint:top]; [b lineToPoint:m]; [b lineToPoint:r]; [b closePath];
    NSBezierPath *cc = [NSBezierPath bezierPath]; [cc moveToPoint:bot]; [cc lineToPoint:l]; [cc lineToPoint:m]; [cc closePath];
    NSBezierPath *d = [NSBezierPath bezierPath]; [d moveToPoint:bot]; [d lineToPoint:m]; [d lineToPoint:r]; [d closePath];
    [rgb(0.62, 0.98, 0.50, alpha) setFill]; [a fill]; [rgb(0.36, 0.80, 0.26, alpha) setFill]; [b fill];
    [rgb(0.30, 0.70, 0.22, alpha) setFill]; [cc fill]; [rgb(0.16, 0.50, 0.12, alpha) setFill]; [d fill];
}
// ---------------------------------------------------------------- choices, settings file, the window
/* Keep a visible window during startup. Hiding the modal window before the game has a window can hand
 * activation/Space selection back to the previous app. The host retires it once the game is frontmost. */
static NSWindow *launch_window; static NSTimer *launch_anim;
void ds_launcher_game_shown(void)
{
    [launch_anim invalidate]; launch_anim = nil;
    [launch_window orderOut:nil]; launch_window = nil;
}
static NSInteger index_of(NSArray<NSDictionary *> *c, NSString *v, NSInteger dflt)
{
    for (NSUInteger k = 0; k < c.count; k++) if ([c[k][@"value"] isEqualToString:v ?: @""]) return (NSInteger)k;
    return dflt;
}
/* the screens the game can be given: the display's own pixels (Retina) or its points, both drawn the same size (the
 * game scales its art and interface to the screen's height), Retina the sharper */
/* the game's screen (DS_RESOLUTION): this display in points, its Retina pixels, or a common size, scaled to fill */
static int notch_height(void) { if (@available(macOS 12.0, *)) return (int)NSScreen.mainScreen.safeAreaInsets.top; return 0; }
static NSArray<NSDictionary *> *resolution_choices(BOOL below_notch)
{
    NSScreen *s = NSScreen.mainScreen; int W = (int)s.frame.size.width, H = (int)s.frame.size.height; double sc = s.backingScaleFactor;
    if (below_notch) H -= notch_height();
    NSMutableArray *a = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    void (^add)(int, int, NSString *) = ^(int w, int h, NSString *note) {
        w &= ~1; h &= ~1; NSString *v = [NSString stringWithFormat:@"%dx%d", w, h]; if ([seen containsObject:v]) return; [seen addObject:v];
        [a addObject:@{@"value": v, @"label": [NSString stringWithFormat:@"%d × %d", w, h], @"note": note}];
    };
    add(W, H, sc > 1.01 ? @"This display in points, scaled up: lighter on the GPU" : @"This display");
    if (sc > 1.01) add((int)(W * sc + 0.5), (int)(H * sc + 0.5), @"Retina: every pixel, the sharpest (recommended)");
    static const int std[][2] = {{2560,1600},{2560,1440},{1920,1200},{1920,1080},{1680,1050},{1600,900},{1440,900},{1280,800},{1280,720},{1024,768}};
    for (size_t k = 0; k < sizeof std / sizeof *std; k++) if (std[k][0] <= W && std[k][1] <= H) add(std[k][0], std[k][1], @"Scaled to fill the screen");
    return a;
}
/* Interface Size: the game runs at the resolution divided by this, so its interface is laid out that much larger, and
 * the renderer draws at the chosen resolution itself (DSR_RENDER_SCALE), so the 3D stays sharp. Sizes leaving the game
 * under 1024x700 aren't offered. The default is 100%, and 200% at Retina resolution: the game's layout in points,
 * drawn in pixels. */
static NSArray<NSDictionary *> *ui_choices(NSString *res)
{
    int W = 0, H = 0; sscanf(res.UTF8String, "%dx%d", &W, &H);
    NSMutableArray *a = [NSMutableArray array];
    static const int sizes[] = {100, 125, 150, 175, 200, 250, 300};
    for (size_t k = 0; k < sizeof sizes / sizeof *sizes; k++) { int pc = sizes[k];
        if (pc > 100 && (W * 100 / pc < 1024 || H * 100 / pc < 700)) continue;
        [a addObject:@{@"value": [NSString stringWithFormat:@"%d", pc], @"label": [NSString stringWithFormat:@"%d%%", pc],
                       @"note": pc == 100 ? @"As the game draws it: the smallest interface" : [NSString stringWithFormat:@"The game laid out at %d × %d, drawn at %d × %d",
                                 (int)lround(W * 100.0 / pc) & ~1, (int)lround(H * 100.0 / pc) & ~1, W, H]}];
    }
    return a;
}
static NSArray<NSDictionary *> *window_choices(void)
{
    return @[@{@"value": @"full", @"label": @"Full Screen", @"note": @"macOS full screen, with Game Mode"},
             @{@"value": @"window", @"label": @"Window", @"note": @"A window you can move and resize"}];
}
static NSArray<NSDictionary *> *notch_choices(void)
{
    return @[@{@"value": @"hide", @"label": @"Below the Notch", @"note": @"The picture under the camera, a black band beside it"},
             @{@"value": @"around", @"label": @"Around the Notch", @"note": @"The whole display; the notch covers a little of the top (no Game Mode)"}];
}
static NSArray<NSDictionary *> *framerate_choices(void)
{
    NSInteger hz = NSScreen.mainScreen.maximumFramesPerSecond; if (hz <= 0) hz = 60;
    NSMutableArray *a = [NSMutableArray arrayWithObject:@{@"value": [NSString stringWithFormat:@"%ld", (long)hz], @"label": [NSString stringWithFormat:@"Display (%ld FPS)", (long)hz],
        @"note": @"As smooth as the display shows"}];
    if (hz > 60) [a addObject:@{@"value": @"60", @"label": @"60 FPS", @"note": @"Capped at 60: cooler and quieter, longer on battery"}];
    [a addObject:@{@"value": @"30", @"label": @"30 FPS", @"note": @"Lightest: for long sessions on battery"}];
    return a;
}
/* The game's own options (Options > Graphics in the game), as its Graphics Rules.sgr sets them: each level is a set
 * of properties, written to its userStartup.cheat at start-up (main.m sims2_prefs, S2_STARTUP). The first choice of
 * each row leaves the game's own setting alone. */
/* levels: {label, note, "prop;prop" (as the rules set them: the cheat file), "key=value" (the game's own saved setting)} */
static NSArray<NSDictionary *> *opt_choices(NSArray *levels)
{
    NSMutableArray *a = [NSMutableArray arrayWithObject:@{@"value": @"", @"label": @"Game's Setting", @"note": @"As set in the game's own Options"}];
    for (NSArray *l in levels) [a addObject:@{@"value": l[2], @"label": l[0], @"note": l[1], @"props": l[3]}];
    return a;
}
static NSArray<NSArray *> *graphics_options(void)   /* {key, title, levels} */
{
    return @[
      @[@"materialDetail", @"Material Detail", @[@[@"High", @"Full textures, bump maps", @"boolProp bumpMapping true;intProp imageDataSizeReductionOnLoad 0", @"optionMaterialDetail=3"],
                                                @[@"Medium", @"Half-size textures", @"boolProp bumpMapping false;intProp imageDataSizeReductionOnLoad 1", @"optionMaterialDetail=2"],
                                                @[@"Low", @"Quarter-size textures", @"boolProp bumpMapping false;intProp imageDataSizeReductionOnLoad 2", @"optionMaterialDetail=1"]]],
      @[@"objectDetail", @"Object Detail", @[@[@"High", @"Full models", @"boolProp reduceBoneWeights false;boolProp useLODs false;intProp lodOverride 0", @"optionObjectDetail=3"],
                                            @[@"Medium", @"Simpler models at a distance", @"boolProp reduceBoneWeights true;boolProp useLODs true;intProp lodOverride 35", @"optionObjectDetail=2"]]],
      @[@"shadows", @"Shadows", @[@[@"High", @"Sims, objects and terrain", @"boolProp simShadows true;boolProp objectShadows true;boolProp guob true;boolProp heightMapShadows true", @"optionShadows=3"],
                                  @[@"Medium", @"Terrain and ground shadows only", @"boolProp simShadows false;boolProp objectShadows false;boolProp guob true;boolProp heightMapShadows true", @"optionShadows=2"],
                                  @[@"Low", @"No shadows", @"boolProp simShadows false;boolProp objectShadows false;boolProp guob false;boolProp heightMapShadows false", @"optionShadows=1"]]],
      @[@"lighting", @"Lighting", @[@[@"High", @"Light through doors and windows, normal maps", @"boolProp lightingEnabled true;boolProp portalLighting true;boolProp floorAndWallNormalMapping true;boolProp specHighlights true", @"optionLightingQuality=3"],
                                    @[@"Medium", @"Without floor and wall normal maps", @"boolProp lightingEnabled true;boolProp portalLighting true;boolProp floorAndWallNormalMapping false;boolProp specHighlights true", @"optionLightingQuality=2"],
                                    @[@"Low", @"Simple lighting", @"boolProp lightingEnabled true;boolProp portalLighting false;boolProp floorAndWallNormalMapping false;boolProp specHighlights false", @"optionLightingQuality=1"]]],
      @[@"effects", @"Effects", @[@[@"High", @"10,000 particles, ocean reflections", @"boolProp useEffects true;intProp maxParticlesTarget 10000;intProp effectPriorityLevel 3;boolProp enableOceanReflection true", @"optionEffectsQuality=3"],
                                  @[@"Medium", @"5,000 particles", @"boolProp useEffects true;intProp maxParticlesTarget 5000;intProp effectPriorityLevel 2;boolProp enableOceanReflection true", @"optionEffectsQuality=2"],
                                  @[@"Low", @"2,000 particles, no ocean reflections", @"boolProp useEffects true;intProp maxParticlesTarget 2000;intProp effectPriorityLevel 1;boolProp enableOceanReflection false", @"optionEffectsQuality=1"]]],
    ];
}
static NSArray<NSArray *> *detail_options(void)
{
    return @[
      @[@"reflections", @"Reflections", @[@[@"On", @"Mirrors and neighbourhood water", @"boolProp reflectionWithExtraViewer true;boolProp nhoodWaterReflection true", @"optionReflection=1"],
                                          @[@"Off", @"Lighter on the GPU", @"boolProp reflectionWithExtraViewer false;boolProp nhoodWaterReflection false", @"optionReflection=0"]]],
      @[@"snow", @"Snow on Ground", @[@[@"On", @"Snow settles in winter", @"boolProp showSnowOnGround true", @"optionSnowOnGround=1"], @[@"Off", @"No snow on the ground", @"boolProp showSnowOnGround false", @"optionSnowOnGround=0"]]],
      @[@"ceilings", @"Ceilings", @[@[@"On", @"Ceilings drawn when walls are up", @"boolProp includeCeilings true", @"optionCeiling=1"], @[@"Off", @"No ceilings", @"boolProp includeCeilings false", @"optionCeiling=0"]]],
      @[@"objectHiding", @"Object Hiding", @[@[@"Off", @"Objects inside walls stay visible", @"intProp renderInsideVisibleObjects 0", @"optionObjectHiding=0"],
                                             @[@"On", @"Hide objects the camera can't see", @"intProp renderInsideVisibleObjects 1", @"optionObjectHiding=1"]]],
      @[@"opaqueUI", @"Opaque Interface", @[@[@"Off", @"The see-through panels", @"boolProp renderOpaqueUI false", @"optionOpaqueUI=0"], @[@"On", @"Solid panels: easier to read", @"boolProp renderOpaqueUI true", @"optionOpaqueUI=1"]]],
    ];
}
static NSArray<NSArray *> *camera_options(void)
{
    return @[
      @[@"edgeScroll", @"Edge Scrolling", @[@[@"On", @"Push the pointer against an edge to move", @"boolProp edgeScrolling true", @"edgeScrolling=true"],
                                            @[@"Off", @"Keys and dragging only", @"boolProp edgeScrolling false", @"edgeScrolling=false"]]],
      @[@"edgeSpeed", @"Edge Scroll Speed", @[@[@"Fast", @"Twice the game's speed", @"floatProp horzedgescrollrate 1;floatProp vertedgescrollrate 1", @"horzedgescrollrate=1;vertedgescrollrate=1"],
                                              @[@"Fastest", @"Four times the game's speed", @"floatProp horzedgescrollrate 2;floatProp vertedgescrollrate 2", @"horzedgescrollrate=2;vertedgescrollrate=2"],
                                              @[@"Normal", @"The game's own speed", @"floatProp horzedgescrollrate 0.5;floatProp vertedgescrollrate 0.5", @"horzedgescrollrate=0.5;vertedgescrollrate=0.5"],
                                              @[@"Slow", @"Half the game's speed", @"floatProp horzedgescrollrate 0.25;floatProp vertedgescrollrate 0.25", @"horzedgescrollrate=0.25;vertedgescrollrate=0.25"]]],
      @[@"driftCam", @"Idle Camera Drift", @[@[@"Off", @"The camera stays where you put it", @"boolProp CameraDriftCamEnabled false", @"CameraDriftCamEnabled=false"],
                                              @[@"On", @"The camera wanders slowly when idle", @"boolProp CameraDriftCamEnabled true", @"CameraDriftCamEnabled=true"]]],
      @[@"eventCam", @"Event Cameras", @[@[@"On", @"The camera follows special events", @"boolProp CameraSpecialEventEnabled true", @"CameraSpecialEventEnabled=true"],
                                         @[@"Off", @"The camera stays put during events", @"boolProp CameraSpecialEventEnabled false", @"CameraSpecialEventEnabled=false"]]],
    ];
}
/* the chosen settings as environment for the game (main.m, the renderer). An environment already set (a terminal) wins. */
static void apply(NSString *res, NSString *ui, NSString *window, NSString *notch, NSString *fps, NSString *startup, NSString *props, NSString *intro, NSString *autosave)
{
    if (!getenv("S2_AUTOSAVE_MIN")) setenv("S2_AUTOSAVE_MIN", autosave.UTF8String, 1);   /* runtime/win32/sims2_imports.c */
    if (!getenv("SIMS2_SKIP_INTRO")) setenv("SIMS2_SKIP_INTRO", [intro isEqualToString:@"skip"] ? "1" : "0", 1);   /* runtime/win32/files.c */
    int W = 0, H = 0, pc = ui.intValue; sscanf(res.UTF8String, "%dx%d", &W, &H);
    if (!getenv("DS_RESOLUTION") && W && H) {
        if (pc > 100) { setenv("DS_RESOLUTION", [NSString stringWithFormat:@"%dx%d", (int)lround(W * 100.0 / pc) & ~1, (int)lround(H * 100.0 / pc) & ~1].UTF8String, 1);
                        setenv("DSR_RENDER_SCALE", [NSString stringWithFormat:@"%g", pc / 100.0].UTF8String, 1); }
        else setenv("DS_RESOLUTION", res.UTF8String, 1);
    }
    if (!getenv("DS_WINDOWED") && [window isEqualToString:@"window"]) setenv("DS_WINDOWED", "1", 1);
    if (!getenv("DS_NOTCH")) setenv("DS_NOTCH", notch.UTF8String, 1);
    if (!getenv("DSR_FPSCAP")) setenv("DSR_FPSCAP", fps.UTF8String, 1);
    if (!getenv("S2_STARTUP")) setenv("S2_STARTUP", startup.UTF8String, 1);
    if (!getenv("S2_PROPS")) setenv("S2_PROPS", props.UTF8String, 1);
}
/* the art: <data>/art, else the copy in the app (Resources/art) */
static NSImage *art(NSString *data, NSString *name)
{
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:[data stringByAppendingPathComponent:@"art"]];
    if (NSBundle.mainBundle.resourcePath) [dirs addObject:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"art"]];
    for (NSString *d in dirs) for (NSString *ext in @[@"png", @"jpg"]) {
        NSImage *i = [[NSImage alloc] initWithContentsOfFile:[[d stringByAppendingPathComponent:name] stringByAppendingPathExtension:ext]];
        if (i.size.width > 16) return i;
    }
    return nil;
}
/* the part of an image with any opacity (Steam's logos come with empty margins), its bottom `cut` share left off */
static NSImage *trimmed(NSImage *img, CGFloat cut)
{
    CGImageRef c = [img CGImageForProposedRect:NULL context:nil hints:nil]; if (!c) return img;
    size_t w = CGImageGetWidth(c), h = CGImageGetHeight(c); uint8_t *px = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB(); CGContextRef g = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(g, CGRectMake(0, 0, w, h), c);
    size_t x0 = w, y0 = h, x1 = 0, y1 = 0;
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) if (px[(y * w + x) * 4 + 3] > 8) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    CGContextRelease(g); CGColorSpaceRelease(cs); free(px);
    if (x1 < x0) return img;
    CGImageRef t = CGImageCreateWithImageInRect(c, CGRectMake(x0, y0, x1 - x0 + 1, (y1 - y0 + 1) * (1 - cut)));   /* bitmap rows run top-down here */
    NSImage *r = [[NSImage alloc] initWithCGImage:t size:NSZeroSize]; CGImageRelease(t);
    return cut > 0 ? trimmed(r, 0) : r;
}


@interface DSBlockTarget : NSObject      /* a button action as a block */
@property (copy) void (^fire)(NSInteger tag);
- (void)clicked:(NSButton *)b;
@end
@implementation DSBlockTarget
- (void)clicked:(NSButton *)b { if (self.fire) self.fire(b.tag); }
@end

// ---------------------------------------------------------------- updates
/* install.sh gives each app an updater (Contents/MacOS/update, passed in DS_UPDATER): it fetches the branch the app
 * follows (main, or nightly for Nightly) from GitHub into a worktree of the checkout the app was installed from and
 * rebuilds the app from it, keeping the game folder, saves and settings. The launcher asks GitHub (in the
 * background, each time it opens) whether that branch moved past the commit the app was built from. */
enum { UPD_NONE, UPD_CHECKING, UPD_CURRENT, UPD_AVAILABLE, UPD_ERROR };
static void on_main(dispatch_block_t b) { CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, b); CFRunLoopWakeUp(CFRunLoopGetMain()); }
static NSString *short_commit(NSString *c) { return c.length > 7 ? [c substringToIndex:7] : (c ?: @""); }
static NSString *update_check(NSString *updater)   /* the newest commit of the branch on GitHub; nil if it can't be reached */
{
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"]; t.arguments = @[updater, @"--check"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ if (t.running) [t terminate]; });
    NSData *d = [p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    NSString *out = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (t.terminationStatus != 0 || !out.length) return nil;
    if (out.length >= 40) return [out substringToIndex:40];   /* a commit (an app built from source) */
    return [out rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound ? out : nil;   /* a release's tag (the downloaded app) */
}
static NSArray<NSDictionary *> *update_choice(int state, NSString *branch, NSString *built, NSString *latest)
{
    NSString *label = @"Not available", *note = @"This copy wasn't installed from the GitHub repository";
    switch (state) {
    case UPD_CHECKING: label = @"Checking..."; note = [NSString stringWithFormat:@"Asking GitHub for the newest %@", branch]; break;
    case UPD_CURRENT: label = @"Up to date"; note = [NSString stringWithFormat:@"%@ %@", branch, short_commit(built)]; break;
    case UPD_AVAILABLE: label = @"Update available"; note = [NSString stringWithFormat:@"%@ -> %@: press to install", short_commit(built), short_commit(latest)]; break;
    case UPD_ERROR: label = @"Couldn't check"; note = @"GitHub unreachable or not signed in: press to retry"; break;
    }
    return @[@{@"value": @"", @"label": label, @"note": note}];
}
/* the phase of install.sh's output, in words */
static NSString *update_phase(NSString *line, NSString *branch)
{
    if ([branch isEqualToString:@"release"]) {   /* the downloaded app's updater (setup/update.sh) */
        if ([line hasPrefix:@"== downloading "]) return [NSString stringWithFormat:@"Downloading %@ from GitHub", [line substringFromIndex:15]];
        if ([line hasPrefix:@"== unpacking"]) return @"Unpacking it";
        if ([line hasPrefix:@"== installing"]) return @"Installing the new app";
        return nil;
    }
    if ([line hasPrefix:@"== fetching"]) return @"Downloading the update from GitHub";
    if ([line hasPrefix:[NSString stringWithFormat:@"== %@:", branch]]) return [@"Got " stringByAppendingString:[line substringFromIndex:branch.length + 4]];
    if ([line hasPrefix:@"== analysis"]) return @"Rebuilding from your game: analysing its code (1 of 4)";
    if ([line hasPrefix:@"== lifting"]) return @"Rebuilding from your game: translating to native code (2 of 4)";
    if ([line hasPrefix:@"== compiling"]) return @"Rebuilding from your game: compiling (3 of 4)";
    if ([line hasPrefix:@"== installing"]) return @"Installing the new app (4 of 4)";
    return nil;
}
/* runs the updater with a progress window (modal); returns YES when the app was rebuilt */
static BOOL update_run(NSWindow *parent, NSString *updater, NSString *branch, NSString *logPath)
{
    NSPanel *pn = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 170) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    pn.title = @"Updating";
    NSTextField *title = [NSTextField labelWithString:@"Updating to the newest version"]; title.font = [NSFont boldSystemFontOfSize:14]; title.frame = NSMakeRect(20, 128, 480, 22);
    NSTextField *status = [NSTextField wrappingLabelWithString:@"Starting..."]; status.frame = NSMakeRect(20, 64, 480, 56);
    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 44, 480, 12)]; spin.indeterminate = YES; [spin startAnimation:nil];
    NSTextField *time = [NSTextField labelWithString:@"This takes a few minutes. Your saves and settings are kept."]; time.font = [NSFont systemFontOfSize:11]; time.textColor = NSColor.secondaryLabelColor; time.frame = NSMakeRect(20, 14, 360, 18);
    NSButton *btn = [NSButton buttonWithTitle:@"Close" target:nil action:nil]; btn.frame = NSMakeRect(400, 8, 100, 30); btn.hidden = YES;
    for (NSView *x in @[title, status, spin, time, btn]) [pn.contentView addSubview:x];
    if (parent) [pn setFrameOrigin:NSMakePoint(NSMidX(parent.frame) - 260, NSMidY(parent.frame) - 85)]; else [pn center];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"]; t.arguments = @[updater];
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe; t.standardError = pipe;
    NSMutableString *pending = [NSMutableString new], *tail = [NSMutableString new];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData; if (!d.length) return;
        [log writeData:d];
        NSString *chunk = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        @synchronized (pending) {
            [pending appendString:chunk];
            NSRange nl;
            while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [pending substringToIndex:nl.location]; [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
                [tail appendFormat:@"%@\n", line]; if (tail.length > 600) [tail deleteCharactersInRange:NSMakeRange(0, tail.length - 600)];
                NSString *ph = update_phase(line, branch);
                if (ph) on_main(^{ status.stringValue = ph; });
            }
        }
    };
    __block BOOL ok = NO;
    __attribute__((objc_precise_lifetime)) DSBlockTarget *bt = [DSBlockTarget new];   /* a button's target is weak: kept here */
    bt.fire = ^(NSInteger tag) { (void)tag; [NSApp stopModal]; };
    btn.target = bt; btn.action = @selector(clicked:);
    t.terminationHandler = ^(NSTask *task) {
        int code = task.terminationStatus;
        on_main(^{
            pipe.fileHandleForReading.readabilityHandler = nil; [log closeFile];
            [spin stopAnimation:nil]; spin.hidden = YES; btn.hidden = NO;
            if (code == 0) { ok = YES; title.stringValue = @"Updated"; status.stringValue = @"The new version is installed. The app restarts when you press Restart."; btn.title = @"Restart"; }
            else {
                NSString *last; @synchronized (pending) { last = [[tail componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "]; }
                title.stringValue = @"The update didn't finish";
                status.stringValue = [NSString stringWithFormat:@"Nothing was changed if it stopped before installing. Details: %@  (%@)", logPath,
                                      last.length > 160 ? [last substringFromIndex:last.length - 160] : last];
                time.stringValue = @"";
            }
        });
    };
    if (![t launchAndReturnError:nil]) { [log closeFile]; return NO; }
    [pn makeKeyAndOrderFront:nil];
    [NSApp runModalForWindow:pn];
    [pn orderOut:nil];
    return ok;
}

/* Shows the launch window (modal) unless DS_NO_LAUNCHER is set; returns 0 to quit. DS_LAUNCHER_SHOT=<png> renders it
 * to an image instead (development; DS_LAUNCHER_OPEN=<group> renders that group's panel open). */
int ds_launcher_run(const char *game_dir, const char *data_dir)
{
    NSString *data = getenv("DS_LAUNCHER_HOME") ? @(getenv("DS_LAUNCHER_HOME")) : @(data_dir), *plistPath = [data stringByAppendingPathComponent:@"launcher.plist"]; (void)game_dir;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:plistPath] ?: @{};
    DSRow *res = [DSRow new], *ui = [DSRow new], *window = [DSRow new], *notch = [DSRow new], *fps = [DSRow new], *intro = [DSRow new], *autosave = [DSRow new];
    intro.title = @"Intro Movies"; intro.choices = @[@{@"value": @"skip", @"label": @"Skip", @"note": @"Straight to loading: about 50 seconds sooner"},
                                                     @{@"value": @"play", @"label": @"Play", @"note": @"The EA logo and the intro, as the game starts"}];
    intro.index = index_of(intro.choices, saved[@"intro"], 0);
    autosave.title = @"Autosave"; autosave.choices = @[@{@"value": @"0", @"label": @"Off", @"note": @"Only your own saves, as the game does"},
                                                       @{@"value": @"10", @"label": @"10 Minutes", @"note": @"Saves every 10 minutes while you play in Live mode"},
                                                       @{@"value": @"20", @"label": @"20 Minutes", @"note": @"Saves every 20 minutes while you play in Live mode"},
                                                       @{@"value": @"30", @"label": @"30 Minutes", @"note": @"Saves every 30 minutes while you play in Live mode"}];
    autosave.index = index_of(autosave.choices, saved[@"autosave"], 0);
    notch.title = @"Notch"; notch.choices = notch_choices(); notch.index = index_of(notch.choices, saved[@"notch"], 0);
    BOOL (^below)(void) = ^BOOL { return ![notch.choices[notch.index][@"value"] isEqualToString:@"around"]; };
    res.title = @"Resolution"; res.choices = resolution_choices(below()); res.index = index_of(res.choices, saved[@"resolution"], res.choices.count > 1 && NSScreen.mainScreen.backingScaleFactor > 1.01 ? 1 : 0);   /* Retina by default */
    ui.title = @"Interface Size"; ui.choices = ui_choices(res.choices[res.index][@"value"]);
    ui.index = index_of(ui.choices, saved[@"interfaceSize"], index_of(ui.choices, res.index == 1 ? @"200" : @"100", 0));   /* Retina: the layout in points by default */
    window.title = @"Window"; window.choices = window_choices(); window.index = index_of(window.choices, saved[@"window"], 0);
    fps.title = @"Frame Rate"; fps.choices = framerate_choices(); fps.index = index_of(fps.choices, saved[@"frameRate"], 0);
    NSMutableArray<DSRow *> *gfx = [NSMutableArray array], *det = [NSMutableArray array], *cam = [NSMutableArray array];
    void (^make)(NSArray *, NSMutableArray *, BOOL) = ^(NSArray *opts, NSMutableArray *into, BOOL gameFirst) {
        for (NSArray *o in opts) { DSRow *r = [DSRow new]; r.title = o[1];
            r.choices = gameFirst ? opt_choices(o[2]) : [opt_choices(o[2]) subarrayWithRange:NSMakeRange(1, [o[2] count])];
            r.index = index_of(r.choices, saved[o[0]], 0); r.key = o[0]; [into addObject:r]; }
    };
    make(graphics_options(), gfx, YES); make(detail_options(), det, YES); make(camera_options(), cam, NO);   /* the camera rows: the port's defaults */
    NSString *(^val)(DSRow *) = ^NSString *(DSRow *r) { return r.choices[r.index][@"value"]; };
    NSString *(^startup)(void) = ^NSString * {
        NSMutableArray *a = [NSMutableArray array];
        for (NSArray *rows in @[gfx, det, cam]) for (DSRow *r in rows) if (val(r).length) [a addObject:val(r)];
        return [a componentsJoinedByString:@";"];
    };
    NSString *(^props)(void) = ^NSString * {
        NSMutableArray *a = [NSMutableArray array];
        for (NSArray *rows in @[gfx, det, cam]) for (DSRow *r in rows) { NSString *p = r.choices[r.index][@"props"]; if (p.length) [a addObject:p]; }
        return [a componentsJoinedByString:@";"];
    };
    void (^finish)(void) = ^{
        NSMutableDictionary *d = [@{@"resolution": val(res), @"interfaceSize": val(ui), @"window": val(window), @"notch": val(notch), @"frameRate": val(fps), @"intro": val(intro), @"autosave": val(autosave)} mutableCopy];
        for (NSArray *rows in @[gfx, det, cam]) for (DSRow *r in rows) d[r.key] = val(r);
        [d writeToFile:plistPath atomically:YES];
        apply(val(res), val(ui), val(window), val(notch), val(fps), startup(), props(), val(intro), val(autosave));
    };
    const char *shot = getenv("DS_LAUNCHER_SHOT");
    if (getenv("DS_NO_LAUNCHER") && !shot) { if (saved.count) apply(val(res), val(ui), val(window), val(notch), val(fps), startup(), props(), val(intro), val(autosave)); return 1; }

    NSString *updater = getenv("DS_UPDATER") ? @(getenv("DS_UPDATER")) : nil, *branch = getenv("DS_UPDATE_BRANCH") ? @(getenv("DS_UPDATE_BRANCH")) : @"main";
    NSString *built = getenv("DS_BUILT_COMMIT") ? @(getenv("DS_BUILT_COMMIT")) : @"";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:updater ?: @""]) updater = nil;
    DSRow *upd = [DSRow new]; upd.title = @"Updates";
    __block int ustate = updater ? UPD_CHECKING : UPD_NONE; __block NSString *latest = nil;
    upd.choices = update_choice(ustate, branch, built, nil);
    BOOL shotMode = shot != NULL;
    DSSection *display = [DSSection new], *graphics = [DSSection new], *detail = [DSSection new], *camera = [DSSection new], *saves = [DSSection new], *updSec = [DSSection new];
    display.title = @"Display"; display.rows = notch_height() > 0 ? @[res, ui, notch, fps, intro, autosave] : @[res, ui, fps, intro, autosave];
    graphics.title = @"Graphics"; graphics.rows = gfx; detail.title = @"Detail"; detail.rows = det; camera.title = @"Camera"; camera.rows = cam;
    NSString *(^chosen)(NSArray<DSRow *> *) = ^NSString *(NSArray<DSRow *> *rows) {   /* the rows that override the game's Options */
        NSMutableArray *a = [NSMutableArray array];
        for (DSRow *r in rows) if (val(r).length) [a addObject:[NSString stringWithFormat:@"%@ %@", r.title, r.choices[r.index][@"label"]]];
        return a.count ? [NSString stringWithFormat:@"Custom · %@", [a componentsJoinedByString:@" · "]] : @"In-Game · As in the game's own Options";
    };
    graphics.summary = ^NSString * { return chosen(gfx); }; detail.summary = ^NSString * { return chosen(det); };
    camera.summary = ^NSString * {   /* the tile: edge scrolling, then the rest */
        DSRow *edge = cam[0]; BOOL on = [val(edge) containsString:@"true"];
        NSMutableArray *a = [NSMutableArray array];
        for (DSRow *r in [cam subarrayWithRange:NSMakeRange(1, cam.count - 1)]) [a addObject:[NSString stringWithFormat:@"%@ %@", r.title, [r.choices[r.index][@"label"] lowercaseString]]];
        return [NSString stringWithFormat:@"%@ · %@", on ? @"Edge Scroll" : @"Keys Only", [a componentsJoinedByString:@" · "]];
    };
    saves.title = @"Saves";
    updSec.title = @"Updates"; updSec.summary = ^NSString * { NSDictionary *c = upd.choices[upd.index]; return [c[@"note"] length] ? [NSString stringWithFormat:@"%@ · %@", c[@"label"], c[@"note"]] : c[@"label"]; };
    DSLaunchView *v = [[DSLaunchView alloc] initWithFrame:NSMakeRect(0, 0, 980, 660)];
    v.top = @[window]; v.sections = @[display, graphics, detail, camera, updSec]; v.open = -1; v.hover = v.pressed = HIT_NONE; v.focus = 0;
    v.note = @"Sound and the rest: in the game's own Options. Pinch or scroll to zoom.";
    __block BOOL wasBelow = below(); __block NSString *wasRes = val(res);
    v.onChange = ^{
        if (below() != wasBelow) { NSString *cur = val(res); wasBelow = below(); res.choices = resolution_choices(wasBelow); res.index = index_of(res.choices, cur, 0); }
        NSString *keep = [val(res) isEqualToString:wasRes] ? val(ui) : (res.index == 1 ? @"200" : @"100");   /* a new resolution: its usual size */
        wasRes = val(res); ui.choices = ui_choices(wasRes); ui.index = index_of(ui.choices, keep, 0);
    };
    __weak DSLaunchView *wv = v; __weak DSRow *wu = upd;
    saves.activate = ^{
        NSString *dir = [data stringByAppendingPathComponent:@"drive_c/Users/player/Documents/EA Games/The Sims 2 Legacy"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            NSAlert *a = [NSAlert new]; a.messageText = @"No saves yet";
            a.informativeText = @"The game makes its folder the first time it starts. Press Play, then come back here."; [a runModal]; return;
        }
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
    };
    updSec.activate = ^{ if (wu.activate) wu.activate(); };
    v.onSaves = ^{ if (saves.activate) saves.activate(); };   /* the game's neighbourhoods, in Finder */
    v.onFiles = ^{ [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@(game_dir)]]; };
    void (^check)(void) = ^{
        if (!updater) return;
        ustate = UPD_CHECKING; wu.choices = update_choice(ustate, branch, built, nil); wv.needsDisplay = YES;
        void (^done)(NSString *) = ^(NSString *l) {
            latest = l; ustate = !l ? UPD_ERROR : [l isEqualToString:built] ? UPD_CURRENT : UPD_AVAILABLE;
            wu.choices = update_choice(ustate, branch, built, l); wv.needsDisplay = YES;
        };
        if (shotMode) { done(update_check(updater)); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ NSString *l = update_check(updater); on_main(^{ done(l); }); });
    };
    check();
    upd.activate = ^{
        if (ustate == UPD_CHECKING) return;
        if (ustate != UPD_AVAILABLE) { check(); return; }
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Update to the newest %@?", [branch isEqualToString:@"nightly"] ? @"Nightly" : @"version"];
        a.informativeText = [branch isEqualToString:@"release"] ? [NSString stringWithFormat:@"%@ is downloaded from GitHub and replaces this app. Your game, saves and settings are kept; if the game's code changed, it is rebuilt from your copy when the app starts again.", latest]
                          : [NSString stringWithFormat:@"The %@ branch (%@) is downloaded from GitHub and the app is rebuilt from your own copy of the game, "
                             "which takes a few minutes. Your game folder, neighbourhoods and settings are kept. The app restarts when it is done.", branch, short_commit(latest)];
        [a addButtonWithTitle:@"Update"]; [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        NSString *logPath = [data stringByAppendingPathComponent:@"update.log"];
        if (update_run(wv.window, updater, branch, logPath)) {
            NSString *app = [[[updater stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            NSTask *o = [NSTask new]; o.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"]; o.arguments = @[@"-n", app];
            [o launchAndReturnError:nil]; [o waitUntilExit];
            exit(0);
        }
        check();
    };
    NSImage *logo = art(data, @"logo"); v.logo = logo ? trimmed(logo, 0) : nil;
    {   /* the slides: the intro's frames and the store's screenshots in turn, the library banner; the capsule framed */
        NSMutableArray<NSImage *> *sc = [NSMutableArray array];
        NSImage *hero = ready(art(data, @"shot"), 1920), *bd = ready(art(data, @"backdrop"), 1600);
        for (int k = 1; k <= 8; k++) {
            NSImage *i = ready(art(data, [NSString stringWithFormat:@"intro-%d", k]), 1280), *s2 = ready(art(data, [NSString stringWithFormat:@"slide-%d", k]), 1920);
            if (i) [sc addObject:i]; if (s2) [sc addObject:s2]; if (k == 2 && hero) [sc addObject:hero];
        }
        if (!sc.count) { if (hero) [sc addObject:hero]; if (bd) [sc addObject:bd]; }
        v.scenes = sc;
        NSImage *pt = ready(art(data, @"portrait"), 900);
        if (pt) { v.portrait = pt; v.portraitFx = 0.5; v.portraitFy = 0.9; v.portraitZ = 1.0; }
        else if (hero) { v.portrait = hero; v.portraitFx = 0.5; v.portraitFy = 0.5; v.portraitZ = 1.0; }
        NSImage *win = ready(art(data, @"slide-2"), 1920) ?: ready(art(data, @"intro-5"), 1280);
        v.cards = @[hero ?: sc.firstObject ?: (id)NSNull.null, win ?: sc.lastObject ?: (id)NSNull.null];   /* Full Screen, Window */
    }
    if (shot) {   /* development: the window as an image, twice its size */
        const char *open = getenv("DS_LAUNCHER_OPEN");
        if (open) for (NSInteger i = 0; i < (NSInteger)v.sections.count; i++) if ([v.sections[i].title caseInsensitiveCompare:@(open)] == NSOrderedSame) { v.open = i; v.focus = 0; }
        if (getenv("DS_LAUNCHER_FOCUS")) { v.focus = atoi(getenv("DS_LAUNCHER_FOCUS")); v.keyed = YES; }
        if (getenv("DS_LAUNCHER_STARTING")) v.starting = YES;
        v.t = getenv("DS_LAUNCHER_TIME") ? atof(getenv("DS_LAUNCHER_TIME")) : 4.0;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)v.bounds.size.width * 2 pixelsHigh:(NSInteger)v.bounds.size.height * 2
                                                                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size = v.bounds.size;
        [v displayRectIgnoringOpacity:v.bounds inContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(shot) atomically:YES];
        if (getenv("DS_LAUNCHER_APPLY")) { finish(); printf("DS_RESOLUTION=%s DSR_RENDER_SCALE=%s S2_STARTUP=%s S2_PROPS=%s\n", getenv("DS_RESOLUTION") ?: "-", getenv("DSR_RENDER_SCALE") ?: "-", getenv("S2_STARTUP") ?: "-", getenv("S2_PROPS") ?: "-"); }
        return 0;
    }

    NSWindow *w = [[NSWindow alloc] initWithContentRect:v.frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO;
    w.titlebarAppearsTransparent = YES; w.titleVisibility = NSWindowTitleHidden; w.movableByWindowBackground = YES; w.title = @DS2_TITLE;
    w.backgroundColor = NSColor.blackColor; w.contentView = v; [w center]; [w makeFirstResponder:v];
    __block int result = 0;
    v.onPlay = ^{ result = 1; [NSApp stopModal]; };
    v.onQuit = ^{ result = 0; [NSApp stopModal]; };
    id closeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:w queue:nil usingBlock:^(NSNotification *n) { (void)n; [NSApp stopModal]; }];
    [NSApp activateIgnoringOtherApps:YES];
    [w makeKeyAndOrderFront:nil];
    /* the animation, 60 times a second (in the modal loop's mode too, and on while the game starts); a controller: the
     * d-pad or the left stick moves (held: repeats), A chooses, B goes back, Start plays */
    double t0 = CACurrentMediaTime(); __block int held = 0; __block double next = 0; __block uint32_t was = 0;
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    NSTimer *anim = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *tm) {
        DSLaunchView *sv = wv; if (!sv) { [tm invalidate]; return; }
        double t = sv.t = CACurrentMediaTime() - t0;
        GCExtendedGamepad *g = (GCController.current ?: GCController.controllers.firstObject).extendedGamepad;
        if (g && NSApp.active && sv.window.isKeyWindow && !sv.starting) {
            float x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value;
            int dir = g.dpad.left.pressed || x < -0.6f ? NAV_LEFT : g.dpad.right.pressed || x > 0.6f ? NAV_RIGHT
                    : g.dpad.up.pressed || y > 0.6f ? NAV_UP : g.dpad.down.pressed || y < -0.6f ? NAV_DOWN : 0;
            if (dir != held) { held = dir; next = t + 0.38; if (dir) [sv nav:dir]; }
            else if (dir && t >= next) { next = t + 0.14; [sv nav:dir]; }
            uint32_t now = (g.buttonA.pressed ? 1u : 0) | (g.buttonB.pressed ? 2u : 0) | (g.buttonMenu.pressed ? 4u : 0), down = now & ~was; was = now;
            if (down & 1) [sv nav:NAV_OK]; else if (down & 2) [sv nav:NAV_BACK]; else if (down & 4) [sv nav:NAV_PLAY];
        } else { held = 0; was = 0; }
        sv.needsDisplay = YES;
        static double lastT; if (getenv("DS_LAUNCHER_TIMING") && t - lastT >= 1) {   /* development: frames a second, then quits after 6 */
            fprintf(stderr, "fps: %.0f\n", frames_drawn / (t - lastT)); frames_drawn = 0; lastT = t; if (t > 6 && !sv.starting) [NSApp stopModal]; }
    }];
    [[NSRunLoop currentRunLoop] addTimer:anim forMode:NSRunLoopCommonModes]; launch_anim = anim;
    if (getenv("DS_LAUNCHER_PLAY"))   /* testing: Play after a moment, as if clicked */
        [[NSRunLoop currentRunLoop] addTimer:[NSTimer timerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *tm) { if (wv.onPlay) wv.onPlay(); }] forMode:NSRunLoopCommonModes];
    [NSApp runModalForWindow:w];
    [[NSNotificationCenter defaultCenter] removeObserver:closeObserver];
    if (!result) { [anim invalidate]; launch_anim = nil; [w orderOut:nil]; return 0; }
    v.starting = YES; v.open = -1; v.onPlay = nil; v.onQuit = nil; v.onChange = nil;
    [w standardWindowButton:NSWindowCloseButton].enabled = NO;
    v.needsDisplay = YES; [w displayIfNeeded]; launch_window = w;
    finish();
    return 1;
}
