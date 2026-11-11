## 2.9.9
### Feature
- Windows: Fixed the maximum length of data sent by Windows sendCustomCmdMsg is 8 characters

## 2.9.8
### Dependency Notes
- macOS SDK update to 12.3.16995
- Windows SDK update to 12.3.0.15893
### Feature
- Windows: Added six interfaces including screen sharing blacklist and whitelist
- Windows: Non-video scenes support multiple instances

## 2.9.7
### Bug Fix
- Adapt to flutter 3.29.0

## 2.9.6
### Dependency Notes
- Android SDK update to 12.3.0.+
- iOS SDK update to 12.3.16995

## 2.9.5
### Optimize
- iOS: Optimizing Texture rendering on iOS devices

## 2.9.4
### Bug Fix
- Fix XCode 14 compatibility issues
### Dependency Notes
- Android SDK update to 12.2.0.+

## 2.9.3
### Dependency Notes
- Android SDK update to 12.2.0.15065
- iOS SDK update to 12.2.16945
- macOS SDK update to 12.2.16945
- Windows SDK update to 12.2.0.15661

## 2.9.2
### Bug Fix
- Adapt to flutter 3.24.4

## 2.9.1
### Dependency Notes
- Android SDK update to 12.1.0.14886
- iOS SDK update to 12.1.16597
- macOS SDK update to 12.1.16597
- Windows SDK update to 12.1.0.15400

## 2.9.0
### Dependency Notes
- Android SDK update to 12.0.0.14689
- iOS SDK update to 12.0.16301
- Windows SDK update to 12.0.1.6060
### Feature
- Windows&MacOS: Newly added `onSystemAudioLoopbackError` callback.
- Android&iOS&Windows&MacOS: Newly added `preloadMusic` API

## 2.8.9
### Bug Fix
- iOS: Fix iOS setCameraZoomRatio can only set integers.
- iOS&Android&MacOS: Fix unable to cancel watermark.

## 2.8.8
### Bug Fix
- Web: Fixed the issue that the introduction of ffi library caused web compilation errors.

## 2.8.7
### Dependency Notes
- Windows SDK update to 12.0.1.6058

## 2.8.6
### Dependency Notes
- MacOS SDK update to 12.0.16292
### Feature
- MacOS: Newly added `enableFollowingDefaultAudioDevice` API.
- MacOS: Newly added `startSystemAudioLoopback` interface, supporting system audio capture, such as third-party music players.
- Android&iOS&Windows&MacOS: Newly added `startSpeedTestWithParams` API and `onSpeedTestResult` callback.
### Bug Fix
- iOS: The `onStatistics` callback parameter parsing field on iOS is aligned with Android, and `receivedBytes` is changed to `receiveBytes`.

## 2.8.5
### Dependency Notes
- Windows SDK update to 12.0.1.6002

## 2.8.4
### Dependency Notes
- Windows SDK update to 12.0.0.15124
### Feature
- Windows: Newly added `enableFollowingDefaultAudioDevice` API.

## 2.8.3
### Dependency Notes
- Android SDK update to 11.9.0.14466
- iOS SDK update to 11.9.15963

## 2.8.2
### Feature
- Android&iOS: Newly added `onAudioRouteChanged` callback.
- Added new audio route such as `TRTC_AUDIO_ROUTE_WIREDHEADSET`, see TRTCCloudDef for details.
### Bug Fix
- Windows: Fixed `onDeviceChange` callback not triggered

## 2.8.1
### Feature
- Android&iOS: Newly added `setVoicePitch` API
- Added new reverb effects such as `Studio 2`, see TXVoiceReverbType for details.

## 2.8.0
### Feature
- Windows: Newly added `getScreenCaptureSources` and `selectScreenCaptureTarget` API to support Windows screen sharing.

## 2.7.9
### Dependency Notes
* Android SDK update to 11.8.0.14188
* iOS SDK update to 11.8.15687

## 2.7.8
### Dependency Notes
- Windows SDK update to 11.7.0.14863
- MacOS SDK update to 11.7.15304
- Android SDK update to 11.7.0.13910
- iOS SDK update to 11.7.15343
### Feature
- Android&iOS: Newly added `createSubCloud` and `destroySubCloud` API
### Bug Fix
- Windows: Fixed `onRecvCustomCmdMsg` callback data parsing error problem

## 2.7.7
### Bug Fix
- Web: Fixed the issue where the switchRole call was invalid.

## 2.7.6
### Bug Fix
- Windows: Fix the data upload issue in Window library.

## 2.7.5
### Feature
- Windows: Updated `startSystemAudioLoopback` interface to support collecting sounds of specific applications

## 2.7.4
### Feature
- Windows: Newly added `startSystemAudioLoopback` interface, supporting system audio capture, such as third-party music players.

## 2.7.3
### Bug Fix
- Web: Fixed the issue of Web platform compilation failure caused by the introduction of dart:ffi.

## 2.7.2
### Dependency Notes
- Window: Upgraded client SDK version to 11.4.0.

## 2.7.1
### Bug Fix
- macOS: Fix the problem of occasional crash during TexTure rendering.
### Feature
- Android&iOS:: Added new `setAudioFrameListener` API.

## 2.7.0
### Feature
- Web: Upgrade the Web TRTC SDK to the latest version (v5) for more stable functionality.

### Bug Fixes
- Web: Fixed the issue where the screen sharing from Android and iOS devices couldn't be viewed in the Web version.

## 2.6.0
### Bug Fixes
- Web: Fix the exception issues when invoking the `getCurrentDevice` and `getDevicesList` APIs.

## 2.5.9
### Feature
- Android&iOS: Added new `startPublishMediaStream` API 
- Android&iOS: Added new `updatePublishMediaStream` API
- Android&iOS: Added new `stopPublishMediaStream` API

## 2.5.8
### Feature
- Replace the document jump link to the international site

## 2.5.7
### Dependency Notes
- Android SDK update to 11.4.0.13189
- iOS SDK update to 11.4.14445
- macOS SDK update to 11.4.14445

## 2.5.6
### Bug Fixes
- Windows: Optimize Dart code style
## 2.5.5
### Dependency Notes
- Android SDK update to 11.3.0.13200
- iOS SDK update to 11.3.14354
- macOS SDK update to 11.3.14333

## 2.5.4
### Dependency Notes
- Android SDK update to 11.3.0.13176
- iOS SDK update to 11.3.14333

## 2.5.3
### Dependency Notes
- Android SDK update to 11.2.13145
- iOS SDK update to 11.2.14217

## 2.5.2
### Bug Fixes
- Windows: Fixed the issue with the `startSpeedTest` function returning overly long data events and having no response;
- Web: Marked `setAudioPlayoutVolume` and `getAudioPlayoutVolume` as unavailable.

## 2.5.1
### Feature 
- Windows&Mac&Web: Restored support for Windows&Mac&Web platforms.
- iOS: Added a new `setSystemAudioLoopbackVolume` API, which supports adjusting the system volume while screen sharing.

### Bug Fixes
- iOS: Fixed occasional memory leak issues with `TRTCCloudVideoView` under specific scenarios.

### Dependency Notes
- Windows&Mac: Upgraded client SDK version to 11.1.0.


## 2.5.0
- Temporarily removed Web/MacOs/Windows

## 2.4.6

Android SDK update to 11.1.0.13111
iOS SDK update to 11.1.14143

## 2.4.5

Android: startSystemAudioLoopback

## 2.4.4

optimize some code

## 2.4.2-release

Android SDK update to 10.9.0.24004

## 2.4.2

Fix ios snapshotVideo null

## 2.4.1

Android SDK update to 10.8.0.13065
iOS SDK update to 10.8.12025

## 2.4.0

optimize some code

## 2.3.9

Android SDK update to 10.7.0.13053
iOS SDK update to 10.7.11936

## 2.3.8

optimize windows add related dll files automatically

## 2.3.7

Fix web "Can't use 'Function' as a name"

## 2.3.6

optimize some code

## 2.3.5

Android SDK update to 10.3.0.11196
iOS SDK update to 10.3.12231

## 2.3.4

update windows/macos/web
supports purevideo

## 2.3.3

setMixTranscodingConfig-supports only mixed video

## 2.3.2

Android/iOS SDK update to 10.3

## 2.3.1

optimize some code

## 2.3.0

Android/iOS SDK update to 10.1 width LiteAVSDK_Professional

## 2.2.5

Support third-party beauty
Android SDK set to 10.1.0.11109, iOS SDK set to 9.9.11217

## 2.2.4

Optimize setMixTranscodingConfig interface

## 2.2.3

Android SDK set to 9.9.0.11820, iOS SDK set to 9.5.11346

## 2.2.2

update log module

## 2.2.1

Platformview supports 'onTap' event

## 2.2.0

update Android/iOS SDK to TXLiteAVSDK_Live

## 2.1.7

fix bug 2.1.6 version ios video render

## 2.1.6

optimize ios texture

## 2.1.5

updateRemoteView adjust parameter order

## 2.1.4

Update docs

## 2.1.3

Update docs

## 2.1.2

Android SDK update to 9.5.11207, iOS SDK update to 9.5.11207

## 2.1.1

Fix the problem of wrong onSpeedTest callback data

## 2.1.0

Optimized initialization timing

## 2.0.9

Bug fix not find web folder

## 2.0.8

Android & IOS SDK update to 9.5

## 2.0.7

Resolve the warnings

## 2.0.6

Delete web folder

## 2.0.5

Optimize document display

## 2.0.1

Encapsulate video texture rendering into platformview

## 2.0.0

Support for fluent web.

## 1.3.1

Optimize some documents

## 1.3.0

Android video surfaceview rendering changed to glsurfaceview

## 1.2.9

Update the underlying Android SDK version to 9.3.10765

## 1.2.8

The underlying glsufaceview of Android is replaced by TextureView, and updateview only supports TextureView

## 1.2.7

Screen sharing supports streams of specified size

## 1.2.6

Fix IOS video rendering problem caused by previous version

## 1.2.5

Android video rendering supports mixed integration mode. The default mode is virtual display mode. The viewmode of trtcloudvideoview is transmitted to trtclouddef TRTC*VideoView* Model\_ Hybrid

## 1.2.4

Texture rendering is supported on the windows side of fluent, and fluent English documents are available online

## 1.2.3

Android supports updatelocalView and updateRemoteview interfaces

## 1.2.2

Fixed Android texture rendering multiplayer switch video memory growth

## 1.2.1

Optimized some functions

## 1.2.0

Specified return value of beauty, equipment and sound effect management module

## 1.1.9

Fix the problem of IOS and MacOS screenshots failing & other problems.

## 1.1.8

Android texture rendering is meglhelper compatible

## 1.1.7

Fix the missing businessInfo field of Android

## 1.1.6

Some functions are optimized.

## 1.1.5

Fix crash when there are special string parameters when playing music in release mode under IOS and MacOS

## 1.1.4

Fix crash in special string parameters under IOS and MacOS

## 1.1.3

*Fix that the onspeedtest callback under IOS and MacOS has no network quality data
*Fix the problem that the Android texture rendering meglcore is null

## 1.1.2

Fix that IOS and MacOS do not support auxiliary flow rendering

## 1.1.1

New texture rendering form

## 1.1.0

Fix the problem that Android stopremoteview and then startremoteview video cannot be rendered

## 1.0.9

Android and IOS support local recording startlocal recording

## 1.0.8

It supports windows and MacOS. At present, it only supports audio related interfaces, and video rendering is not supported temporarily

## 1.0.5

Fix the platformexception error after the Android video view is destroyed

## 1.0.4

IOS adds updatelocalView and updateRemoteview interfaces

## 1.0.3

Fix the problem that setaudioroute is invalid after Android turns off the microphone

## 1.0.2

Modify document comments

## 1.0.1

Fix the problem that Android roomid cannot enter the room when it exceeds 2147483647. Value range support: 1 - 4294967294

## 1.0.0

Upgrade flutter2.0 0, null safety is supported

## 0.2.3

IOS fixed the optional problem returned by onrecvcustomcmdmsguserid and onrecvseimsg

## 0.2.2

TRTC shuttle SDK removes the path\_ Provider dependency

## 0.2.1

Support screen sharing startscreencapture

## 0.2.0

Fix bug when IOS viewtype is specified as surfaceview

## 0.1.9

Fix the bug of data returned by IOS onuservoicevolume callback

## 0.1.8

Some functions have been optimized

## 0.1.7

It is modified to introduce the online package of Android SDK

## 0.1.6

Enter the room and add the strroomid parameter, which supports the incoming string room

## 0.1.5

Optimize code structure and update documents

## 0.1.4

Update document

## 0.1.3

The trtcloudlistenerenum enumeration class is modified to trtcloudlistener, which is not downward compatible. When upgrading to this version or above, you need to change the event listener to trtcloudlistener

## 0.1.2

New friend cloud push interface

## 0.1.1

Add custom message sending interface

## 0.1.0

Optimize the code and remove the onaudiouroutechanged callback

## 0.0.9

Fix some warnings in xocde runtime

## 0.0.8

Update document

## 0.0.7

*Added startpublishing, stoppublishing, setvideomuteimage, setlogdirpath and setlogdirpath interfaces
*Update the native IOS version and repair the onerror and onsetmixtranscodingconfig callbacks of IOS

## 0.0.6

Update document

## 0.0.5

*Trtcloud adds connectotherroom, disconnectotherroom and switchroom interfaces
*Txdevicemanager adds enablecameraautofocus and isautofocusenabled interfaces

## 0.0.4

*IOS fixed the problem of current sound after opening the ear return setting sound effect
*Android trtcloudvideoview adds a viewtype parameter, supports surfaceview and TextureView, and the default is TextureView

## 0.0.3

Update document

## 0.0.1

Initialize the project, encapsulate the shuttle TRTC SDK, based on Android SDK and IOS SDK

## 0.0.3

Update document

## 0.0.1

Initialize the project, encapsulate the shuttle TRTC SDK, based on Android SDK and IOS SDKs
