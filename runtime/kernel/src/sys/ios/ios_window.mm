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
//           * Frame rate: 60 (default) or 120 on a ProMotion screen, chosen
//             with the Frame Rate row of the game's Display screen (Options >
//             Display, where VSync is on the PC). The game writes the console
//             variable IOSMaxFPS; this file asks the display link for that
//             rate, remembers it (NSUserDefaults) and says so with a toast and
//             a haptic. The engine is variable-step (each frame's real time,
//             exact physics integration, the local server stepped and every
//             object sent each frame), so 120 draws new frames and keeps the
//             game's speed. Release builds have no engine frame cap (MaxFPS
//             is compiled out with _FINAL): the display link is the only pace.
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
#include <strings.h>
#include <unistd.h>
#include <sys/stat.h>
#include <vector>
#include <string>

// macos_client.cpp: the engine's start / one frame / stop.
extern "C" bool LTMacClient_Start(int argc, char** argv);
extern "C" bool LTMacClient_Step(void);
extern "C" void LTMacClient_Stop(void);
extern "C" int  LTMacClient_GetConsoleInt(const char* pName, int nDefault);
extern "C" void LTMacClient_RunConsole(const char* pCommand);

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

    // The frame rate asked of the screen: 60 or 120 (IOSMaxFPS).
    NSString* const kMaxFpsKey = @"IOSMaxFps";
    int g_nMaxFps = 60;

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

// argv for the engine: the program name, then a -rez pair per archive. Every
// .rez in the game folder is loaded (later ones override earlier ones):
//   1. the retail archives, in the order the original game's own dedicated
//      server lists them (NOLF2/ServerApp/ServerDlg.cpp): GAME, GAME2,
//      GAMEDLL, SOUND, GAMEL, GAMEP, GAMEP2. Copies differ in which of these
//      they have -- one had GAME, GAME2, GAMEDLL and SOUND, with the interface
//      text (cres.dll) not in GAME or GAME2 -- so loading only GAME and GAME2,
//      as the macOS launcher does, is not enough;
//   2. any other .rez, in name order (the player's extras);
//   3. the 1.3 patch, Update_v1x3.rez, so it overrides the retail files;
//   4. the loose Game folder, which overrides everything (as on macOS).
// ENGINE.REZ is left out: the engine always adds engine.rez itself, last
// (macos_client.cpp), and the file-name layer finds it whatever its case.
static std::vector<std::string> ios_BuildArgs(NSString* pGameDir) {
    std::vector<std::string> args;
    args.push_back("Lithtech");
    std::vector<std::string> used;
    auto add = [&](const std::string& s) {
        if (s.empty()) return;
        for (const std::string& u : used)
            if (strcasecmp(u.c_str(), s.c_str()) == 0) return;
        used.push_back(s);
        args.push_back("-rez");
        args.push_back(s);
    };

    const char* aRetail[] = { "GAME.rez", "GAME2.rez", "GAMEDLL.rez", "SOUND.rez",
                              "GAMEL.rez", "GAMEP.rez", "GAMEP2.rez" };
    for (const char* a : aRetail)
        add(ios_FindNoCase(pGameDir, a));

    NSArray<NSString*>* items = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:pGameDir error:nil]
                                  sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString* sName in items) {
        BOOL bDir = NO;
        NSString* sPath = [pGameDir stringByAppendingPathComponent:sName];
        if ([sName caseInsensitiveCompare:@"engine.rez"] == NSOrderedSame ||        // the engine adds it
            [sName caseInsensitiveCompare:@"Update_v1x3.rez"] == NSOrderedSame)     // added next
            continue;
        if ([[sName pathExtension] caseInsensitiveCompare:@"rez"] == NSOrderedSame &&
            [[NSFileManager defaultManager] fileExistsAtPath:sPath isDirectory:&bDir] && !bDir)
            add(std::string([sName UTF8String]));
    }

    add(ios_FindNoCase(pGameDir, "Update_v1x3.rez"));
    add(ios_FindNoCase(pGameDir, "Game"));
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
@property (nonatomic, strong) UILabel* toast;
@property (nonatomic, strong) UILabel* buildStamp;
- (void)showMessage:(NSString*)text;
- (void)startEngine;
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
    // One turn of the run loop later, so the launch has finished first: the
    // engine's start loads the archives and takes a while, and iOS ends an app
    // whose launch takes too long.
    dispatch_async(dispatch_get_main_queue(), ^{ [self startEngine]; });
}

- (void)startEngine {
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
        // The one cause we can name for the player: a new profile is made from
        // Profiles\default.prf, a loose file of the game folder (not in a .rez).
        // Without it, and with no profile saved yet, CProfileMgr::Init fails.
        struct stat st;
        bool bHaveDefaultProfile = (stat("Profiles/default.prf", &st) == 0);   // ignores case (ios_paths.cpp)
        fprintf(stderr, "[ios] Profiles/default.prf %s\n", bHaveDefaultProfile ? "found" : "NOT found");
        fflush(stderr);
        if (!bHaveDefaultProfile)
            [self showMessage:@"The game could not start: the Profiles folder from your game folder is missing (it holds the file default.prf).\n\nCopy the Profiles folder into the app's folder in the Files app, next to GAME.REZ, then open the app again."];
        else
            [self showMessage:@"The game could not start.\n\nThe file engine.log in the app's folder in the Files app says why. Please send it with a bug report."];
        return;
    }

    // The remembered frame rate, given to the game so its Display screen shows it.
    NSInteger nSaved = [[NSUserDefaults standardUserDefaults] integerForKey:kMaxFpsKey];
    g_nMaxFps = (nSaved == 120) ? 120 : 60;
    char szCmd[64];
    snprintf(szCmd, sizeof(szCmd), "+IOSMaxFPS %d", g_nMaxFps);
    LTMacClient_RunConsole(szCmd);

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    [self applyMaxFps];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    fprintf(stderr, "[ios] frame rate %d (screen max %ld)\n", g_nMaxFps,
            (long)[UIScreen mainScreen].maximumFramesPerSecond);
}

// Ask the screen for 60 or 120 frames a second. 120 only runs on a ProMotion
// screen; elsewhere iOS gives the most the screen has.
- (void)applyMaxFps {
    if (!self.displayLink) return;
    if (g_nMaxFps == 120)
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    else
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
}

// The game's Display screen changed IOSMaxFPS: follow it, remember it, say so.
- (void)checkMaxFps {
    int n = LTMacClient_GetConsoleInt("IOSMaxFPS", g_nMaxFps);
    if ((n != 60 && n != 120) || n == g_nMaxFps) return;
    g_nMaxFps = n;
    [[NSUserDefaults standardUserDefaults] setInteger:n forKey:kMaxFpsKey];
    [self applyMaxFps];
    fprintf(stderr, "[ios] frame rate now %d\n", n);
    [self showToast:(n == 120) ? @"120 FPS: smoother, uses more battery"
                               : @"60 FPS: cooler, uses less battery"];
    UIImpactFeedbackGenerator* h = [[UIImpactFeedbackGenerator alloc]
                                    initWithStyle:UIImpactFeedbackStyleMedium];
    [h impactOccurred];
}

// "build 80 · Nov 9" from the run number and UTC date CI writes into
// Info.plist (SWBuildNumber, SWBuildDate); "build dev" for a local build.
static NSString* LTIOS_BuildStampText(void) {
    NSDictionary* info = [[NSBundle mainBundle] infoDictionary];
    NSString* num = info[@"SWBuildNumber"];
    if (![num isKindOfClass:[NSString class]] || num.length == 0) return @"build dev";
    NSString* day = info[@"SWBuildDate"];
    NSDateFormatter* f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    f.dateFormat = @"yyyy-MM-dd";
    NSDate* d = [day isKindOfClass:[NSString class]] ? [f dateFromString:day] : nil;
    if (!d) return [NSString stringWithFormat:@"build %@", num];
    f.dateFormat = @"MMM d";
    return [NSString stringWithFormat:@"build %@ \u00B7 %@", num, [f stringFromDate:d]];
}

// The build stamp: small, dim, bottom right, clear of the notch and home bar,
// only while the game's main menu is up (IOSMainMenu, set by CScreenMain).
- (void)checkBuildStamp {
    BOOL show = LTMacClient_GetConsoleInt("IOSMainMenu", 0) != 0;
    if (!show) {
        self.buildStamp.hidden = YES;
        return;
    }
    if (!self.buildStamp) {
        UILabel* l = [[UILabel alloc] init];
        l.text = LTIOS_BuildStampText();
        l.font = [UIFont systemFontOfSize:12];
        l.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        l.userInteractionEnabled = NO;
        [l sizeToFit];
        [self.view addSubview:l];
        self.buildStamp = l;
    }
    UILabel* l = self.buildStamp;
    UIEdgeInsets in = self.view.safeAreaInsets;
    CGSize sz = l.bounds.size;
    l.frame = CGRectMake(self.view.bounds.size.width - MAX(in.right, 16) - 8 - sz.width,
                         self.view.bounds.size.height - MAX(in.bottom, 12) - 4 - sz.height,
                         sz.width, sz.height);
    l.hidden = NO;
}

- (void)showToast:(NSString*)text {
    if (!self.toast) {
        UILabel* l = [[UILabel alloc] init];
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = [UIColor whiteColor];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        l.font = [UIFont boldSystemFontOfSize:15];
        l.layer.cornerRadius = 10;
        l.layer.masksToBounds = YES;
        l.userInteractionEnabled = NO;
        [self.view addSubview:l];
        self.toast = l;
    }
    UILabel* l = self.toast;
    l.text = text;
    CGSize sz = [l sizeThatFits:CGSizeMake(self.view.bounds.size.width - 80, 40)];
    CGFloat w = sz.width + 32, hgt = sz.height + 16;
    UIEdgeInsets in = self.view.safeAreaInsets;
    l.frame = CGRectMake((self.view.bounds.size.width - w) / 2, MAX(in.top, 16) + 8, w, hgt);
    [l.layer removeAllAnimations];
    l.alpha = 1;
    [UIView animateWithDuration:0.4 delay:1.8 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ l.alpha = 0; } completion:nil];
}

// One line in engine.log every 5 s of play (not in menus): the frame rate
// reached, the frame-to-frame time (average, worst), how many frames came
// late (over 1.5 refreshes), and the engine's own time per frame.
- (void)logFrameStats:(double)fStart stepMs:(double)fStepMs {
    static double s_fPrev = 0, s_fT0 = 0, s_fSum = 0, s_fMax = 0, s_fStep = 0, s_fStepMax = 0;
    static unsigned s_nFrames = 0, s_nLate = 0;
    if (!LTMacWin_EngineWantsCursorLock()) { s_fPrev = 0; s_fT0 = 0; return; }
    if (s_fPrev == 0 || fStart - s_fPrev > 0.5) {   // first frame, or back from a pause
        s_fPrev = s_fT0 = fStart;
        s_fSum = s_fMax = s_fStep = s_fStepMax = 0;
        s_nFrames = s_nLate = 0;
        return;
    }
    double fMs = (fStart - s_fPrev) * 1000.0;
    s_fPrev = fStart;
    s_fSum += fMs;   if (fMs > s_fMax) s_fMax = fMs;
    s_fStep += fStepMs; if (fStepMs > s_fStepMax) s_fStepMax = fStepMs;
    if (fMs > 1.5 * 1000.0 / g_nMaxFps) ++s_nLate;
    ++s_nFrames;
    if (fStart - s_fT0 >= 5.0) {
        fprintf(stderr, "[ios] play %d: %.1f fps | frame avg %.2f max %.2f ms | late %u/%u"
                        " | engine avg %.2f max %.2f ms\n",
                g_nMaxFps, s_nFrames * 1000.0 / s_fSum, s_fSum / s_nFrames, s_fMax,
                s_nLate, s_nFrames, s_fStep / s_nFrames, s_fStepMax);
        fflush(stderr);
        s_fT0 = fStart;
        s_fSum = s_fMax = s_fStep = s_fStepMax = 0;
        s_nFrames = s_nLate = 0;
    }
}

- (void)frame:(CADisplayLink*)link {
    @autoreleasepool {
        double fStart = CACurrentMediaTime();
        bool bRunning = LTMacClient_Step();
        if (bRunning) {
            [self logFrameStats:fStart stepMs:(CACurrentMediaTime() - fStart) * 1000.0];
            [self checkMaxFps];
            [self checkBuildStamp];
        }
        if (!bRunning) {
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
    // What is in it (names only), so a bug report shows what the player copied.
    for (NSString* sName in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:gameDir error:nil]
                               sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
        fprintf(stderr, "[ios]   %s\n", [sName UTF8String]);
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
