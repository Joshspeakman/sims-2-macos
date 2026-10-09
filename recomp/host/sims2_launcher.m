// The Sims 2's launch window, laid out like the other ports' (The Sims, Dungeon Siege, Diablo II, Delta Force): a banner
// (the game's logo over its art), the Resolution row, and a button for each group of settings (Display, Graphics,
// Camera, Saves, Updates) that opens it as a panel. Choices are remembered in <data>/launcher.plist and passed to the
// game as environment (main.m, the renderer, runtime/win32/sims2_options.c). The art is fetched at install time
// (tools/sims2_art.py: the logo, background and banner from the game's Steam store page) into <data>/art and a copy in
// the app; nothing from the game is stored in this project, and without the art the window writes the title.
#import <AppKit/AppKit.h>
#include "../runtime/edition.h"

// ---------------------------------------------------------------- settings
@interface DSRow : NSObject
@property NSString *title, *key; @property NSArray<NSDictionary *> *choices; @property NSInteger index;
@property (copy) void (^activate)(void);     /* a row that runs something instead of cycling (Updates) */
@end
@implementation DSRow @end

/* The Sims' own interface: blue panels, white text, the plumbob's green for what is chosen */
static NSColor *accent(void) { return [NSColor colorWithSRGBRed:0.55 green:0.92 blue:0.38 alpha:1]; }
static NSColor *accent_dim(void) { return [NSColor colorWithSRGBRed:0.20 green:0.42 blue:0.85 alpha:1]; }
static NSColor *panel_blue(void) { return [NSColor colorWithSRGBRed:0.05 green:0.12 blue:0.42 alpha:0.88]; }
static NSColor *text_c(void) { return [NSColor colorWithSRGBRed:0.93 green:0.93 blue:0.88 alpha:1]; }
static NSColor *dim(void) { return [NSColor colorWithSRGBRed:0.66 green:0.66 blue:0.6 alpha:1]; }
static NSFont *din(CGFloat size)                    /* the system's rounded face, bold */
{
    NSFont *f = [NSFont systemFontOfSize:size weight:NSFontWeightBold];
    NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return d ? [NSFont fontWithDescriptor:d size:size] : f;
}
static NSFont *body(CGFloat size, BOOL bold)
{
    NSFont *f = [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
    NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return d ? [NSFont fontWithDescriptor:d size:size] : f;
}

// ---------------------------------------------------------------- the view
/* A group's button opens it as a panel over the window, with Back where Quit was; Key Guide and Updates run their own. */
@interface DSSection : NSObject
@property NSString *title; @property NSArray<DSRow *> *rows;
@property (copy) void (^activate)(void); @property (copy) NSString *(^summary)(void);
@end
@implementation DSSection @end

@interface DSLaunchView : NSView
@property NSArray<DSRow *> *top; @property NSArray<DSSection *> *sections; @property NSInteger open;   /* the open group, -1 none */
@property NSInteger focus; @property NSInteger hover; @property NSInteger pressed;
@property NSImage *backdrop, *logo, *shot; @property NSString *note;
@property (copy) void (^onPlay)(void); @property (copy) void (^onQuit)(void); @property (copy) void (^onChange)(void);
@end

enum { HIT_NONE = -1, HIT_PLAY = 100, HIT_QUIT = 101, HIT_BACK = 102, HIT_SECTION = 200 };   /* rows: 10*row + 0 (left arrow) / 1 (value) / 2 (right arrow) */
enum { BANNER_H = 252, TOP_Y = 270 };

@implementation DSLaunchView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (NSArray<DSRow *> *)rows { return self.open >= 0 ? self.sections[self.open].rows : self.top; }
- (NSInteger)items { return (NSInteger)self.rows.count + (self.open >= 0 ? 0 : (NSInteger)self.sections.count); }   /* what the keyboard moves between */
- (NSRect)flyRect   /* an open group's panel: above Back and Play */
{
    NSRect b = self.bounds; CGFloat h = b.size.height - 268, need = 80 + 74 * (CGFloat)(self.open >= 0 ? self.sections[self.open].rows.count : 0);
    CGFloat grow = MIN(MAX(need - h, 0), 60);
    return NSMakeRect(40, 168 - grow, b.size.width - 80, h + grow);
}
- (NSRect)rowRect:(NSInteger)k { CGFloat y = self.open >= 0 ? self.flyRect.origin.y + 70 : TOP_Y + 14; return NSMakeRect(70, y + 74 * k, self.bounds.size.width - 140, 64); }
- (NSRect)arrow:(NSInteger)k right:(BOOL)right { NSRect r = [self rowRect:k]; return NSMakeRect(right ? NSMaxX(r) - 34 : NSMaxX(r) - 330, r.origin.y + 6, 30, 30); }
- (NSRect)valueRect:(NSInteger)k { NSRect r = [self rowRect:k]; return NSMakeRect(NSMaxX(r) - 300, r.origin.y + 7, 262, 30); }
- (NSRect)sectionRect:(NSInteger)i
{
    NSInteger n = (NSInteger)self.sections.count, per = 2, line = i / per, inLine = MIN(per, n - line * per), col = i % per;
    CGFloat w = 290, g = 28, x0 = (self.bounds.size.width - (inLine * w + (inLine - 1) * g)) / 2;
    return NSMakeRect(x0 + col * (w + g), TOP_Y + 74 * self.top.count + 44 + line * 100, w, 54);
}
- (NSRect)playRect { NSRect b = self.bounds; return NSMakeRect(NSMidX(b) + 12, b.size.height - 80, 220, 52); }
- (NSRect)quitRect { NSRect b = self.bounds; return NSMakeRect(NSMidX(b) - 232, b.size.height - 80, 220, 52); }
- (NSInteger)hit:(NSPoint)p
{
    if (NSPointInRect(p, self.playRect)) return HIT_PLAY;
    if (NSPointInRect(p, self.quitRect)) return self.open >= 0 ? HIT_BACK : HIT_QUIT;
    if (self.open < 0) for (NSInteger i = 0; i < (NSInteger)self.sections.count; i++) if (NSPointInRect(p, [self sectionRect:i])) return HIT_SECTION + i;
    for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
        if (NSPointInRect(p, [self arrow:k right:NO])) return 10 * k;
        if (NSPointInRect(p, [self arrow:k right:YES])) return 10 * k + 2;
        if (NSPointInRect(p, [self valueRect:k])) return 10 * k + 1;
    }
    if (self.open >= 0 && !NSPointInRect(p, self.flyRect)) return HIT_BACK;   /* a click outside the panel closes it */
    return HIT_NONE;
}
- (void)openSection:(NSInteger)i
{
    DSSection *s = self.sections[i]; self.focus = (NSInteger)self.top.count + i;
    if (s.activate) { s.activate(); self.needsDisplay = YES; return; }
    self.open = i; self.focus = 0; self.hover = HIT_NONE; self.needsDisplay = YES;
}
- (void)closeSection { if (self.open < 0) return; self.focus = (NSInteger)self.top.count + self.open; self.open = -1; self.hover = HIT_NONE; self.needsDisplay = YES; }
- (void)updateTrackingAreas
{
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e { NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != self.hover) { self.hover = h; self.needsDisplay = YES; } }
- (void)mouseDown:(NSEvent *)e { self.pressed = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; self.needsDisplay = YES; }
- (void)mouseUp:(NSEvent *)e
{
    NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]], p = self.pressed; self.pressed = HIT_NONE; self.needsDisplay = YES;
    if (h != p || h == HIT_NONE) return;
    if (h == HIT_PLAY) { if (self.onPlay) self.onPlay(); return; }
    if (h == HIT_QUIT) { if (self.onQuit) self.onQuit(); return; }
    if (h == HIT_BACK) { [self closeSection]; return; }
    if (h >= HIT_SECTION) { [self openSection:h - HIT_SECTION]; return; }
    NSInteger k = h / 10; self.focus = k;
    if (self.rows[k].activate) { self.rows[k].activate(); self.needsDisplay = YES; return; }
    [self step:k by:(h % 10 == 0) ? -1 : 1];
}
- (void)step:(NSInteger)k by:(NSInteger)dir
{
    if (k >= (NSInteger)self.rows.count) { NSInteger n = [self items]; self.focus = (self.focus + dir + n) % n; self.needsDisplay = YES; return; }   /* the group buttons */
    DSRow *r = self.rows[k]; NSInteger n = (NSInteger)r.choices.count;
    if (r.activate) { r.activate(); self.needsDisplay = YES; return; }
    r.index = (r.index + dir + n) % n; self.needsDisplay = YES;
    if (self.onChange) self.onChange();
}
- (void)keyDown:(NSEvent *)e
{
    NSInteger n = [self items], rc = (NSInteger)self.rows.count;
    switch (e.keyCode) {
    case 0x24: case 0x4c:                                                /* Return, Enter */
        if (self.focus >= rc) { [self openSection:self.focus - rc]; return; }
        if (self.rows[self.focus].activate) { self.rows[self.focus].activate(); self.needsDisplay = YES; return; }
        if (self.open >= 0) { [self closeSection]; return; }
        if (self.onPlay) self.onPlay(); return;
    case 0x35: if (self.open >= 0) { [self closeSection]; return; }      /* Escape */
               if (self.onQuit) self.onQuit(); return;
    case 0x7e: self.focus = (self.focus + n - 1) % n; self.needsDisplay = YES; return;
    case 0x7d: self.focus = (self.focus + 1) % n; self.needsDisplay = YES; return;
    case 0x7b: [self step:self.focus by:-1]; return;
    case 0x7c: [self step:self.focus by:1]; return;
    }
    [super keyDown:e];
}
static void draw_text(NSString *s, NSFont *f, NSColor *c, NSRect r, NSTextAlignment al, NSShadow *sh, CGFloat kern)
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = al; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *a = [@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps, NSKernAttributeName: @(kern)} mutableCopy];
    if (sh) a[NSShadowAttributeName] = sh;
    [s drawInRect:r withAttributes:a];
}
/* (the other ports frame panels with corner marks; The Sims' are plain rounded rectangles) */
static void brackets(NSRect r, CGFloat len, CGFloat w, NSColor *c) { (void)r; (void)len; (void)w; (void)c; }
static void fill_over(NSRect r) { NSRectFillUsingOperation(r, NSCompositingOperationSourceOver); }
- (void)drawButton:(NSRect)r title:(NSString *)title code:(NSInteger)code primary:(BOOL)primary
{
    BOOL hot = self.hover == code, down = self.pressed == code;
    NSColor *fill = down ? [accent() colorWithAlphaComponent:0.55] : hot ? [accent_dim() colorWithAlphaComponent:0.95] : primary ? [NSColor colorWithSRGBRed:0.22 green:0.62 blue:0.22 alpha:0.95] : panel_blue();
    [fill setFill]; [[NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.height / 2 yRadius:r.size.height / 2] fill];
    [[NSColor colorWithWhite:1 alpha:primary || hot ? 0.95 : 0.6] setStroke]; NSBezierPath *b = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1) xRadius:r.size.height / 2 - 1 yRadius:r.size.height / 2 - 1]; b.lineWidth = 2; [b stroke];
    brackets(NSInsetRect(r, -4, -4), 10, 2, primary || hot ? accent() : accent_dim());
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; sh.shadowOffset = NSMakeSize(0, -1.5); sh.shadowBlurRadius = 2;
    NSFont *f = din(primary ? 30 : 26); NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: hot || primary ? NSColor.whiteColor : text_c(), NSShadowAttributeName: sh, NSKernAttributeName: @4};
    NSSize sz = [title sizeWithAttributes:at];   /* the capitals centred on the button */
    [title drawAtPoint:NSMakePoint(NSMidX(r) - sz.width / 2, round(NSMidY(r) + f.capHeight / 2 - f.ascender)) withAttributes:at];
}
- (void)drawArrow:(NSRect)r right:(BOOL)right lit:(BOOL)lit
{
    NSBezierPath *p = [NSBezierPath bezierPath]; CGFloat x0 = r.origin.x + 9, x1 = NSMaxX(r) - 9, y0 = r.origin.y + 7, y1 = NSMaxY(r) - 7, ym = NSMidY(r);
    if (right) { [p moveToPoint:NSMakePoint(x0, y0)]; [p lineToPoint:NSMakePoint(x1, ym)]; [p lineToPoint:NSMakePoint(x0, y1)]; }
    else { [p moveToPoint:NSMakePoint(x1, y0)]; [p lineToPoint:NSMakePoint(x0, ym)]; [p lineToPoint:NSMakePoint(x1, y1)]; }
    [p closePath]; [(lit ? NSColor.whiteColor : accent()) setFill]; [p fill];
}
- (void)drawRows:(NSShadow *)sh
{
    for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
        DSRow *row = self.rows[k]; NSRect r = [self rowRect:k]; NSDictionary *ch = row.choices[row.index];
        if (k == self.focus) { [[NSColor colorWithWhite:1 alpha:0.08] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, -10, -2) xRadius:10 yRadius:10] fill]; }
        draw_text(row.title, din(22), NSColor.whiteColor, NSMakeRect(r.origin.x + 4, r.origin.y + 10, 300, 30), NSTextAlignmentLeft, sh, 2);
        [self drawArrow:[self arrow:k right:NO] right:NO lit:self.hover == 10 * k];
        [self drawArrow:[self arrow:k right:YES] right:YES lit:self.hover == 10 * k + 2];
        draw_text(ch[@"label"], body(20, YES), self.hover == 10 * k + 1 ? NSColor.whiteColor : text_c(), [self valueRect:k], NSTextAlignmentCenter, sh, 0.5);
        draw_text(ch[@"note"] ?: @"", body(12.5, NO), dim(), NSMakeRect(NSMaxX(r) - 340, r.origin.y + 40, 350, 18), NSTextAlignmentCenter, nil, 0);
        if (k + 1 < (NSInteger)self.rows.count) { [[accent_dim() colorWithAlphaComponent:0.35] setFill]; fill_over(NSMakeRect(r.origin.x, NSMaxY(r) + 5, r.size.width, 1)); }
    }
}
- (void)drawPanel:(NSRect)panel
{
    [panel_blue() setFill]; [[NSBezierPath bezierPathWithRoundedRect:panel xRadius:14 yRadius:14] fill];
    [[NSColor colorWithWhite:1 alpha:0.5] setStroke]; NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(panel, 1, 1) xRadius:13 yRadius:13]; bp.lineWidth = 2; [bp stroke];
    brackets(NSInsetRect(panel, -5, -5), 18, 2.5, accent());
}
/* an image filling a rectangle, its aspect kept (cropped), at the given share of its own centre */
static void draw_cover(NSImage *img, NSRect r, CGFloat fraction)
{
    NSSize is = img.size; CGFloat sc = MAX(r.size.width / is.width, r.size.height / is.height), w = r.size.width / sc, h = r.size.height / sc;
    [img drawInRect:r fromRect:NSMakeRect((is.width - w) / 2, (is.height - h) / 2, w, h) operation:NSCompositingOperationSourceOver fraction:fraction
     respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}
- (void)drawBanner:(NSRect)br shadow:(NSShadow *)sh
{
    [NSColor.blackColor setFill]; NSRectFill(br);
    if (self.backdrop) draw_cover(self.backdrop, br, 1);
    if (self.shot) {   /* the screenshot on the right, fading into the background towards the logo */
        NSRect sr = NSMakeRect(br.size.width * 0.38, 0, br.size.width * 0.62, br.size.height);
        NSImage *layer = [NSImage imageWithSize:sr.size flipped:YES drawingHandler:^BOOL(NSRect dst) {
            draw_cover(self.shot, dst, 1);
            NSGradient *fade = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0 alpha:1], 0.0, [NSColor colorWithWhite:0 alpha:0.6], 0.25, [NSColor colorWithWhite:0 alpha:0], 0.55, nil];
            [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationDestinationOut];
            [fade drawInRect:dst angle:0];
            return YES;
        }];
        [layer drawInRect:sr fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    NSGradient *shade = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0 alpha:0.45], 0.0, [NSColor colorWithWhite:0 alpha:0.05], 0.5, [NSColor colorWithWhite:0 alpha:0.15], 1.0, nil];
    [shade drawInRect:br angle:0];
    /* the logo on the left, the subtitle under it */
    NSRect lr = NSMakeRect(28, 16, 300, 186);
    if (self.logo) {
        CGFloat h = lr.size.height, w = h * self.logo.size.width / self.logo.size.height; if (w > lr.size.width) { w = lr.size.width; h = w * self.logo.size.height / self.logo.size.width; }
        NSShadow *glow = [NSShadow new]; glow.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; glow.shadowOffset = NSZeroSize; glow.shadowBlurRadius = 14;
        [NSGraphicsContext saveGraphicsState]; [glow set];
        [self.logo drawInRect:NSMakeRect(NSMidX(lr) - w / 2, lr.origin.y + (lr.size.height - h) / 2, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
    }
    else draw_text(@"THE SIMS 2", din(54), NSColor.whiteColor, NSMakeRect(lr.origin.x - 20, 70, lr.size.width + 40, 64), NSTextAlignmentCenter, sh, 6);
    draw_text(@"NATIVE EDITION FOR macOS", din(15), NSColor.whiteColor, NSMakeRect(lr.origin.x - 20, NSMaxY(lr) + 8, lr.size.width + 40, 22), NSTextAlignmentCenter, sh, 4);
    NSGradient *fade = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:0] endingColor:[NSColor colorWithWhite:0 alpha:0.85]];
    [fade drawInRect:NSMakeRect(0, BANNER_H - 36, br.size.width, 36) angle:90];
    [accent_dim() setFill]; NSRectFill(NSMakeRect(0, BANNER_H, br.size.width, 1.5));
}
- (void)drawRect:(NSRect)dirty
{
    NSRect b = self.bounds;
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; sh.shadowOffset = NSMakeSize(0, -1); sh.shadowBlurRadius = 3;
    [[NSColor colorWithWhite:0.04 alpha:1] setFill]; NSRectFill(b);
    if (self.backdrop) draw_cover(self.backdrop, b, 0.55);              /* the game's texture, darker below the banner */
    NSGradient *vig = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0 alpha:0.25], 0.0, [NSColor colorWithWhite:0 alpha:0.75], 1.0, nil];
    [vig drawInRect:b relativeCenterPosition:NSMakePoint(0, -0.1)];
    [self drawBanner:NSMakeRect(0, 0, b.size.width, BANNER_H) shadow:sh];
    /* the top level: the Controls row, then a button for each group with a summary under it */
    NSInteger fly = self.open, foc = self.focus, hov = self.hover; self.open = -1;
    if (fly >= 0) self.focus = self.hover = HIT_NONE;           /* under the panel: nothing lit */
    [self drawPanel:NSMakeRect(54, TOP_Y, b.size.width - 108, 74 * self.top.count + 14)];
    [self drawRows:sh];
    for (NSInteger i = 0; i < (NSInteger)self.sections.count; i++) {
        DSSection *s = self.sections[i]; NSRect r = [self sectionRect:i]; NSInteger code = HIT_SECTION + i;
        if (fly < 0 && self.focus == (NSInteger)self.top.count + i) { [[accent() colorWithAlphaComponent:0.35] setFill]; NSRect g = NSInsetRect(r, -6, -6); [[NSBezierPath bezierPathWithRoundedRect:g xRadius:g.size.height / 2 yRadius:g.size.height / 2] fill]; }
        [self drawButton:r title:s.title.uppercaseString code:code primary:NO];
        NSString *sum = s.summary ? s.summary() : nil;
        if (!sum) { NSMutableArray *l = [NSMutableArray array]; for (DSRow *row in s.rows) [l addObject:row.choices[row.index][@"label"]]; sum = [l componentsJoinedByString:@" · "]; }
        draw_text(sum, body(12.5, NO), dim(), NSMakeRect(r.origin.x - 10, NSMaxY(r) + 8, r.size.width + 20, 32), NSTextAlignmentCenter, sh, 0);
    }
    if (self.note.length) draw_text(self.note, body(12.5, NO), dim(), NSMakeRect(54, [self sectionRect:(NSInteger)self.sections.count - 1].origin.y + 98, b.size.width - 108, 34), NSTextAlignmentCenter, sh, 0);
    self.open = fly; self.focus = foc; self.hover = hov;
    /* an open group: a panel over the window */
    if (self.open >= 0) {
        [[NSColor colorWithWhite:0 alpha:0.6] setFill]; fill_over(b);
        NSRect f = self.flyRect;
        [[NSColor colorWithSRGBRed:0.04 green:0.09 blue:0.32 alpha:1] setFill]; [[NSBezierPath bezierPathWithRoundedRect:f xRadius:18 yRadius:18] fill];
        [[NSColor colorWithWhite:1 alpha:0.55] setStroke]; NSBezierPath *fp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(f, 1, 1) xRadius:17 yRadius:17]; fp.lineWidth = 2; [fp stroke];
        brackets(NSInsetRect(f, -5, -5), 22, 3, accent());
        draw_text(self.sections[self.open].title, din(28), NSColor.whiteColor, NSMakeRect(f.origin.x, f.origin.y + 20, f.size.width, 36), NSTextAlignmentCenter, sh, 5);
        [[accent_dim() colorWithAlphaComponent:0.6] setFill]; fill_over(NSMakeRect(f.origin.x + 30, f.origin.y + 60, f.size.width - 60, 1));
        [self drawRows:sh];
    }
    [self drawButton:self.quitRect title:self.open >= 0 ? @"BACK" : @"QUIT" code:self.open >= 0 ? HIT_BACK : HIT_QUIT primary:NO];
    [self drawButton:self.playRect title:@"PLAY" code:HIT_PLAY primary:YES];
}
@end

// ---------------------------------------------------------------- choices, settings file, the window
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
    add(W, H, @"This display (recommended): smooth at full frame rate");
    if (sc > 1.01) add((int)(W * sc + 0.5), (int)(H * sc + 0.5), @"Retina: every pixel; sharpest, about half the frame rate");
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
             @{@"value": @"around", @"label": @"Around the Notch", @"note": @"The whole display; the notch covers a little of the top"}];
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
static void apply(NSString *res, NSString *ui, NSString *window, NSString *notch, NSString *fps, NSString *startup, NSString *props, NSString *intro)
{
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
    return t.terminationStatus == 0 && out.length >= 40 ? [out substringToIndex:40] : nil;
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
    NSString *data = @(data_dir), *plistPath = [data stringByAppendingPathComponent:@"launcher.plist"]; (void)game_dir;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:plistPath] ?: @{};
    DSRow *res = [DSRow new], *ui = [DSRow new], *window = [DSRow new], *notch = [DSRow new], *fps = [DSRow new], *intro = [DSRow new];
    intro.title = @"Intro Movies"; intro.choices = @[@{@"value": @"skip", @"label": @"Skip", @"note": @"Straight to loading: about 50 seconds sooner"},
                                                     @{@"value": @"play", @"label": @"Play", @"note": @"The EA logo and the intro, as the game starts"}];
    intro.index = index_of(intro.choices, saved[@"intro"], 0);
    notch.title = @"Notch"; notch.choices = notch_choices(); notch.index = index_of(notch.choices, saved[@"notch"], 0);
    BOOL (^below)(void) = ^BOOL { return ![notch.choices[notch.index][@"value"] isEqualToString:@"around"]; };
    res.title = @"Resolution"; res.choices = resolution_choices(below()); res.index = index_of(res.choices, saved[@"resolution"], 0);
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
        NSMutableDictionary *d = [@{@"resolution": val(res), @"interfaceSize": val(ui), @"window": val(window), @"notch": val(notch), @"frameRate": val(fps), @"intro": val(intro)} mutableCopy];
        for (NSArray *rows in @[gfx, det, cam]) for (DSRow *r in rows) d[r.key] = val(r);
        [d writeToFile:plistPath atomically:YES];
        apply(val(res), val(ui), val(window), val(notch), val(fps), startup(), props(), val(intro));
    };
    const char *shot = getenv("DS_LAUNCHER_SHOT");
    if (getenv("DS_NO_LAUNCHER") && !shot) { if (saved.count) apply(val(res), val(ui), val(window), val(notch), val(fps), startup(), props(), val(intro)); return 1; }

    NSString *updater = getenv("DS_UPDATER") ? @(getenv("DS_UPDATER")) : nil, *branch = getenv("DS_UPDATE_BRANCH") ? @(getenv("DS_UPDATE_BRANCH")) : @"main";
    NSString *built = getenv("DS_BUILT_COMMIT") ? @(getenv("DS_BUILT_COMMIT")) : @"";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:updater ?: @""]) updater = nil;
    DSRow *upd = [DSRow new]; upd.title = @"Updates";
    __block int ustate = updater ? UPD_CHECKING : UPD_NONE; __block NSString *latest = nil;
    upd.choices = update_choice(ustate, branch, built, nil);
    BOOL shotMode = shot != NULL;
    DSSection *display = [DSSection new], *graphics = [DSSection new], *detail = [DSSection new], *camera = [DSSection new], *saves = [DSSection new], *updSec = [DSSection new];
    display.title = @"Display"; display.rows = notch_height() > 0 ? @[ui, window, notch, fps, intro] : @[ui, window, fps, intro];
    graphics.title = @"Graphics"; graphics.rows = gfx; detail.title = @"Detail"; detail.rows = det; camera.title = @"Camera"; camera.rows = cam;
    NSString *(^chosen)(NSArray<DSRow *> *) = ^NSString *(NSArray<DSRow *> *rows) {   /* the rows that override the game's Options */
        NSMutableArray *a = [NSMutableArray array];
        for (DSRow *r in rows) if (val(r).length) [a addObject:[NSString stringWithFormat:@"%@ %@", r.title, r.choices[r.index][@"label"]]];
        return a.count ? [a componentsJoinedByString:@" · "] : @"As in the game's own Options";
    };
    graphics.summary = ^NSString * { return chosen(gfx); }; detail.summary = ^NSString * { return chosen(det); };
    saves.title = @"Saves"; saves.summary = ^NSString * { return @"Your neighbourhoods, in Finder"; };
    updSec.title = @"Updates"; updSec.summary = ^NSString * { NSDictionary *c = upd.choices[upd.index]; return [c[@"note"] length] ? [NSString stringWithFormat:@"%@ · %@", c[@"label"], c[@"note"]] : c[@"label"]; };
    DSLaunchView *v = [[DSLaunchView alloc] initWithFrame:NSMakeRect(0, 0, 780, 800)];
    v.top = @[res]; v.sections = @[display, graphics, detail, camera, saves, updSec]; v.open = -1; v.hover = v.pressed = HIT_NONE;
    v.note = @"Sound and the rest: in the game's own Options. Pinch or scroll to zoom; push the pointer against an edge to scroll.";
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
        a.informativeText = [NSString stringWithFormat:@"The %@ branch (%@) is downloaded from GitHub and the app is rebuilt from your own copy of the game, "
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
    v.backdrop = art(data, @"backdrop"); v.shot = art(data, @"shot");
    NSImage *logo = art(data, @"logo"); v.logo = logo ? trimmed(logo, 0) : nil;
    if (shot) {
        const char *open = getenv("DS_LAUNCHER_OPEN");
        if (open) for (NSInteger i = 0; i < (NSInteger)v.sections.count; i++) if ([v.sections[i].title caseInsensitiveCompare:@(open)] == NSOrderedSame) v.open = i;
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds]; [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
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
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:w queue:nil usingBlock:^(NSNotification *n) { (void)n; [NSApp stopModal]; }];
    [NSApp activateIgnoringOtherApps:YES];
    [w makeKeyAndOrderFront:nil];
    [NSApp runModalForWindow:w];
    [w orderOut:nil];
    if (!result) return 0;
    finish();
    return 1;
}
