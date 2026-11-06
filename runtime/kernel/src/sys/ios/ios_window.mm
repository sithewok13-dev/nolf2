// ----------------------------------------------------------------------- //
//
// MODULE  : ios_window.mm
//
// PURPOSE : The iOS / iPadOS platform shell -- the UIKit counterpart of
//           macos_window.mm, implementing the same LTMacWin_* C ABI
//           (ltmacwindow.h) so the engine, the Metal renderer and the input
//           layer are shared with the macOS port unchanged.
//
//           What is different from macOS, and why:
//
//           * UIKit owns the main thread. The engine cannot run its own
//             blocking frame loop, so main() starts UIApplicationMain and a
//             CADisplayLink runs one engine frame per screen refresh
//             (LTMacClient_Step in macos_client.cpp). Pacing from the display
//             link, not from a timer of our own, is what keeps the frames even.
//
//           * The game files are the player's own retail copy, copied into the
//             app's Documents folder with the Files app (Info.plist turns on
//             UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace). The
//             folder is found here, made the current directory -- the engine
//             resolves its .rez archives relative to it, as on macOS -- and the
//             -rez arguments are built the way the macOS launcher builds them.
//             With no game files the app says so on screen and never starts
//             the engine.
//
//           * Everything the engine prints goes to Documents/engine.log, which
//             the player can find in the Files app and send with a bug report.
//
//           * The audio session is set to Playback before the engine opens its
//             sound device, so the game is heard with the silent switch on.
//
//           * A touch is the mouse: in menus it moves the game's cursor and
//             clicks (WM_MOUSEMOVE / WM_LBUTTONDOWN / WM_LBUTTONUP through the
//             game's hooked window proc, exactly as macos_window.mm does). In
//             play (the engine asks for a locked cursor) a drag looks around
//             instead. A second finger is the Escape key: it opens the game
//             menu and backs out of menu screens. The full touch controls come
//             later; this is the minimum to reach and drive the menus.
//
// ----------------------------------------------------------------------- //

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AVFoundation/AVFoundation.h>

#include "ltmacwindow.h"
#include "macos_input.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vector>
#include <string>

// macos_client.cpp: the engine's start / one frame / stop.
extern "C" bool LTMacClient_Start(int argc, char** argv);
extern "C" bool LTMacClient_Step(void);
extern "C" void LTMacClient_Stop(void);

// --------------------------------------------------------------------------
// State
// --------------------------------------------------------------------------
@class LTIOSViewController;

namespace {
    UIWindow*            g_pWindow     = nil;
    LTIOSViewController* g_pVC         = nil;
    UIView*              g_pMetalView  = nil;
    bool                 g_bShouldClose = false;
    LTMacWndProc         g_pMacWndProc  = NULL;

    // Touches are queued as they arrive from UIKit and handed to the game in
    // LTMacWin_PumpEvents, inside the engine's frame, as macOS does with its
    // NSEvent queue -- so the game never sees input in the middle of a frame.
    enum EIOSInput { IN_MOVE, IN_DOWN, IN_UP, IN_LOOK, IN_ESCAPE };
    struct SIOSInput { EIOSInput m_eType; float m_fX, m_fY; };
    std::vector<SIOSInput> g_aInput;

    // The scale from view points to drawable pixels (the engine works in
    // drawable pixels everywhere, see LTMacWin_GetSize).
    const CGFloat kMaxRenderScale = 2.0;
}

// --------------------------------------------------------------------------
// The view: a CAMetalLayer the size of the screen's safe area.
// --------------------------------------------------------------------------
@interface LTIOSMetalView : UIView
@end

@implementation LTIOSMetalView {
    UITouch* m_pMouseTouch;      // the finger acting as the mouse / look drag
    CGPoint  m_LastPoint;
}

+ (Class)layerClass { return [CAMetalLayer class]; }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor blackColor];
        CAMetalLayer* l = (CAMetalLayer*)self.layer;
        l.opaque = YES;
    }
    return self;
}

- (CGFloat)renderScale {
    CGFloat s = self.traitCollection.displayScale;
    if (s <= 0) s = 1.0;
    return (s > kMaxRenderScale) ? kMaxRenderScale : s;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer* l = (CAMetalLayer*)self.layer;
    CGFloat s = [self renderScale];
    l.contentsScale = s;
    l.drawableSize  = CGSizeMake(floor(self.bounds.size.width * s),
                                 floor(self.bounds.size.height * s));
}

// View points -> drawable pixels, clamped to the drawable.
- (CGPoint)pixelPoint:(CGPoint)pt {
    CAMetalLayer* l = (CAMetalLayer*)self.layer;
    CGSize b = self.bounds.size;
    if (b.width <= 0 || b.height <= 0) return CGPointZero;
    CGFloat x = pt.x * l.drawableSize.width  / b.width;
    CGFloat y = pt.y * l.drawableSize.height / b.height;
    if (x < 0) x = 0; else if (x > l.drawableSize.width  - 1) x = l.drawableSize.width  - 1;
    if (y < 0) y = 0; else if (y > l.drawableSize.height - 1) y = l.drawableSize.height - 1;
    return CGPointMake(x, y);
}

- (void)queue:(EIOSInput)e at:(CGPoint)pt {
    CGPoint p = [self pixelPoint:pt];
    g_aInput.push_back({ e, (float)p.x, (float)p.y });
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) {
        if (m_pMouseTouch) {
            // A second finger while one is down: Escape.
            g_aInput.push_back({ IN_ESCAPE, 0, 0 });
            continue;
        }
        m_pMouseTouch = t;
        m_LastPoint   = [t locationInView:self];
        if (!LTMacWin_EngineWantsCursorLock()) {
            [self queue:IN_MOVE at:m_LastPoint];
            [self queue:IN_DOWN at:m_LastPoint];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (!m_pMouseTouch || ![touches containsObject:m_pMouseTouch]) return;
    CGPoint pt = [m_pMouseTouch locationInView:self];
    if (LTMacWin_EngineWantsCursorLock()) {
        // In play: relative motion in points, as a look drag.
        g_aInput.push_back({ IN_LOOK, (float)(pt.x - m_LastPoint.x),
                                      (float)(pt.y - m_LastPoint.y) });
    } else {
        [self queue:IN_MOVE at:pt];
    }
    m_LastPoint = pt;
}

- (void)endTouches:(NSSet<UITouch*>*)touches {
    if (!m_pMouseTouch || ![touches containsObject:m_pMouseTouch]) return;
    CGPoint pt = [m_pMouseTouch locationInView:self];
    // Always release the button, even if the game switched to play meanwhile,
    // so a menu never sees a button stuck down.
    [self queue:IN_MOVE at:pt];
    [self queue:IN_UP at:pt];
    m_pMouseTouch = nil;
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event { [self endTouches:touches]; }

@end

// --------------------------------------------------------------------------
// Game data: find the folder, build the arguments.
// --------------------------------------------------------------------------

// The entry in pDir whose name matches pName ignoring case, or "".
static std::string ios_FindNoCase(NSString* pDir, const char* pName) {
    NSArray<NSString*>* items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pDir error:nil];
    NSString* want = [NSString stringWithUTF8String:pName];
    for (NSString* s in items)
        if ([s caseInsensitiveCompare:want] == NSOrderedSame)
            return std::string([s UTF8String]);
    return std::string();
}

static bool ios_IsGameFolder(NSString* pDir) {
    return !ios_FindNoCase(pDir, "GAME.rez").empty() && !ios_FindNoCase(pDir, "GAME2.rez").empty();
}

// Documents itself, or one folder down (players often copy the whole game
// folder in). Documents first, then the folders in name order.
static NSString* ios_FindGameFolder(NSString* pDocs) {
    if (ios_IsGameFolder(pDocs)) return pDocs;
    NSArray<NSString*>* items = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:pDocs error:nil]
                                  sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString* s in items) {
        NSString* p = [pDocs stringByAppendingPathComponent:s];
        BOOL bDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&bDir] && bDir && ios_IsGameFolder(p))
            return p;
    }
    return nil;
}

// argv for the engine: the program name, then a -rez pair per archive, in the
// macOS launcher's order -- the retail archives, then the loose Game folder,
// which overrides them (launcher/NOLF2Launcher.swift, GameFolder.archives).
static std::vector<std::string> ios_BuildArgs(NSString* pGameDir) {
    std::vector<std::string> args;
    args.push_back("Lithtech");
    const char* aBase[] = { "GAME.rez", "GAME2.rez", "Update_v1x3.rez" };
    for (const char* a : aBase) {
        std::string s = ios_FindNoCase(pGameDir, a);
        if (!s.empty()) { args.push_back("-rez"); args.push_back(s); }
    }
    std::string sGame = ios_FindNoCase(pGameDir, "Game");
    if (!sGame.empty()) { args.push_back("-rez"); args.push_back(sGame); }
    return args;
}

// --------------------------------------------------------------------------
// The view controller: landscape, full screen, no status bar or home bar.
// --------------------------------------------------------------------------
@interface LTIOSViewController : UIViewController
@property (nonatomic, strong) CADisplayLink* displayLink;
@property (nonatomic, strong) UILabel* message;
@property (nonatomic, copy)   NSString* gameDir;
@property (nonatomic) BOOL started;
- (void)showMessage:(NSString*)text;
@end

@implementation LTIOSViewController

- (void)loadView {
    UIView* root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor blackColor];
    self.view = root;

    LTIOSMetalView* mv = [[LTIOSMetalView alloc] initWithFrame:root.bounds];
    [root addSubview:mv];
    g_pMetalView = mv;
}

// The game's picture fills the screen from side to side between the safe-area
// insets, so nothing of the menus sits under the rounded corners, the notch or
// the Dynamic Island. It keeps the full height: the home indicator only
// overlaps the very bottom, and the game draws nothing there that a tap needs.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets in = self.view.safeAreaInsets;
    CGRect b = self.view.bounds;
    g_pMetalView.frame = CGRectMake(in.left, 0, b.size.width - in.left - in.right, b.size.height);
    if (self.message)
        self.message.frame = CGRectInset(self.view.bounds, MAX(in.left, 24) + 8, 24);
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
// Edge swipes still work, but need a second swipe, so a look drag that starts
// at the bottom edge doesn't throw the player out of the game.
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)showMessage:(NSString*)text {
    if (!self.message) {
        UILabel* l = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 32, 24)];
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:17];
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.6;
        [self.view addSubview:l];
        self.message = l;
    }
    self.message.text = text;
    [self.view setNeedsLayout];
}

// Start the engine only once the view is on screen with its final, landscape
// size: the renderer reads the drawable size once, at start-up (nr_Init).
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.started || !self.gameDir) return;
    self.started = YES;
    [self.view layoutIfNeeded];
    [g_pMetalView layoutIfNeeded];

    std::vector<std::string> args = ios_BuildArgs(self.gameDir);
    std::vector<char*> argv;
    for (std::string& s : args) {
        argv.push_back(strdup(s.c_str()));
        fprintf(stderr, "[ios] arg: %s\n", s.c_str());
    }
    argv.push_back(NULL);

    if (!LTMacClient_Start((int)args.size(), argv.data())) {
        fprintf(stderr, "[ios] the engine did not start\n");
        fflush(stderr);
        [self showMessage:@"The game could not start.\n\nThe file engine.log in the app's folder in the Files app says why. Please send it with a bug report."];
        return;
    }

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    // 60 Hz for now, also on 120 Hz screens: what this engine costs per frame
    // on a phone is not known yet.
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)frame:(CADisplayLink*)link {
    @autoreleasepool {
        if (!LTMacClient_Step()) {
            [link invalidate];
            self.displayLink = nil;
            LTMacClient_Stop();
            // Like the macOS main(): skip the game modules' static destructors
            // (see the note at the end of macos_client.cpp's main). An iOS app
            // that ends itself is unusual, but the player chose Quit.
            _exit(0);
        }
    }
}

- (void)setPaused:(BOOL)paused {
    self.displayLink.paused = paused;
    if (paused) {
        g_aInput.clear();
        LTMacInput_ClearAll();
    }
}

@end

// --------------------------------------------------------------------------
// The app delegate.
// --------------------------------------------------------------------------
@interface LTIOSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow* window;
@end

@implementation LTIOSAppDelegate

- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts {
    NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

    // The log first, so everything after this is in it.
    NSString* log = [docs stringByAppendingPathComponent:@"engine.log"];
    if (freopen([log fileSystemRepresentation], "w", stderr))
        setvbuf(stderr, NULL, _IOLBF, 0);
    dup2(fileno(stderr), fileno(stdout));
    setvbuf(stdout, NULL, _IOLBF, 0);
    NSDictionary* info = [[NSBundle mainBundle] infoDictionary];
    fprintf(stderr, "[ios] NOLF2 for iOS %s (%s), %s %s\n",
            [info[@"CFBundleShortVersionString"] UTF8String] ?: "?",
            [info[@"CFBundleVersion"] UTF8String] ?: "?",
            [[UIDevice currentDevice].systemName UTF8String],
            [[UIDevice currentDevice].systemVersion UTF8String]);

    // Sound with the silent switch on, mixed with (and ducking) other audio.
    // This has to be set before the engine opens its sound device.
    NSError* err = nil;
    AVAudioSession* session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:(AVAudioSessionCategoryOptionMixWithOthers |
                               AVAudioSessionCategoryOptionDuckOthers)
                        error:&err])
        fprintf(stderr, "[ios] audio session category failed: %s\n", [[err description] UTF8String]);
    if (![session setActive:YES error:&err])
        fprintf(stderr, "[ios] audio session activate failed: %s\n", [[err description] UTF8String]);

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    g_pWindow = self.window;
    g_pVC = [[LTIOSViewController alloc] init];
    self.window.rootViewController = g_pVC;
    [self.window makeKeyAndVisible];

    NSString* gameDir = ios_FindGameFolder(docs);
    if (!gameDir) {
        fprintf(stderr, "[ios] no game files (GAME.rez + GAME2.rez) in %s or one folder down\n",
                [docs fileSystemRepresentation]);
        NSString* name = info[@"CFBundleDisplayName"] ?: @"NOLF2";
        [g_pVC showMessage:[NSString stringWithFormat:
            @"Game files not found.\n\n"
            @"Copy the files of your own No One Lives Forever 2 (GAME.rez, GAME2.rez and the rest of "
            @"the game folder) into Files > On My iPhone > %@, then open the app again.", name]];
        return YES;
    }

    fprintf(stderr, "[ios] game folder: %s\n", [gameDir fileSystemRepresentation]);
    chdir([gameDir fileSystemRepresentation]);

    // The real client shell and the three game modules, from the app bundle
    // (the macOS launcher passes the same variables to the engine).
    NSString* fw = [[NSBundle mainBundle] privateFrameworksPath];
    setenv("LT_LOAD_CSHELL", "1", 1);
    setenv("LT_CSHELL_MODULE",   [[fw stringByAppendingPathComponent:@"libCShell.dylib"] fileSystemRepresentation], 1);
    setenv("LT_OBJECT_MODULE",   [[fw stringByAppendingPathComponent:@"libObject.dylib"] fileSystemRepresentation], 1);
    setenv("LT_CLIENTFX_MODULE", [[fw stringByAppendingPathComponent:@"libClientFx.dylib"] fileSystemRepresentation], 1);

    g_pVC.gameDir = gameDir;   // viewDidAppear starts the engine
    return YES;
}

- (void)applicationWillResignActive:(UIApplication*)app { [g_pVC setPaused:YES]; }
- (void)applicationDidBecomeActive:(UIApplication*)app  { [g_pVC setPaused:NO]; }

@end

int main(int argc, char* argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([LTIOSAppDelegate class]));
    }
}

// --------------------------------------------------------------------------
// The LTMacWin_* C ABI (ltmacwindow.h).
// --------------------------------------------------------------------------
extern "C" {

// The window already exists (the app delegate made it); nothing to create.
bool LTMacWin_Create(const char* pTitle, int width, int height, bool fullscreen) {
    (void)pTitle; (void)width; (void)height; (void)fullscreen;
    return g_pMetalView != nil;
}

// bDown: the finger is on the screen (MK_LBUTTON in wParam, as Win32 sets it).
static void ios_PostMouse(unsigned int uMsg, float fX, float fY, bool bDown) {
    if (!g_pMacWndProc) return;
    long nX = (long)fX, nY = (long)fY;
    unsigned long wParam = bDown ? 0x0001 /*MK_LBUTTON*/ : 0;
    long lParam = (long)(((nY & 0xFFFF) << 16) | (nX & 0xFFFF));
    g_pMacWndProc((__bridge void*)g_pWindow, uMsg, wParam, lParam);
}

void LTMacWin_PumpEvents(void) {
    LTMacInput_TickInjection();
    LTMacInput_TickHold();

    // Swap out first: the game's handlers may run long, and UIKit only adds
    // to the queue between frames anyway (same thread).
    std::vector<SIOSInput> aInput;
    aInput.swap(g_aInput);
    static bool s_bDown = false;
    for (const SIOSInput& in : aInput) {
        switch (in.m_eType) {
            case IN_MOVE:
                ios_PostMouse(0x0200 /*WM_MOUSEMOVE*/, in.m_fX, in.m_fY, s_bDown);
                break;
            case IN_DOWN:
                s_bDown = true;
                LTMacInput_SetMouseButton(0, true);
                ios_PostMouse(0x0201 /*WM_LBUTTONDOWN*/, in.m_fX, in.m_fY, true);
                break;
            case IN_UP:
                if (s_bDown) {
                    s_bDown = false;
                    LTMacInput_SetMouseButton(0, false);
                    ios_PostMouse(0x0202 /*WM_LBUTTONUP*/, in.m_fX, in.m_fY, false);
                }
                break;
            case IN_LOOK:
                LTMacInput_AddMouseDelta(in.m_fX, in.m_fY);
                break;
            case IN_ESCAPE:
                LTMacInput_InjectKey(0x1B /*VK_ESCAPE*/, 0x01 /*DIK_ESCAPE*/, true);
                LTMacInput_InjectKey(0x1B, 0x01, false);
                break;
        }
    }
}

void* LTMacWin_GetMetalLayer(void) {
    return g_pMetalView ? (__bridge void*)g_pMetalView.layer : NULL;
}

bool LTMacWin_ShouldClose(void) { return g_bShouldClose; }
void LTMacWin_RequestClose(void) { g_bShouldClose = true; }

void LTMacWin_GetSize(int* w, int* h) {
    if (!g_pMetalView) return;
    CAMetalLayer* l = (CAMetalLayer*)g_pMetalView.layer;
    if (w) *w = (int)l.drawableSize.width;
    if (h) *h = (int)l.drawableSize.height;
}

void* LTMacWin_GetNSWindow(void) { return (__bridge void*)g_pWindow; }
void  LTMacWin_SetTitle(const char* pTitle) { (void)pTitle; }

// No pointer to capture or hide on a touch screen: these just remember.
static bool g_bCaptured = false;
void LTMacWin_SetMouseCapture(bool bCapture) { g_bCaptured = bCapture; }
bool LTMacWin_IsMouseCaptured(void) { return g_bCaptured; }
void LTMacWin_SetCursorVisible(bool bVisible) { (void)bVisible; }

LTMacWndProc* LTMacWin_GetWndProcSlot(void) { return &g_pMacWndProc; }

void LTMacWin_Destroy(void) {}

} // extern "C"
