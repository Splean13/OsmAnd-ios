//
//  OAMapRendererView.m
//  OsmAnd
//
//  Created by Alexey Pelykh on 7/18/13.
//  Copyright (c) 2013 OsmAnd. All rights reserved.
//

#import "OAMapRendererView.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

#include <OsmAndCore/QtExtensions.h>
#include <OsmAndCore.h>
#include <OsmAndCore/Map/IMapRenderer.h>
#include <OsmAndCore/Map/IAtlasMapRenderer.h>
#include <OsmAndCore/Map/AtlasMapRendererConfiguration.h>
#include <OsmAndCore/Map/MapAnimator.h>

#import "OALog.h"

#if defined(DEBUG)
#   define validateGL() [self validateOpenGLES]
#else
#   define validateGL()
#endif

#define _(name) OAMapRendererView__##name
#define commonInit _(commonInit)
#define deinit _(deinit)

@implementation OAMapRendererView
{
    EAGLSharegroup* _glShareGroup;
    EAGLContext* _glRenderContext;
    EAGLContext* _glWorkerContext;
    GLuint _depthRenderBuffer;
    GLuint _colorRenderBuffer;
    GLuint _frameBuffer;
    CADisplayLink* _displayLink;
    
    OsmAnd::PointI _viewSize;
    
    std::shared_ptr<OsmAnd::IMapRenderer> _renderer;
    std::shared_ptr<OsmAnd::MapAnimator> _animator;
}

+ (Class)layerClass
{
    return [CAEAGLLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)dealloc
{
    [self deinit];
}

- (void)commonInit
{
    _stateObservable = [[OAObservable alloc] init];
    _settingsObservable = [[OAObservable alloc] init];
    _framePreparedObservable = [[OAObservable alloc] init];

    // Set default values
    _glShareGroup = nil;
    _glRenderContext = nil;
    _glWorkerContext = nil;
    _depthRenderBuffer = 0;
    _colorRenderBuffer = 0;
    _frameBuffer = 0;
    _displayLink = nil;
    
    // Create map renderer instance
    _renderer = OsmAnd::createMapRenderer(OsmAnd::MapRendererClass::AtlasMapRenderer_OpenGLES2);
    const auto rendererConfig = std::static_pointer_cast<OsmAnd::AtlasMapRendererConfiguration>(_renderer->getConfiguration());
    rendererConfig->texturesFilteringQuality = OsmAnd::TextureFilteringQuality::Good;
    _renderer->setConfiguration(rendererConfig);
    
    OAObservable* stateObservable = _stateObservable;
    _renderer->stateChangeObservable.attach((__bridge const void*)_stateObservable,
        [stateObservable]
        (const OsmAnd::IMapRenderer* renderer, const OsmAnd::MapRendererStateChange thisChange, const uint32_t allChanges)
        {
            [stateObservable notifyEventWithKey:[NSNumber numberWithUnsignedInteger:(OAMapRendererViewStateEntry)thisChange]];
        });

    OAObservable* framePreparedObservable = _framePreparedObservable;
    _renderer->framePreparedObservable.attach((__bridge const void*)_framePreparedObservable,
        [framePreparedObservable]
        (const OsmAnd::IMapRenderer* renderer)
        {
            [framePreparedObservable notifyEvent];
        });

    // Create animator for that map
    _animator.reset(new OsmAnd::MapAnimator());
    _animator->setMapRenderer(_renderer);

#if defined(OSMAND_IOS_DEV)
    _forceRenderingOnEachFrame = NO;
#endif // defined(OSMAND_IOS_DEV)
}

- (void)deinit
{
    // Just to be sure, try to release context
    [self releaseContext];
    
    // Unregister observer
    _renderer->stateChangeObservable.detach((__bridge const void*)_stateObservable);
    _renderer->framePreparedObservable.detach((__bridge const void*)_framePreparedObservable);
}

- (std::shared_ptr<OsmAnd::IMapRasterBitmapTileProvider>)providerOf:(OsmAnd::RasterMapLayerId)layer
{
    return _renderer->getState().rasterLayerProviders[static_cast<int>(layer)];
}

- (void)setProvider:(std::shared_ptr<OsmAnd::IMapRasterBitmapTileProvider>)provider ofLayer:(OsmAnd::RasterMapLayerId)layer
{
    _renderer->setRasterLayerProvider(layer, provider);
}

- (void)removeProviderOf:(OsmAnd::RasterMapLayerId)layer
{
    _renderer->setRasterLayerProvider(layer, std::shared_ptr<OsmAnd::IMapRasterBitmapTileProvider>());
}

- (float)opacityOf:(OsmAnd::RasterMapLayerId)layer
{
    return _renderer->getState().rasterLayerOpacity[static_cast<int>(layer)];
}

- (void)setOpacity:(float)opacity ofLayer:(OsmAnd::RasterMapLayerId)layer
{
    _renderer->setRasterLayerOpacity(layer, opacity);
}

- (std::shared_ptr<OsmAnd::IMapElevationDataProvider>)elevationDataProvider
{
    return _renderer->getState().elevationDataProvider;
}

- (void)setElevationDataProvider:(std::shared_ptr<OsmAnd::IMapElevationDataProvider>)elevationDataProvider
{
    _renderer->setElevationDataProvider(elevationDataProvider);
}

- (float)elevationDataScale
{
    return _renderer->getState().elevationDataScaleFactor;
}

- (void)removeElevationDataProvider
{
    _renderer->setElevationDataProvider(std::shared_ptr<OsmAnd::IMapElevationDataProvider>());
}

- (void)setElevationDataScale:(float)elevationDataScale
{
    _renderer->setElevationDataScaleFactor(elevationDataScale);
}

- (void)addSymbolProvider:(std::shared_ptr<OsmAnd::IMapDataProvider>)provider
{
    _renderer->addSymbolProvider(provider);
}

- (void)removeSymbolProvider:(std::shared_ptr<OsmAnd::IMapDataProvider>)provider
{
    _renderer->removeSymbolProvider(provider);
}

- (void)removeAllSymbolProviders
{
    _renderer->removeAllSymbolProviders();
}

- (float)fieldOfView
{
    return _renderer->getState().fieldOfView;
}

- (void)setFieldOfView:(float)fieldOfView
{
    _renderer->setFieldOfView(fieldOfView);
}

- (float)azimuth
{
    return _renderer->getState().azimuth;
}

- (void)setAzimuth:(float)azimuth
{
    _renderer->setAzimuth(azimuth);
}

- (float)elevationAngle
{
    return _renderer->getState().elevationAngle;
}

- (void)setElevationAngle:(float)elevationAngle
{
    _renderer->setElevationAngle(elevationAngle);
}

- (OsmAnd::PointI)target31
{
    return _renderer->getState().target31;
}

- (void)setTarget31:(OsmAnd::PointI)target31
{
    _renderer->setTarget(target31);
}

- (float)zoom
{
    return _renderer->getState().requestedZoom;
}

- (void)setZoom:(float)zoom
{
    _renderer->setZoom(zoom);
}

- (OsmAnd::ZoomLevel)zoomLevel
{
    return _renderer->getState().zoomBase;
}

- (float)currentTileSizeOnScreenInPixels
{
    return std::dynamic_pointer_cast<OsmAnd::IAtlasMapRenderer>(_renderer)->getCurrentTileSizeOnScreenInPixels();
}

- (float)minZoom
{
    return _renderer->getMinZoom();
}

- (float)maxZoom
{
    return _renderer->getMaxZoom();
}

@synthesize stateObservable = _stateObservable;

- (QList<OsmAnd::TileId>)visibleTiles
{
    return std::dynamic_pointer_cast<OsmAnd::IAtlasMapRenderer>(_renderer)->getVisibleTiles();
}

- (BOOL)convert:(CGPoint)point toLocation:(OsmAnd::PointI*)location
{
    if (!location)
        return NO;
    return _renderer->getLocationFromScreenPoint(OsmAnd::PointI(static_cast<int32_t>(point.x), static_cast<int32_t>(point.y)), *location);
}

- (BOOL)convert:(CGPoint)point toLocation64:(OsmAnd::PointI64*)location
{
    if (!location)
        return NO;
    return _renderer->getLocationFromScreenPoint(OsmAnd::PointI(static_cast<int32_t>(point.x), static_cast<int32_t>(point.y)), *location);
}

@synthesize framePreparedObservable = _framePreparedObservable;

- (const std::shared_ptr<OsmAnd::MapAnimator>&)getAnimator
{
    return _animator;
}

- (void)createContext
{
    if (_glShareGroup != nil)
        return;

    OALog(@"[MapRenderView] Creating context");

    // Set layer to be opaque to reduce perfomance loss, and anyways we use all area for rendering
    CAEAGLLayer* eaglLayer = (CAEAGLLayer*)self.layer;
    eaglLayer.opaque = YES;
    
    // Create OpenGLES 2.0 contexts
    _glRenderContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!_glRenderContext)
    {
        [NSException raise:NSGenericException format:@"Failed to initialize OpenGLES 2.0 render context"];
        return;
    }
    _glShareGroup = [_glRenderContext sharegroup];
    if (!_glShareGroup)
    {
        [NSException raise:NSGenericException format:@"Failed to initialize OpenGLES 2.0 render context has no sharegroup"];
        return;
    }
    _glWorkerContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:_glShareGroup];
    if (!_glWorkerContext)
    {
        [NSException raise:NSGenericException format:@"Failed to initialize OpenGLES 2.0 worker context"];
        return;
    }
    
    // Set created context as current active
    if (![EAGLContext setCurrentContext:_glRenderContext])
    {
        [NSException raise:NSGenericException format:@"Failed to set current OpenGLES2 context"];
        return;
    }

    // Setup renderer
    OsmAnd::MapRendererSetupOptions rendererSetup;
    rendererSetup.gpuWorkerThreadEnabled = true;
    const auto capturedWorkerContext = _glWorkerContext;
    rendererSetup.gpuWorkerThreadPrologue =
        [capturedWorkerContext]
        (const OsmAnd::IMapRenderer* const renderer)
        {
            // Activate worker context
            if (![EAGLContext setCurrentContext:capturedWorkerContext])
            {
                [NSException raise:NSGenericException format:@"Failed to set current OpenGLES2 context in GPU worker thread"];
                return;
            }
        };
    rendererSetup.gpuWorkerThreadEpilogue =
        []
        (const OsmAnd::IMapRenderer* const renderer)
        {
            // Nothing to do
        };
    _renderer->setup(rendererSetup);

    // Initialize rendering
    if (!_renderer->initializeRendering())
    {
        [NSException raise:NSGenericException format:@"Failed to initialize OpenGLES2 map renderer"];
        return;
    }
    
    // Rendering needs to be resumed/started manually, since render target is not created yet
}

- (void)releaseContext
{
    if (_glShareGroup == nil)
        return;

    OALog(@"[MapRenderView] Releasing context");

    // Stop rendering (if it was running)
    [self suspendRendering];
    
    // Release map renderer
    if (!_renderer->releaseRendering())
    {
        [NSException raise:NSGenericException format:@"Failed to release OpenGLES2 map renderer"];
        return;
    }
    
    // Release render-buffers and framebuffer
    [self releaseRenderAndFrameBuffers];
    
    // Tear down contexts
    if ([EAGLContext currentContext] == _glRenderContext || [EAGLContext currentContext] == _glWorkerContext)
        [EAGLContext setCurrentContext:nil];
    _glWorkerContext = nil;
    _glRenderContext = nil;
    _glShareGroup = nil;
}

#if defined(DEBUG)
- (GLenum)validateOpenGLES
{
    GLenum result = glGetError();
    if (result == GL_NO_ERROR)
        return result;
    
    OALog(@"OpenGLES error 0x%08x", result);
    
    return result;
}
#endif

- (void)layoutSubviews
{
    OALog(@"[MapRenderView] Recreating OpenGLES2 frame and render buffers due to resize");

    // Kill buffers, since window was resized
    [self releaseRenderAndFrameBuffers];
}

- (void)allocateRenderAndFrameBuffers
{
    OALog(@"[MapRenderView] Allocating render and frame buffers");

    if (![EAGLContext setCurrentContext:_glRenderContext])
    {
        [NSException raise:NSGenericException format:@"Failed to set current OpenGLES2 context"];
        return;
    }
    
    // Setup frame-buffer
    glGenFramebuffers(1, &_frameBuffer);
    validateGL();
    NSAssert(_frameBuffer != 0, @"Failed to allocate frame buffer");
    glBindFramebuffer(GL_FRAMEBUFFER, _frameBuffer);
    validateGL();
    
    // Setup render buffer (color component)
    glGenRenderbuffers(1, &_colorRenderBuffer);
    validateGL();
    NSAssert(_colorRenderBuffer != 0, @"Failed to allocate render buffer (color component)");
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderBuffer);
    validateGL();
    if (![_glRenderContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer])
    {
        [NSException raise:NSGenericException format:@"Failed to create render buffer (color component)"];
        return;
    }
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_viewSize.x);
    validateGL();
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_viewSize.y);
    validateGL();
    OALog(@"[MapRenderView] View size %dx%d", _viewSize.x, _viewSize.y);

    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRenderBuffer);
    validateGL();

    // Setup render buffer (depth component)
    glGenRenderbuffers(1, &_depthRenderBuffer);
    validateGL();
    NSAssert(_depthRenderBuffer != 0, @"Failed to allocate render buffer (depth component)");
    glBindRenderbuffer(GL_RENDERBUFFER, _depthRenderBuffer);
    validateGL();
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24_OES, _viewSize.x, _viewSize.y);
    validateGL();
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthRenderBuffer);
    validateGL();
    
    // Check that we've initialized our framebuffer fully
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
    {
        [NSException raise:NSGenericException format:@"Failed to make complete framebuffer (0x%08x)", glCheckFramebufferStatus(GL_FRAMEBUFFER)];
        return;
    }
    validateGL();
}

- (void)releaseRenderAndFrameBuffers
{
    OALog(@"[MapRenderView] Releasing render and frame buffers");

    if (![EAGLContext setCurrentContext:_glRenderContext])
    {
        [NSException raise:NSGenericException format:@"Failed to set current OpenGLES2 context"];
        return;
    }
    
    if (_frameBuffer != 0)
    {
        glDeleteFramebuffers(1, &_frameBuffer);
        _frameBuffer = 0;
        validateGL();
    }
    if (_colorRenderBuffer != 0)
    {
        glDeleteRenderbuffers(1, &_colorRenderBuffer);
        _colorRenderBuffer = 0;
        validateGL();
    }
    if (_depthRenderBuffer != 0)
    {
        glDeleteRenderbuffers(1, &_depthRenderBuffer);
        _depthRenderBuffer = 0;
        validateGL();
    }
}

@synthesize settingsObservable = _settingsObservable;

- (void)render:(CADisplayLink*)displayLink
{
    if (![EAGLContext setCurrentContext:_glRenderContext])
    {
        [NSException raise:NSGenericException format:@"Failed to set current OpenGLES2 context"];
        return;
    }
    
    // Update animator
    _animator->update(displayLink.duration * displayLink.frameInterval);
    
    // Allocate buffers if they are not yet allocated
    if (_frameBuffer == 0)
    {
        // Allocate new buffers
        [self allocateRenderAndFrameBuffers];
        
        // Update size of renderer window and viewport
        _renderer->setWindowSize(_viewSize);
        _renderer->setViewport(OsmAnd::AreaI(OsmAnd::PointI(), _viewSize));
    }
    
    // Process update
    if (!_renderer->update())
    {
        [NSException raise:NSGenericException format:@"Failed to update OpenGLES2 map renderer"];
        return;
    }
    
    // Perform rendering only if frame is marked as invalidated
    bool shouldRenderFrame = false;
    shouldRenderFrame = shouldRenderFrame || _renderer->isFrameInvalidated();
#if defined(OSMAND_IOS_DEV)
    shouldRenderFrame = shouldRenderFrame || _forceRenderingOnEachFrame;
#endif // defined(OSMAND_IOS_DEV)
    if (_renderer->prepareFrame() && shouldRenderFrame)
    {
        // Activate framebuffer
        glBindFramebuffer(GL_FRAMEBUFFER, _frameBuffer);
        validateGL();
    
        // Clear buffer
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        validateGL();

        // Perform rendering
        if (!_renderer->renderFrame())
        {
            [NSException raise:NSGenericException format:@"Failed to render frame using OpenGLES2 map renderer"];
            return;
        }
        validateGL();
    
        //TODO: apply multisampling?
    
        // Erase depthbuffer, since not needed
        const GLenum buffersToDiscard[] =
        {
            GL_DEPTH_ATTACHMENT
        };
        glBindFramebuffer(GL_FRAMEBUFFER, _frameBuffer);
        validateGL();
        glDiscardFramebufferEXT(GL_FRAMEBUFFER, 1, buffersToDiscard);
        validateGL();
    
        // Present results
        glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderBuffer);
        validateGL();
        [_glRenderContext presentRenderbuffer:GL_RENDERBUFFER];
    }
}

- (BOOL)isRenderingSuspended
{
    return (_displayLink == nil);
}

- (BOOL)resumeRendering
{
    if (_displayLink != nil)
        return FALSE;
    
    if (![EAGLContext setCurrentContext:_glRenderContext])
    {
        [NSException raise:NSGenericException format:@"Failed to set current OpenGLES2 context"];
        return FALSE;
    }
    
    // Setup display link
    _displayLink = [CADisplayLink displayLinkWithTarget:self
                                               selector:@selector(render:)];
    [_displayLink addToRunLoop:[NSRunLoop currentRunLoop]
                       forMode:NSDefaultRunLoopMode];

    // Resume GPU worker thread
    _renderer->resumeGpuWorkerThread();
    
    OALog(@"[MapRenderView] Rendering resumed");

    return TRUE;
}

- (BOOL)suspendRendering
{
    if (_displayLink == nil)
        return FALSE;
    
    if (![EAGLContext setCurrentContext:_glRenderContext])
    {
        [NSException raise:NSGenericException format:@"Failed to set current OpenGLES2 context"];
        return FALSE;
    }
    
    // Release display link
    [_displayLink invalidate];
    _displayLink = nil;

    // Pause GPU worker thread
    _renderer->pauseGpuWorkerThread();
    
    OALog(@"[MapRenderView] Rendering suspended");

    return TRUE;
}

- (void)invalidateFrame
{
    _renderer->forcedFrameInvalidate();
}

- (CGFloat)referenceTileSizeOnScreenInPixels
{
    const auto configuration = std::static_pointer_cast<OsmAnd::AtlasMapRendererConfiguration>(_renderer->getConfiguration());
    return configuration->referenceTileSizeOnScreenInPixels;
}

- (void)setReferenceTileSizeOnScreenInPixels:(CGFloat)referenceTileSizeOnScreenInPixels
{
    const auto configuration = std::static_pointer_cast<OsmAnd::AtlasMapRendererConfiguration>(_renderer->getConfiguration());
    configuration->referenceTileSizeOnScreenInPixels = referenceTileSizeOnScreenInPixels;
    _renderer->setConfiguration(configuration);
}

#if defined(OSMAND_IOS_DEV)
@synthesize forceRenderingOnEachFrame = _forceRenderingOnEachFrame;
- (void)setForceRenderingOnEachFrame:(BOOL)forceRenderingOnEachFrame
{
    _forceRenderingOnEachFrame = forceRenderingOnEachFrame;

    [_settingsObservable notifyEvent];
}
#endif // defined(OSMAND_IOS_DEV)

@end
