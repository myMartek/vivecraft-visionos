// quiet_window.m: keeps the Minecraft window of the two build runs out of sight (tools/avpplay/build_parts.sh, stages
// "world" and "bake"). Our code, under this repository's LICENSE.
//
// The two runs need a real window: the game draws into it with the Mac's own OpenGL, as it does when somebody plays.
// So the window stays what it is, on screen and drawn into, and this library makes it invisible instead: every window
// of the process is fully transparent, has no shadow and lets clicks through, from before it is first put on screen.
//
// The game must also know that its window is not the one in front. It assumes it is until it is told otherwise, and
// then puts the mouse pointer into the middle of its window whenever the player enters the world. A window that never
// was in front is never told that it no longer is, so right after a window is first shown this library posts the two
// notifications AppKit posts when a window gets and loses the keyboard. The game hears "focus gained, focus lost",
// stops taking itself for the app in front and leaves the pointer alone.
//
// The process also tells macOS that it is doing work somebody asked for, so that a game nobody can see is not slowed
// down (App Nap).
//
// It is loaded into the game's JVM as a native agent (-agentpath:<this library>). It contains no Java, loads no class
// and calls nothing of the JVM or the game: it only touches AppKit. The classpath, the mods and the Java agents of the
// run are the same with and without it.
//
// Build: xcrun --sdk macosx clang -arch arm64 -fobjc-arc -O1 -dynamiclib -framework AppKit -o libquietwindow.dylib quiet_window.m
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static IMP o_alpha, o_order, o_front, o_key, o_regardless, o_visible;
static id activity;
static char told;                         // key of the "was told it lost the keyboard" mark on a window

static void prepare(NSWindow *w) {
    if (o_alpha) ((void (*)(id, SEL, CGFloat))o_alpha)(w, @selector(setAlphaValue:), 0.0);
    w.ignoresMouseEvents = YES;
    w.hasShadow = NO;
}

static void shown(NSWindow *w) {         // once per window, when it is on screen for the first time
    if (!w.visible || w.keyWindow || objc_getAssociatedObject(w, &told)) return;
    objc_setAssociatedObject(w, &told, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNotificationCenter *c = [NSNotificationCenter defaultCenter];
    [c postNotificationName:NSWindowDidBecomeKeyNotification object:w];
    [c postNotificationName:NSWindowDidResignKeyNotification object:w];
    fprintf(stderr, "[quiet-window] a %.0fx%.0f window is on screen, invisible; the game was told it is not in front\n",
            w.frame.size.width, w.frame.size.height);
}

static void q_alpha(id self, SEL cmd, CGFloat alpha) {          // nothing makes a window of this process visible
    ((void (*)(id, SEL, CGFloat))o_alpha)(self, cmd, 0.0);
}
static void q_order(id self, SEL cmd, NSWindowOrderingMode mode, NSInteger other) {
    prepare(self); ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))o_order)(self, cmd, mode, other); shown(self);
}
static void q_front(id self, SEL cmd, id sender) { prepare(self); ((void (*)(id, SEL, id))o_front)(self, cmd, sender); shown(self); }
static void q_key(id self, SEL cmd, id sender) { prepare(self); ((void (*)(id, SEL, id))o_key)(self, cmd, sender); shown(self); }
static void q_regardless(id self, SEL cmd) { prepare(self); ((void (*)(id, SEL))o_regardless)(self, cmd); shown(self); }
static void q_visible(id self, SEL cmd, BOOL visible) { prepare(self); ((void (*)(id, SEL, BOOL))o_visible)(self, cmd, visible); shown(self); }

static void hook(SEL sel, IMP replacement, IMP *original) {
    Method m = class_getInstanceMethod([NSWindow class], sel);
    if (!m) return;                       // a method AppKit no longer has: nothing to do for it
    *original = method_getImplementation(m);
    method_setImplementation(m, replacement);
}

__attribute__((visibility("default")))
int Agent_OnLoad(void *vm, char *options, void *reserved) {
    @autoreleasepool {
        hook(@selector(setAlphaValue:), (IMP)q_alpha, &o_alpha);
        hook(@selector(orderWindow:relativeTo:), (IMP)q_order, &o_order);
        hook(@selector(orderFront:), (IMP)q_front, &o_front);
        hook(@selector(makeKeyAndOrderFront:), (IMP)q_key, &o_key);
        hook(@selector(orderFrontRegardless), (IMP)q_regardless, &o_regardless);
        hook(@selector(setIsVisible:), (IMP)q_visible, &o_visible);
        activity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:(NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical)
                              reason:@"Minecraft parts build"];
    }
    return 0;                             // JNI_OK
}
