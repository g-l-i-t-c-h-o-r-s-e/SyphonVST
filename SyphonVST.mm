// SyphonVST.mm — VST2 (64-bit, Mojave) with Syphon video preview.
// Supports effect/instrument via SYPHON_VSTI (0 = effect, 1 = instrument).

#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <Syphon/Syphon.h>

#ifndef SYPHON_VSTI
#define SYPHON_VSTI 0
#endif

// VST2 SDK
#include "aeffectx.h"
#include "aeffeditor.h"
#include "audioeffectx.h"

class SyphonVSTEditor;

// ========================== GL view (Syphon 5 API) ==========================
@interface SyphonGLView : NSOpenGLView
@property (atomic, strong) SyphonClient *client;
@property (atomic, assign) BOOL wantFirstServer;          // auto-pick first server
@property (atomic, copy)   NSString *selectedServerUUID;  // last manually chosen server
- (void)connectToFirstServerIfNeeded;
@end

@implementation SyphonGLView

+ (NSOpenGLPixelFormat *)defaultPixelFormat
{
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, (NSOpenGLPixelFormatAttribute)24,
        NSOpenGLPFAAlphaSize, (NSOpenGLPixelFormatAttribute)8,
        NSOpenGLPFAOpenGLProfile, (NSOpenGLPixelFormatAttribute)NSOpenGLProfileVersionLegacy,
        0
    };
    return [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect pixelFormat:[SyphonGLView defaultPixelFormat]];
    if (self) {
        _wantFirstServer = YES;

        // Watch for servers appearing/disappearing
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(serversChanged:)
                   name:SyphonServerAnnounceNotification object:nil];
        [nc addObserver:self selector:@selector(serversChanged:)
                   name:SyphonServerRetireNotification  object:nil];
        [nc addObserver:self selector:@selector(serversChanged:)
                   name:SyphonServerUpdateNotification  object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.client = nil;
    self.selectedServerUUID = nil;
}

- (void)prepareOpenGL
{
    [super prepareOpenGL];
    GLint swap = 1;
    [[self openGLContext] setValues:&swap forParameter:NSOpenGLCPSwapInterval];

    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glClearColor(0.f, 0.f, 0.f, 1.f);

    [self connectToFirstServerIfNeeded];
}

- (void)reshape
{
    [super reshape];
    [[self openGLContext] makeCurrentContext];
    NSRect b = self.bounds;
    glViewport(0, 0, (GLsizei)b.size.width, (GLsizei)b.size.height);
}

- (void)serversChanged:(__unused NSNotification *)n
{
    // Whenever servers change, try to reconnect according to our selection rules
    [self connectToFirstServerIfNeeded];
}

// Helper: actually connect to a specific server description
- (void)connectToServerDescription:(NSDictionary *)desc
{
    if (!desc) {
        self.client = nil;
        [self setNeedsDisplay:YES];
        return;
    }

    NSString *newUUID = desc[SyphonServerDescriptionUUIDKey];

    if (self.client) {
        NSString *curUUID = self.client.serverDescription[SyphonServerDescriptionUUIDKey];
        if (curUUID && newUUID && [curUUID isEqualToString:newUUID]) {
            // Already connected to this server
            return;
        }
    }

    CGLContextObj cgl = [[self openGLContext] CGLContextObj];

    __weak SyphonGLView *weakSelf = self;
    SyphonClient *newClient =
    [[SyphonClient alloc] initWithServerDescription:desc
                                            context:cgl
                                            options:nil
                                   newFrameHandler:^(SyphonClient *client) {
        (void)client;
        SyphonGLView *strongSelf = weakSelf;
        if (!strongSelf) return;

        // UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf setNeedsDisplay:YES];
        });
    }];

    self.client = newClient;
    self.selectedServerUUID = newUUID;
    [self setNeedsDisplay:YES];
}

// Choose what to connect to, based on selected UUID / auto-first
- (void)connectToFirstServerIfNeeded
{
    NSArray<NSDictionary *> *servers = [SyphonServerDirectory sharedDirectory].servers;
    if (servers.count == 0) {
        self.client = nil;
        [self setNeedsDisplay:YES];
        return;
    }

    // If user has chosen a specific server, try to follow it by UUID
    NSString *selectedUUID = self.selectedServerUUID;
    if (selectedUUID.length > 0) {
        for (NSDictionary *d in servers) {
            NSString *uuid = d[SyphonServerDescriptionUUIDKey];
            if (uuid && [uuid isEqualToString:selectedUUID]) {
                [self connectToServerDescription:d];
                return;
            }
        }
    }

    // No (valid) manual selection; if auto-select is enabled, grab first
    if (self.wantFirstServer) {
        NSDictionary *first = servers.firstObject;
        [self connectToServerDescription:first];
    }
}

// ======================= Right-click context menu ==========================
- (void)refreshServers:(id)sender
{
    (void)sender;
    // Just re-run our selection logic; SyphonServerDirectory is already live
    [self connectToFirstServerIfNeeded];
}

- (void)selectServerFromMenu:(NSMenuItem *)item
{
    NSDictionary *desc = item.representedObject;
    if (!desc) return;

    // From now on, don't auto-switch to "first"; we follow this UUID
    self.wantFirstServer = NO;
    [self connectToServerDescription:desc];
}

- (void)rightMouseDown:(NSEvent *)event
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Syphon"];
    [menu setAutoenablesItems:NO];

    // Refresh item
    NSMenuItem *refreshItem =
    [[NSMenuItem alloc] initWithTitle:@"Refresh Servers"
                               action:@selector(refreshServers:)
                        keyEquivalent:@""];
    [refreshItem setTarget:self];
    [menu addItem:refreshItem];
    [menu addItem:[NSMenuItem separatorItem]];

    // Server list
    NSArray<NSDictionary *> *servers = [SyphonServerDirectory sharedDirectory].servers;
    if (servers.count == 0) {
        NSMenuItem *none =
        [[NSMenuItem alloc] initWithTitle:@"No Syphon servers"
                                   action:NULL
                            keyEquivalent:@""];
        [none setEnabled:NO];
        [menu addItem:none];
    } else {
        NSString *selectedUUID = self.selectedServerUUID;
        for (NSDictionary *desc in servers) {
            NSString *name = desc[SyphonServerDescriptionNameKey];
            NSString *app  = desc[SyphonServerDescriptionAppNameKey];

            if (!name || name.length == 0) name = @"(Unnamed)";
            if (!app  || app.length  == 0) app  = @"(Unknown App)";

            NSString *title = [NSString stringWithFormat:@"%@ — %@", name, app];

            NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:title
                                       action:@selector(selectServerFromMenu:)
                                keyEquivalent:@""];
            [item setTarget:self];
            item.representedObject = desc;

            NSString *uuid = desc[SyphonServerDescriptionUUIDKey];
            if (uuid && selectedUUID && [uuid isEqualToString:selectedUUID]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [item setState:NSOnState];  // older style; fine on Mojave
#pragma clang diagnostic pop
            }

            [menu addItem:item];
        }
    }

    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

// ============================= Drawing =====================================
- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;

    [[self openGLContext] makeCurrentContext];
    glClear(GL_COLOR_BUFFER_BIT);

    if (!self.client || !self.client.isValid) {
        glBegin(GL_QUADS);
        glColor3f(0.15f, 0.15f, 0.15f);
        glVertex2f(-1.f,-1.f);
        glVertex2f( 1.f,-1.f);
        glVertex2f( 1.f, 1.f);
        glVertex2f(-1.f, 1.f);
        glEnd();
        [[self openGLContext] flushBuffer];
        return;
    }

    SyphonImage *img = [self.client newFrameImage];
    if (img) {
        GLuint tex = img.textureName;
        NSSize ts  = img.textureSize;
        size_t tw  = (size_t)ts.width;
        size_t th  = (size_t)ts.height;

        GLenum  tgt  = GL_TEXTURE_RECTANGLE_ARB; // Syphon uses rect textures
        GLfloat sMax = (GLfloat)tw;
        GLfloat tMax = (GLfloat)th;

        glEnable(tgt);
        glBindTexture(tgt, tex);
        glColor3f(1.f, 1.f, 1.f);

        // Letterbox to fit view while preserving aspect
        NSRect b = self.bounds;
        float vw = (float)b.size.width;
        float vh = (float)b.size.height;
        float arTex  = (float)tw / (float)th;
        float arView = vw / vh;
        float sx = 1.f, sy = 1.f;
        if (arView > arTex) {
            sx = arTex / arView;
        } else {
            sy = arView / arTex;
        }

        glBegin(GL_QUADS);
        glTexCoord2f(0.f,    0.f);  glVertex2f(-sx, -sy);
        glTexCoord2f(sMax,   0.f);  glVertex2f( sx, -sy);
        glTexCoord2f(sMax, tMax);   glVertex2f( sx,  sy);
        glTexCoord2f(0.f,  tMax);   glVertex2f(-sx,  sy);
        glEnd();

        glBindTexture(tgt, 0);
        glDisable(tgt);
    } else {
        // No frame yet: neutral background
        glBegin(GL_QUADS);
        glColor3f(0.05f, 0.05f, 0.05f);
        glVertex2f(-1.f,-1.f);
        glVertex2f( 1.f,-1.f);
        glVertex2f( 1.f, 1.f);
        glVertex2f(-1.f, 1.f);
        glEnd();
    }

    [[self openGLContext] flushBuffer];
}

@end

// ============================== VST class =====================================
class SyphonVST : public AudioEffectX
{
public:
    explicit SyphonVST(audioMasterCallback audioMaster);
    ~SyphonVST() override = default;

    void processReplacing(float **inputs, float **outputs, VstInt32 sampleFrames) override;
    void setProgramName(char *name) override;
    void getProgramName(char *name) override;

    bool getEffectName(char *name) override;
    bool getProductString(char *text) override;
    bool getVendorString(char *text) override;
    VstInt32 getVendorVersion() override { return 1000; }
    VstPlugCategory getPlugCategory() override
    {
    #if SYPHON_VSTI
        return kPlugCategSynth;
    #else
        return kPlugCategEffect;
    #endif
    }
    VstInt32 canDo(char *text) override
    {
        if (!text) return 0;
        if (!strcmp(text, "receiveVstEvents"))      return 1;
        if (!strcmp(text, "receiveVstMidiEvent"))   return 1;
        if (!strcmp(text, "receiveVstTimeInfo"))    return 1;
        if (!strcmp(text, "plugAsChannelInsert"))   return SYPHON_VSTI ? 0 : 1;
        if (!strcmp(text, "plugAsSend"))            return SYPHON_VSTI ? 0 : 1;
        if (!strcmp(text, "plugAsSynth"))           return SYPHON_VSTI ? 1 : 0;
        return 0;
    }

private:
    char     programName[kVstMaxProgNameLen + 1];
    VstInt32 mNumIn;
    VstInt32 mNumOut;
};

class SyphonVSTEditor : public AEffEditor
{
public:
    explicit SyphonVSTEditor(AudioEffect *effect);
    ~SyphonVSTEditor() override;

    bool open(void *ptr) override;
    void close() override;
    void idle() override;
    bool getRect(ERect **ppRect) override;

private:
    ERect editorRect;
    NSView       *parentView = nil;
    SyphonGLView *glView     = nil;
};

SyphonVST::SyphonVST(audioMasterCallback audioMaster)
: AudioEffectX(audioMaster, 1, 0)
{
#if SYPHON_VSTI
    mNumIn  = 0; mNumOut = 2; isSynth(true);
#else
    mNumIn  = 2; mNumOut = 2; isSynth(false);
#endif
    setNumInputs(mNumIn);
    setNumOutputs(mNumOut);
    setUniqueID('Syph');
    canProcessReplacing();
    vst_strncpy(programName, "Default", kVstMaxProgNameLen);
    setEditor(new SyphonVSTEditor(this));
}

void SyphonVST::processReplacing(float **inputs, float **outputs, VstInt32 sampleFrames)
{
    if (!outputs) return;
#if SYPHON_VSTI
    float *outL = outputs[0];
    float *outR = outputs[(mNumOut > 1) ? 1 : 0];
    memset(outL, 0, sizeof(float)*sampleFrames);
    memset(outR, 0, sizeof(float)*sampleFrames);
#else
    if (!inputs) return;
    float *inL  = inputs[0];
    float *inR  = inputs[(mNumIn  > 1) ? 1 : 0];
    float *outL = outputs[0];
    float *outR = outputs[(mNumOut > 1) ? 1 : 0];
    for (VstInt32 i = 0; i < sampleFrames; ++i)
    {
        outL[i] = inL[i];
        outR[i] = inR[i];
    }
#endif
}

void SyphonVST::setProgramName(char *name)
{
    vst_strncpy(programName, name, kVstMaxProgNameLen);
}
void SyphonVST::getProgramName(char *name)
{
    vst_strncpy(name, programName, kVstMaxProgNameLen);
}
bool SyphonVST::getEffectName(char *name)
{
    vst_strncpy(name, "SyphonVST", kVstMaxEffectNameLen);
    return true;
}
bool SyphonVST::getProductString(char *text)
{
    vst_strncpy(text, "Syphon VST Syphon Viewer", kVstMaxProductStrLen);
    return true;
}
bool SyphonVST::getVendorString(char *text)
{
    vst_strncpy(text, "Pandela", kVstMaxVendorStrLen);
    return true;
}

// -------------------- Editor --------------------
SyphonVSTEditor::SyphonVSTEditor(AudioEffect *effect)
: AEffEditor(effect)
{
    editorRect.top    = 0;
    editorRect.left   = 0;
    editorRect.right  = 640;
    editorRect.bottom = 360;
}
SyphonVSTEditor::~SyphonVSTEditor()
{
    @autoreleasepool {
        [glView removeFromSuperview];
        glView = nil;
        parentView = nil;
    }
}
bool SyphonVSTEditor::getRect(ERect **ppRect)
{
    if (!ppRect) return false;
    *ppRect = &editorRect;
    return true;
}

bool SyphonVSTEditor::open(void *ptr)
{
    @autoreleasepool {
        id hostObj = (__bridge id)ptr;
        if ([hostObj isKindOfClass:[NSView class]])        parentView = (NSView *)hostObj;
        else if ([hostObj isKindOfClass:[NSWindow class]]) parentView = [(NSWindow *)hostObj contentView];
        else                                               parentView = nil;
        if (!parentView) return false;

        NSRect frame = NSMakeRect(0, 0,
                                  editorRect.right  - editorRect.left,
                                  editorRect.bottom - editorRect.top);
        glView = [[SyphonGLView alloc] initWithFrame:frame];
        glView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [parentView addSubview:glView];
    }
    return true;
}
void SyphonVSTEditor::close()
{
    @autoreleasepool {
        [glView removeFromSuperview];
        glView = nil;
        parentView = nil;
    }
}
void SyphonVSTEditor::idle()
{
    // Redraw is driven by Syphon's newFrameHandler
    AEffEditor::idle();
}

// -------------------- VST entry points --------------------
static AudioEffect* createEffectInstance(audioMasterCallback master)
{
    return new SyphonVST(master);
}

extern "C" AEffect* VSTPluginMain(audioMasterCallback master)
{
    if (!master(nullptr, audioMasterVersion, 0, 0, nullptr, 0)) return nullptr;
    AudioEffect *fx = createEffectInstance(master);
    return fx ? fx->getAeffect() : nullptr;
}

extern "C" AEffect* main_macho(audioMasterCallback master) __attribute__((visibility("default")));
AEffect* main_macho(audioMasterCallback master)
{
    return VSTPluginMain(master);
}
