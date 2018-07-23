#import "RNCamera.h"
#import "RNCameraUtils.h"
#import "RNImageUtils.h"
#import "RNFileSystem.h"
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/UIView+React.h>

@interface RNCamera ()

@property (nonatomic, weak) RCTBridge *bridge;

@property (nonatomic, assign, getter=isSessionPaused) BOOL paused;

@property (nonatomic, strong) RCTPromiseResolveBlock videoRecordedResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock videoRecordedReject;
@property (nonatomic, strong) id faceDetectorManager;

@property (nonatomic, copy) RCTDirectEventBlock onCameraReady;
@property (nonatomic, copy) RCTDirectEventBlock onMountError;
@property (nonatomic, copy) RCTDirectEventBlock onBarCodeRead;
@property (nonatomic, copy) RCTDirectEventBlock onFacesDetected;
@property (nonatomic, copy) RCTDirectEventBlock onAudioMetering;
@property (nonatomic, copy) RCTDirectEventBlock onCameraFeaturesDetected;

@end

@implementation RNCamera

static NSDictionary *defaultFaceDetectorOptions = nil;

- (id)initWithBridge:(RCTBridge *)bridge
{
    if ((self = [super init])) {
        self.bridge = bridge;
        self.session = [AVCaptureSession new];
        self.sessionQueue = dispatch_queue_create("cameraQueue", DISPATCH_QUEUE_SERIAL);
        self.faceDetectorManager = [self createFaceDetectorManager];
#if !(TARGET_IPHONE_SIMULATOR)
        self.previewLayer =
        [AVCaptureVideoPreviewLayer layerWithSession:self.session];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        self.previewLayer.needsDisplayOnBoundsChange = YES;
#endif
        self.paused = NO;
        [self changePreviewOrientation:[UIApplication sharedApplication].statusBarOrientation];
        [self initializeCaptureSessionInput];
        [self startSession];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(handleRouteChange:)
                                                name:AVAudioSessionRouteChangeNotification
                                            object:nil];

        self.autoFocus = -1;
        NSError *sessionError = nil;
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&sessionError];
        [audioSession setActive:YES error:&sessionError];

        NSURL *contentURL = [NSURL URLWithString:@"/dev/null"];
        NSMutableDictionary *recordSettings = [[NSMutableDictionary alloc] init];
        [recordSettings setObject:[NSNumber numberWithInt:kAudioFormatAppleLossless] forKey: AVFormatIDKey];
        [recordSettings setObject:[NSNumber numberWithFloat:22050.0] forKey: AVSampleRateKey];
        [recordSettings setObject:[NSNumber numberWithInt:1] forKey:AVNumberOfChannelsKey];
        [recordSettings setObject:[NSNumber numberWithInt:12800] forKey:AVEncoderBitRateKey];
        [recordSettings setObject:[NSNumber numberWithInt:16] forKey:AVLinearPCMBitDepthKey];
        [recordSettings setObject:[NSNumber numberWithInt: AVAudioQualityLow] forKey: AVEncoderAudioQualityKey];

        self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:contentURL settings:recordSettings error:nil];

        if([[AVAudioSession sharedInstance] respondsToSelector:@selector(requestRecordPermission:)]) {
            [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
                // RCTLogWarn(@"permission : %d", granted);
                // if(granted)[self setupMic];
            }];
        }

        [self.audioRecorder prepareToRecord];
        self.audioRecorder.meteringEnabled = YES;
        [self.audioRecorder record];
        [self.audioRecorder updateMeters];
        [self updateAudioMetering];

        //        [[NSNotificationCenter defaultCenter] addObserver:self
        //                                                 selector:@selector(bridgeDidForeground:)
        //                                                     name:EX_UNVERSIONED(@"EXKernelBridgeDidForegroundNotification")
        //                                                   object:self.bridge];
        //
        //        [[NSNotificationCenter defaultCenter] addObserver:self
        //                                                 selector:@selector(bridgeDidBackground:)
        //                                                     name:EX_UNVERSIONED(@"EXKernelBridgeDidBackgroundNotification")
        //                                                   object:self.bridge];

    }
    return self;
}

- (void)onReady:(NSDictionary *)event
{
    if (_onCameraReady) {
        _onCameraReady(nil);
    }
}

- (void)onMountingError:(NSDictionary *)event
{
    if (_onMountError) {
        _onMountError(event);
    }
}

- (void)onCodeRead:(NSDictionary *)event
{
    if (_onBarCodeRead) {
        _onBarCodeRead(event);
    }
}

- (void)onAudioMetering:(NSDictionary *)event
{
    if (_onAudioMetering) {
        _onAudioMetering(event);
    }
}

- (void)audioMeterTimer {
    [self.audioRecorder updateMeters]; // instance of AVAudioRecorder
    NSDictionary *event = @{
        @"averagePower" : [NSNumber numberWithFloat:[self.audioRecorder averagePowerForChannel:0]],
        @"peakPower" : [NSNumber numberWithFloat:[self.audioRecorder peakPowerForChannel:0]],
        };
    [self onAudioMetering:event];
}

- (void)startAudioMetering {
    if (!self.meterTimer) {
        self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.033 target:self selector:@selector(audioMeterTimer)userInfo:nil repeats:YES];
    }
}

- (void)stopAudioMetering {
    if ([self.meterTimer isValid]) {
        [self.meterTimer invalidate];
    }
    self.meterTimer = nil;
}

- (void)updateAudioMetering
{
    if ([self isAudioMeteringEnabled]) {
        [self startAudioMetering];
    } else {
        [self stopAudioMetering];
    }
}

- (void)onCameraFeaturesDetected:(NSDictionary *)event
{
    if (_onCameraFeaturesDetected) {
        _onCameraFeaturesDetected(event);
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.previewLayer.frame = self.bounds;
    [self setBackgroundColor:[UIColor blackColor]];
    [self.layer insertSublayer:self.previewLayer atIndex:0];
}

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
    [self insertSubview:view atIndex:atIndex + 1];
    [super insertReactSubview:view atIndex:atIndex];
    return;
}

- (void)removeReactSubview:(UIView *)subview
{
    [subview removeFromSuperview];
    [super removeReactSubview:subview];
    return;
}

- (void)removeFromSuperview
{
    [self stopSession];
    [super removeFromSuperview];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
}

-(void)updateType
{
    dispatch_async(self.sessionQueue, ^{
        [self initializeCaptureSessionInput];
        if (!self.session.isRunning) {
            [self startSession];
        }
    });
}

- (void)updateFrameRate
{
    // RCTLogWarn(@"configure for frame rate %d", self.frameRate);
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];

    AVCaptureDeviceFormat *matchingFormat = nil;
    BOOL matchingFormatFound = NO;

    for ( AVCaptureDeviceFormat *format in [device formats] ) {
        for ( AVFrameRateRange *range in format.videoSupportedFrameRateRanges ) {
            if ( range.minFrameRate <= (double)self.frameRate && range.maxFrameRate >= (double)self.frameRate) {
                matchingFormat = format;
                matchingFormatFound = YES;
                break;
            }
            if (matchingFormatFound) break;
        }
    }
    if ( matchingFormat ) {
        if ( [device lockForConfiguration:NULL] == YES ) {
            RCTLogWarn(@"matchingFormat found %@", matchingFormat);
            device.activeFormat = matchingFormat;
            device.activeVideoMinFrameDuration = CMTimeMake(1, (int)self.frameRate);
            device.activeVideoMaxFrameDuration = CMTimeMake(1, (int)self.frameRate);
            [device unlockForConfiguration];
        }
    }
}

- (void)updateFlashMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (self.flashMode == RNCameraFlashModeTorch) {
        if (![device hasTorch])
            return;
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasTorch && [device isTorchModeSupported:AVCaptureTorchModeOn])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                [device setFlashMode:AVCaptureFlashModeOff];
                [device setTorchMode:AVCaptureTorchModeOn];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    } else {
        if (![device hasFlash])
            return;
        if (![device lockForConfiguration:&error]) {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
            return;
        }
        if (device.hasFlash && [device isFlashModeSupported:self.flashMode])
        {
            NSError *error = nil;
            if ([device lockForConfiguration:&error]) {
                if ([device isTorchModeSupported:AVCaptureTorchModeOff]) {
                    [device setTorchMode:AVCaptureTorchModeOff];
                }
                [device setFlashMode:self.flashMode];
                [device unlockForConfiguration];
            } else {
                if (error) {
                    RCTLogError(@"%s: %@", __func__, error);
                }
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateAutoFocusPointOfInterest
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([self.autoFocusPointOfInterest objectForKey:@"x"] && [self.autoFocusPointOfInterest objectForKey:@"y"]) {
        float xValue = [self.autoFocusPointOfInterest[@"x"] floatValue];
        float yValue = [self.autoFocusPointOfInterest[@"y"] floatValue];
        if ([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {

            CGPoint autofocusPoint = CGPointMake(xValue, yValue);
            [device setFocusPointOfInterest:autofocusPoint];
            [device setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
          }
        else {
            RCTLogWarn(@"AutoFocusPointOfInterest not supported");
        }
    }

    [device unlockForConfiguration];
}

- (void)updateAutoExposureMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }


    if ([device isExposureModeSupported:self.autoExposure]) {
        if ([device lockForConfiguration:&error]) {
            [device setExposureMode:self.autoExposure];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateAutoExposurePointOfInterest
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([self.autoExposurePointOfInterest objectForKey:@"x"] && [self.autoExposurePointOfInterest objectForKey:@"y"]) {
        float xValue = [self.autoExposurePointOfInterest[@"x"] floatValue];
        float yValue = [self.autoExposurePointOfInterest[@"y"] floatValue];
        if ([device isExposurePointOfInterestSupported] && [device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            CGPoint autoExposurePoint = CGPointMake(xValue, yValue);
            [device setExposurePointOfInterest:autoExposurePoint];
            [device setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
          }
        else {
            RCTLogWarn(@"AutoExposurePointOfInterest not supported");
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusMode
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if ([device isFocusModeSupported:self.autoFocus]) {
        if ([device lockForConfiguration:&error]) {
            [device setFocusMode:self.autoFocus];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

- (void)updateFocusDepth
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (self.autoFocus < 0 || device.focusMode != RNCameraAutoFocusOff || device.position == RNCameraTypeFront) {
        return;
    }

    if (![device respondsToSelector:@selector(isLockingFocusWithCustomLensPositionSupported)] || ![device isLockingFocusWithCustomLensPositionSupported]) {
        RCTLogWarn(@"%s: Setting focusDepth isn't supported for this camera device", __func__);
        return;
    }

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    __weak __typeof__(device) weakDevice = device;
    [device setFocusModeLockedWithLensPosition:self.focusDepth completionHandler:^(CMTime syncTime) {
        [weakDevice unlockForConfiguration];
    }];
}

- (void)updateZoom {
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    device.videoZoomFactor = (device.activeFormat.videoMaxZoomFactor - 1.0) * self.zoom + 1.0;

    [device unlockForConfiguration];
}

- (void)updateWhiteBalance
{
    AVCaptureDevice *device = [self.videoCaptureDeviceInput device];
    NSError *error = nil;

    if (![device lockForConfiguration:&error]) {
        if (error) {
            RCTLogError(@"%s: %@", __func__, error);
        }
        return;
    }

    if (self.whiteBalance == RNCameraWhiteBalanceAuto) {
        [device setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        [device unlockForConfiguration];
    } else {
        AVCaptureWhiteBalanceTemperatureAndTintValues temperatureAndTint = {
            .temperature = [RNCameraUtils temperatureForWhiteBalance:self.whiteBalance],
            .tint = 0,
        };
        AVCaptureWhiteBalanceGains rgbGains = [device deviceWhiteBalanceGainsForTemperatureAndTintValues:temperatureAndTint];
        __weak __typeof__(device) weakDevice = device;
        if ([device lockForConfiguration:&error]) {
            [device setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:rgbGains completionHandler:^(CMTime syncTime) {
                [weakDevice unlockForConfiguration];
            }];
        } else {
            if (error) {
                RCTLogError(@"%s: %@", __func__, error);
            }
        }
    }

    [device unlockForConfiguration];
}

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
- (void)updateFaceDetecting:(id)faceDetecting
{
    [_faceDetectorManager setIsEnabled:faceDetecting];
}

- (void)updateFaceDetectionMode:(id)requestedMode
{
    [_faceDetectorManager setMode:requestedMode];
}

- (void)updateFaceDetectionLandmarks:(id)requestedLandmarks
{
    [_faceDetectorManager setLandmarksDetected:requestedLandmarks];
}

- (void)updateFaceDetectionClassifications:(id)requestedClassifications
{
    [_faceDetectorManager setClassificationsDetected:requestedClassifications];
}
#endif

- (void)takePicture:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
    int orientation;
    if ([options[@"orientation"] integerValue]) {
        orientation = [options[@"orientation"] integerValue];
    } else {
        orientation = [RNCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]];
    }
    [connection setVideoOrientation:orientation];
    [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler: ^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
        if (imageSampleBuffer && !error) {
            NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];

            UIImage *takenImage = [UIImage imageWithData:imageData];

            CGRect frame = [_previewLayer metadataOutputRectOfInterestForRect:self.frame];
            CGImageRef takenCGImage = takenImage.CGImage;
            size_t width = CGImageGetWidth(takenCGImage);
            size_t height = CGImageGetHeight(takenCGImage);
            CGRect cropRect = CGRectMake(frame.origin.x * width, frame.origin.y * height, frame.size.width * width, frame.size.height * height);
            takenImage = [RNImageUtils cropImage:takenImage toRect:cropRect];

            if ([options[@"mirrorImage"] boolValue]) {
                takenImage = [RNImageUtils mirrorImage:takenImage];
            }
            if ([options[@"forceUpOrientation"] boolValue]) {
                takenImage = [RNImageUtils forceUpOrientation:takenImage];
            }

            if ([options[@"width"] integerValue]) {
                takenImage = [RNImageUtils scaleImage:takenImage toWidth:[options[@"width"] integerValue]];
            }

            NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
            float quality = [options[@"quality"] floatValue];
            NSData *takenImageData = UIImageJPEGRepresentation(takenImage, quality);
            NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".jpg"];
            response[@"uri"] = [RNImageUtils writeImage:takenImageData toPath:path];
            response[@"width"] = @(takenImage.size.width);
            response[@"height"] = @(takenImage.size.height);

            if ([options[@"base64"] boolValue]) {
                response[@"base64"] = [takenImageData base64EncodedStringWithOptions:0];
            }



            if ([options[@"exif"] boolValue]) {
                int imageRotation;
                switch (takenImage.imageOrientation) {
                    case UIImageOrientationLeft:
                    case UIImageOrientationRightMirrored:
                        imageRotation = 90;
                        break;
                    case UIImageOrientationRight:
                    case UIImageOrientationLeftMirrored:
                        imageRotation = -90;
                        break;
                    case UIImageOrientationDown:
                    case UIImageOrientationDownMirrored:
                        imageRotation = 180;
                        break;
                    case UIImageOrientationUpMirrored:
                    default:
                        imageRotation = 0;
                        break;
                }
                [RNImageUtils updatePhotoMetadata:imageSampleBuffer withAdditionalData:@{ @"Orientation": @(imageRotation) } inResponse:response]; // TODO
            }

            resolve(response);
        } else {
            reject(@"E_IMAGE_CAPTURE_FAILED", @"Image could not be captured", error);
        }
    }];
}

- (void)record:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
    if (_movieFileOutput == nil) {
        // At the time of writing AVCaptureMovieFileOutput and AVCaptureVideoDataOutput (> GMVDataOutput)
        // cannot coexist on the same AVSession (see: https://stackoverflow.com/a/4986032/1123156).
        // We stop face detection here and restart it in when AVCaptureMovieFileOutput finishes recording.
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager stopFaceDetection];
#endif
        [self setupMovieFileCapture];
    }

    if (self.movieFileOutput == nil || self.movieFileOutput.isRecording || _videoRecordedResolve != nil || _videoRecordedReject != nil) {
      return;
    }

    if (options[@"maxDuration"]) {
        Float64 maxDuration = [options[@"maxDuration"] floatValue];
        self.movieFileOutput.maxRecordedDuration = CMTimeMakeWithSeconds(maxDuration, 30);
    }

    if (options[@"maxFileSize"]) {
        self.movieFileOutput.maxRecordedFileSize = [options[@"maxFileSize"] integerValue];
    }

    if (options[@"quality"]) {
        [self updateSessionPreset:[RNCameraUtils captureSessionPresetForVideoResolution:(RNCameraVideoResolution)[options[@"quality"] integerValue]]];
    }

    [self updateSessionAudioIsMuted:!!options[@"mute"]];

    AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:[RNCameraUtils videoOrientationForDeviceOrientation:[[UIDevice currentDevice] orientation]]];

    if (options[@"codec"]) {
      AVVideoCodecType videoCodecType = options[@"codec"];
      if (@available(iOS 10, *)) {
        if ([self.movieFileOutput.availableVideoCodecTypes containsObject:videoCodecType]) {
          [self.movieFileOutput setOutputSettings:@{AVVideoCodecKey:videoCodecType} forConnection:connection];
          self.videoCodecType = videoCodecType;
        } else {
          RCTLogWarn(@"%s: Video Codec '%@' is not supported on this device.", __func__, videoCodecType);
        }
      } else {
        RCTLogWarn(@"%s: Setting videoCodec is only supported above iOS version 10.", __func__);
      }
    }

    dispatch_async(self.sessionQueue, ^{
        [self updateFlashMode];
        NSString *path = [RNFileSystem generatePathInDirectory:[[RNFileSystem cacheDirectoryPath] stringByAppendingPathComponent:@"Camera"] withExtension:@".mov"];
        NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:path];
        [self.movieFileOutput startRecordingToOutputFileURL:outputURL recordingDelegate:self];
        self.videoRecordedResolve = resolve;
        self.videoRecordedReject = reject;
    });
}

- (void)stopRecording
{
    [self.movieFileOutput stopRecording];
}

- (void)detectCameraFeatures
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif

    NSMutableDictionary *cameraFeatures = [[NSMutableDictionary alloc] init];

    // AUDIO
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];

    // active input
    for (AVAudioSessionPortDescription *desc in audioSession.currentRoute.inputs) {
        cameraFeatures[@"activeAudioInputType"] = desc.portType;
        cameraFeatures[@"activeAudioInputName"] = desc.portName;
    }

    // https://stackoverflow.com/questions/46612223/avaudiorecorder-avaudiosession-with-apple-airpods
    // available inputs
    NSMutableArray *availableAudioInputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *desc in audioSession.availableInputs) {
        // RCTLogWarn(@"av input route desc %@", desc);
        [availableAudioInputs addObject: desc.portType];
    }
    cameraFeatures[@"availableAudioInputs"] = availableAudioInputs;


    //  AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    //  RCTLogWarn(@"default audio device %@", audioCaptureDevice);

    // // available inputs
    // if (@available(iOS 10.0, *)) {
    //     AVCaptureDeviceDiscoverySession *audioInputs = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInMicrophone] mediaType:AVMediaTypeAudio position:AVCaptureDevicePositionUnspecified];
    //     for(AVCaptureDevice *device in audioInputs.devices) {
    //         RCTLogWarn(@"audio input type %@", device);
    //     }
    // } else {
    //     // Fallback on earlier versions
    // }



    // CAMERAS

    // active camera
    AVCaptureDevice *activeDevice = self.videoCaptureDeviceInput.device;
    NSString *activeDevicePositon = @"Unspecified";
            if (activeDevice.position == AVCaptureDevicePositionFront) {
              activeDevicePositon = @"Front";
            }
            if (activeDevice.position == AVCaptureDevicePositionBack) {
              activeDevicePositon = @"Back";
            }
    NSMutableDictionary *activeDeviceFormats = [NSMutableDictionary new];
    for ( AVCaptureDeviceFormat *format in [activeDevice formats] ) {
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        NSString *dimensionKey = [NSString stringWithFormat:@"%dx%d", dimensions.width, dimensions.height];
        NSMutableArray *formatsForDimensions = activeDeviceFormats[dimensionKey] ?activeDeviceFormats[dimensionKey] : [NSMutableArray array];
        NSMutableArray *frameRateRangesForFormat = [NSMutableArray array];
        for ( AVFrameRateRange *range in [format videoSupportedFrameRateRanges] ) {
            NSDictionary *rangeDetails = @{
                @"minFrameRate" : [NSString stringWithFormat:@"%f", range.minFrameRate],
                @"maxFrameRate" : [NSString stringWithFormat:@"%f", range.maxFrameRate],
                };
            [frameRateRangesForFormat addObject: rangeDetails];
        }
        NSDictionary *formatDetails = @{
                                      @"width" : [NSNumber numberWithInt:dimensions.width],
                                      @"height" : [NSNumber numberWithInt:dimensions.height],
                                      @"frameRateRanges" : frameRateRangesForFormat,
                                      };
        [formatsForDimensions addObject: formatDetails];
        activeDeviceFormats[dimensionKey] = formatsForDimensions;
    }
    NSDictionary *activeDeviceDetails = @{
                @"deviceType" : [NSString stringWithFormat:@"%@", activeDevice.deviceType],
                @"position" : [NSString stringWithFormat:@"%@", activeDevicePositon],
                @"modelID" : [NSString stringWithFormat:@"%@", activeDevice.modelID],
                @"localizedName" : [NSString stringWithFormat:@"%@", activeDevice.localizedName],
                @"lensAperture" : [NSString stringWithFormat:@"%f", activeDevice.lensAperture],
                @"exposurePointOfInterestSupported": activeDevice.exposurePointOfInterestSupported ? [NSNumber numberWithBool:YES] : [NSNumber numberWithBool:NO],
                @"focusPointOfInterestSupported": activeDevice.focusPointOfInterestSupported ? [NSNumber numberWithBool:YES] : [NSNumber numberWithBool:NO],
                @"formats": activeDeviceFormats,
            };
    cameraFeatures[@"activeCamera"] = activeDeviceDetails;

    // available cameras
    if (@available(iOS 10.0, *)) {

        NSArray *allTypes = @[];
        if (@available(iOS 11.1, *)) {
            allTypes = @[AVCaptureDeviceTypeBuiltInTrueDepthCamera, AVCaptureDeviceTypeBuiltInDualCamera, AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInTelephotoCamera ];
        } else if (@available(iOS 10.2, *)) {
            allTypes = @[AVCaptureDeviceTypeBuiltInDualCamera, AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInTelephotoCamera ];
        } else {
            allTypes = @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInTelephotoCamera ];
        }

        NSMutableArray *availableCameras = [NSMutableArray array];
        AVCaptureDeviceDiscoverySession *discoveredCameras = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:allTypes mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
        for(AVCaptureDevice *device in discoveredCameras.devices) {
            // array of devices
            // RCTLogWarn(@"device: %@", device);

            // device formats
            NSMutableDictionary *cameraFormats = [NSMutableDictionary new];
            for ( AVCaptureDeviceFormat *format in [device formats] ) {
                // RCTLogWarn(@"format: %@", format);
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
                NSString *dimensionKey = [NSString stringWithFormat:@"%dx%d", dimensions.width, dimensions.height];
                NSMutableArray *formatsForDimensions = cameraFormats[dimensionKey] ? cameraFormats[dimensionKey] : [NSMutableArray array];
                NSMutableArray *frameRateRangesForFormat = [NSMutableArray array];
                for ( AVFrameRateRange *range in [format videoSupportedFrameRateRanges] ) {
                    NSDictionary *rangeDetails = @{
                        @"minFrameRate" : [NSString stringWithFormat:@"%f", range.minFrameRate],
                        @"maxFrameRate" : [NSString stringWithFormat:@"%f", range.maxFrameRate],
                        };
                    [frameRateRangesForFormat addObject: rangeDetails];
                }
                NSDictionary *formatDetails = @{
                                              @"width" : [NSNumber numberWithInt:dimensions.width],
                                              @"height" : [NSNumber numberWithInt:dimensions.height],
                                              @"frameRateRanges" : frameRateRangesForFormat,
                                              };
                [formatsForDimensions addObject: formatDetails];
                cameraFormats[dimensionKey] = formatsForDimensions;
            }

            NSString *devicePositon = @"Unspecified";
            if (device.position == AVCaptureDevicePositionFront) {
              devicePositon = @"Front";
            }
            if (device.position == AVCaptureDevicePositionBack) {
              devicePositon = @"Back";
            }

            NSDictionary *deviceDetails = @{
                @"deviceType" : [NSString stringWithFormat:@"%@", device.deviceType],
                @"position" : [NSString stringWithFormat:@"%@", devicePositon],
                @"modelID" : [NSString stringWithFormat:@"%@", device.modelID],
                @"localizedName" : [NSString stringWithFormat:@"%@", device.localizedName],
                @"lensAperture" : [NSString stringWithFormat:@"%f", device.lensAperture],
                @"exposurePointOfInterestSupported": device.exposurePointOfInterestSupported ? [NSNumber numberWithBool:YES] : [NSNumber numberWithBool:NO],
                @"focusPointOfInterestSupported": device.focusPointOfInterestSupported ? [NSNumber numberWithBool:YES] : [NSNumber numberWithBool:NO],
                @"formats": cameraFormats,
            };
            [availableCameras addObject: deviceDetails];
        }
        cameraFeatures[@"availableCameras"] = availableCameras;
    }
    [self onCameraFeaturesDetected:cameraFeatures];
}

- (void)startSession
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    //    NSDictionary *cameraPermissions = [EXCameraPermissionRequester permissions];
    //    if (![cameraPermissions[@"status"] isEqualToString:@"granted"]) {
    //        [self onMountingError:@{@"message": @"Camera permissions not granted - component could not be rendered."}];
    //        return;
    //    }
    dispatch_async(self.sessionQueue, ^{
        if (self.presetCamera == AVCaptureDevicePositionUnspecified) {
            return;
        }

        self.session.sessionPreset = AVCaptureSessionPresetPhoto;
        
        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        if ([self.session canAddOutput:stillImageOutput]) {
            stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
            [self.session addOutput:stillImageOutput];
            [stillImageOutput setHighResolutionStillImageOutputEnabled:YES];
            self.stillImageOutput = stillImageOutput;
        }

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
#else
        // If AVCaptureVideoDataOutput is not required because of Google Vision
        // (see comment in -record), we go ahead and add the AVCaptureMovieFileOutput
        // to avoid an exposure rack on some devices that can cause the first few
        // frames of the recorded output to be underexposed.
        [self setupMovieFileCapture];
#endif
        [self setupOrDisableBarcodeScanner];

        __weak RNCamera *weakSelf = self;
        [self setRuntimeErrorHandlingObserver:
         [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:nil usingBlock:^(NSNotification *note) {
            RNCamera *strongSelf = weakSelf;
            dispatch_async(strongSelf.sessionQueue, ^{
                // Manually restarting the session since it must
                // have been stopped due to an error.
                [strongSelf.session startRunning];
                [strongSelf onReady:nil];
            });
        }]];

        [self.session startRunning];
        [self onReady:nil];

        [self detectCameraFeatures];
    });
}

- (void)stopSession
{
#if TARGET_IPHONE_SIMULATOR
    return;
#endif
    dispatch_async(self.sessionQueue, ^{
#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
        [_faceDetectorManager stopFaceDetection];
#endif
        [self.previewLayer removeFromSuperlayer];
        [self.session commitConfiguration];
        [self.session stopRunning];
        for (AVCaptureInput *input in self.session.inputs) {
            [self.session removeInput:input];
        }

        for (AVCaptureOutput *output in self.session.outputs) {
            [self.session removeOutput:output];
        }
    });
}

- (void)initializeCaptureSessionInput
{
    // commented to allow for changing to telephoto lens while on back camera
    // if (self.videoCaptureDeviceInput.device.position == self.presetCamera) {
    //     return;
    // }

    __block UIInterfaceOrientation interfaceOrientation;

    void (^statusBlock)() = ^() {
        interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    };
    if ([NSThread isMainThread]) {
        statusBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), statusBlock);
    }

    AVCaptureVideoOrientation orientation = [RNCameraUtils videoOrientationForInterfaceOrientation:interfaceOrientation];
    dispatch_async(self.sessionQueue, ^{
        if (@available(iOS 10.0, *)) {
          [self.session beginConfiguration];
          
          NSError *error = nil;
          
          AVCaptureDeviceType prefferedDeviceType = AVCaptureDeviceTypeBuiltInWideAngleCamera;
          // set to telephoto
          if (self.useTelephoto) {
            prefferedDeviceType = AVCaptureDeviceTypeBuiltInTelephotoCamera;
          }
          AVCaptureDevice *captureDevice = [RNCameraUtils deviceWithMediaType:AVMediaTypeVideo preferringPosition:self.presetCamera preferringDeviceType:prefferedDeviceType];
          
          AVCaptureDeviceInput *captureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:captureDevice error:&error];
          
          if (error || captureDeviceInput == nil) {
            RCTLog(@"%s: %@", __func__, error);
            return;
          }
          
          [self.session removeInput:self.videoCaptureDeviceInput];
          if ([self.session canAddInput:captureDeviceInput]) {
            [self.session addInput:captureDeviceInput];
            
            self.videoCaptureDeviceInput = captureDeviceInput;
            [self updateFlashMode];
            [self updateZoom];
            [self updateFocusMode];
            [self updateFocusDepth];
            [self updateAutoFocusPointOfInterest];
            [self updateWhiteBalance];
            [self.previewLayer.connection setVideoOrientation:orientation];
            [self _updateMetadataObjectsToRecognize];
            [self updateFrameRate];
          }
          
          [self.session commitConfiguration];
        }
      
    });
}

#pragma mark - internal

- (void)updateSessionPreset:(NSString *)preset
{
#if !(TARGET_IPHONE_SIMULATOR)
    if (preset) {
        dispatch_async(self.sessionQueue, ^{
            [self.session beginConfiguration];
            if ([self.session canSetSessionPreset:preset]) {
                self.session.sessionPreset = preset;
            }
            [self.session commitConfiguration];
        });
    }
#endif
}

- (void)updateSessionAudioIsMuted:(BOOL)isMuted
{
    dispatch_async(self.sessionQueue, ^{
        [self.session beginConfiguration];

        for (AVCaptureDeviceInput* input in [self.session inputs]) {
            if ([input.device hasMediaType:AVMediaTypeAudio]) {
                if (isMuted) {
                    [self.session removeInput:input];
                }
                [self.session commitConfiguration];
                return;
            }
        }

        if (!isMuted) {
            NSError *error = nil;

            AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];

            if (error || audioDeviceInput == nil) {
                RCTLogWarn(@"%s: %@", __func__, error);
                return;
            }

            if ([self.session canAddInput:audioDeviceInput]) {
                [self.session addInput:audioDeviceInput];
            }
        }

        [self.session commitConfiguration];
    });
}

- (void)bridgeDidForeground:(NSNotification *)notification
{

    if (![self.session isRunning] && [self isSessionPaused]) {
        self.paused = NO;
        dispatch_async( self.sessionQueue, ^{
            [self.session startRunning];
        });
    }
}

- (void)bridgeDidBackground:(NSNotification *)notification
{
    if ([self.session isRunning] && ![self isSessionPaused]) {
        self.paused = YES;
        dispatch_async( self.sessionQueue, ^{
            [self.session stopRunning];
        });
    }
}

- (void)orientationChanged:(NSNotification *)notification
{
    UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
    [self changePreviewOrientation:orientation];
}

- (void)changePreviewOrientation:(UIInterfaceOrientation)orientation
{
    __weak typeof(self) weakSelf = self;
    AVCaptureVideoOrientation videoOrientation = [RNCameraUtils videoOrientationForInterfaceOrientation:orientation];
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.previewLayer.connection.isVideoOrientationSupported) {
            [strongSelf.previewLayer.connection setVideoOrientation:videoOrientation];
        }
    });
}

- (void)handleRouteChange:(NSNotification *)notification
{
    NSNumber *reasonValue = [[notification userInfo] objectForKey:AVAudioSessionRouteChangeReasonKey];
    NSString *reasonPreviousRoute = [[notification userInfo] objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
    // RCTLogWarn(@"SESSION ROUTE CHANGED %@ %@", reasonValue, reasonPreviousRoute);

    [self detectCameraFeatures];

    // AVCaptureDevice *audioCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    // RCTLogWarn(@"audioCaptureDevice %@", audioCaptureDevice);

    // switch (reasonValue.unsignedIntegerValue) {
    //     case AVAudioSessionRouteChangeReasonNewDeviceAvailable: {
    //             RCTLogWarn(@"new device");
    //         } break;
    //     case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: {
    //             RCTLogWarn(@"device removed");
    //         } break;
    //     default:
    //         break;
    // }

}

# pragma mark - AVCaptureMetadataOutput

- (void)setupOrDisableBarcodeScanner
{
    [self _setupOrDisableMetadataOutput];
    [self _updateMetadataObjectsToRecognize];
}

- (void)_setupOrDisableMetadataOutput
{
    if ([self isReadingBarCodes] && (_metadataOutput == nil || ![self.session.outputs containsObject:_metadataOutput])) {
        AVCaptureMetadataOutput *metadataOutput = [[AVCaptureMetadataOutput alloc] init];
        if ([self.session canAddOutput:metadataOutput]) {
            [metadataOutput setMetadataObjectsDelegate:self queue:self.sessionQueue];
            [self.session addOutput:metadataOutput];
            self.metadataOutput = metadataOutput;
        }
    } else if (_metadataOutput != nil && ![self isReadingBarCodes]) {
        [self.session removeOutput:_metadataOutput];
        _metadataOutput = nil;
    }
}

- (void)_updateMetadataObjectsToRecognize
{
    if (_metadataOutput == nil) {
        return;
    }

    NSArray<AVMetadataObjectType> *availableRequestedObjectTypes = [[NSArray alloc] init];
    NSArray<AVMetadataObjectType> *requestedObjectTypes = [NSArray arrayWithArray:self.barCodeTypes];
    NSArray<AVMetadataObjectType> *availableObjectTypes = _metadataOutput.availableMetadataObjectTypes;

    for(AVMetadataObjectType objectType in requestedObjectTypes) {
        if ([availableObjectTypes containsObject:objectType]) {
            availableRequestedObjectTypes = [availableRequestedObjectTypes arrayByAddingObject:objectType];
        }
    }

    [_metadataOutput setMetadataObjectTypes:availableRequestedObjectTypes];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputMetadataObjects:(NSArray *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection
{
    for(AVMetadataObject *metadata in metadataObjects) {
        if([metadata isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            AVMetadataMachineReadableCodeObject *codeMetadata = (AVMetadataMachineReadableCodeObject *) metadata;
            for (id barcodeType in self.barCodeTypes) {
                if ([metadata.type isEqualToString:barcodeType]) {
                    AVMetadataMachineReadableCodeObject *transformed = (AVMetadataMachineReadableCodeObject *)[_previewLayer transformedMetadataObjectForMetadataObject:metadata];
                    NSDictionary *event = @{
                                            @"type" : codeMetadata.type,
                                            @"data" : codeMetadata.stringValue,
                                            @"bounds": @{
                                                @"origin": @{
                                                    @"x": [NSString stringWithFormat:@"%f", transformed.bounds.origin.x],
                                                    @"y": [NSString stringWithFormat:@"%f", transformed.bounds.origin.y]
                                                },
                                                @"size": @{
                                                    @"height": [NSString stringWithFormat:@"%f", transformed.bounds.size.height],
                                                    @"width": [NSString stringWithFormat:@"%f", transformed.bounds.size.width]
                                                }
                                            }
                                            };

                    [self onCodeRead:event];
                }
            }
        }
    }
}

# pragma mark - AVCaptureMovieFileOutput

- (void)setupMovieFileCapture
{
    AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];

    if ([self.session canAddOutput:movieFileOutput]) {
        [self.session addOutput:movieFileOutput];
        self.movieFileOutput = movieFileOutput;
    }
}

- (void)cleanupMovieFileCapture
{
    if ([_session.outputs containsObject:_movieFileOutput]) {
        [_session removeOutput:_movieFileOutput];
        _movieFileOutput = nil;
    }
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    BOOL success = YES;
    if ([error code] != noErr) {
        NSNumber *value = [[error userInfo] objectForKey:AVErrorRecordingSuccessfullyFinishedKey];
        if (value) {
            success = [value boolValue];
        }
    }
    if (success && self.videoRecordedResolve != nil) {
      AVVideoCodecType videoCodec = self.videoCodecType;
      if (videoCodec == nil) {
        videoCodec = [self.movieFileOutput.availableVideoCodecTypes firstObject];
      }

      self.videoRecordedResolve(@{ @"uri": outputFileURL.absoluteString, @"codec":videoCodec });
    } else if (self.videoRecordedReject != nil) {
        self.videoRecordedReject(@"E_RECORDING_FAILED", @"An error occurred while recording a video.", error);
    }
    self.videoRecordedResolve = nil;
    self.videoRecordedReject = nil;
    self.videoCodecType = nil;

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    [self cleanupMovieFileCapture];

    // If face detection has been running prior to recording to file
    // we reenable it here (see comment in -record).
    [_faceDetectorManager maybeStartFaceDetectionOnSession:_session withPreviewLayer:_previewLayer];
#endif

    if (self.session.sessionPreset != AVCaptureSessionPresetPhoto) {
        [self updateSessionPreset:AVCaptureSessionPresetPhoto];
    }
}

# pragma mark - Face detector

- (id)createFaceDetectorManager
{
    Class faceDetectorManagerClass = NSClassFromString(@"RNFaceDetectorManager");
    Class faceDetectorManagerStubClass = NSClassFromString(@"RNFaceDetectorManagerStub");

#if __has_include(<GoogleMobileVision/GoogleMobileVision.h>)
    if (faceDetectorManagerClass) {
        return [[faceDetectorManagerClass alloc] initWithSessionQueue:_sessionQueue delegate:self];
    } else if (faceDetectorManagerStubClass) {
        return [[faceDetectorManagerStubClass alloc] init];
    }
#endif

    return nil;
}

- (void)onFacesDetected:(NSArray<NSDictionary *> *)faces
{
    if (_onFacesDetected) {
        _onFacesDetected(@{
                           @"type": @"face",
                           @"faces": faces
                           });
    }
}

@end
