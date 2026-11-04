FORZA MOBILE CAM — STAGE 2
Android Controller Application Source
Version: 0.2.0

WHAT THIS STAGE ADDS
- Native Android controller UI (landscape).
- WebSocket connection to the Stage 1 Windows Bridge.
- WASD analog joystick for camera movement.
- Relative mouse touchpad for camera look.
- E/Q vertical movement buttons.
- Mouse wheel zoom.
- Photo Mode quick actions: P, R, Enter, F1, Esc.
- Hold Shift and hold right mouse button.
- Gyroscope camera control with sensitivity and X/Y inversion.
- Gyroscope bias calibration.
- ARM / Emergency Stop.
- Remembers PC IP and port (the session token is not saved).

IMPORTANT COMPATIBILITY
This Android app speaks the same WebSocket protocol as Forza Mobile Cam Stage 1.
Keep the Stage 1 Windows Bridge running on the PC.
Default ports:
- WebSocket: 8765
- Browser test panel: 8766

The app sends standard Windows keyboard and mouse input through the Bridge.
It does not patch game files, inject code into the game, or access game memory.
The game must accept the relevant keyboard/mouse controls. Actual camera bindings
may differ based on your Forza version and in-game key bindings.

REQUIREMENTS TO BUILD THE APK
- Windows 10/11 PC.
- Flutter SDK (stable channel) installed and added to PATH.
- Android Studio installed with Android SDK and Android SDK Platform Tools.
- Internet connection for the first dependency download.
- Android phone for testing.

INSTALL FLUTTER
Follow the official guide:
https://docs.flutter.dev/get-started/install/windows/mobile

Install Android Studio:
https://developer.android.com/studio

After installation, open Command Prompt and run:
  flutter doctor

Resolve Android toolchain warnings before continuing. If Flutter asks for Android
licenses, run:
  flutter doctor --android-licenses

CREATE THE PROJECT
1. Extract ForzaMobileCam_Stage2.zip.
2. Double-click setup_flutter_project.bat.
3. The script creates a folder named ForzaMobileCamAndroid.
4. It copies the application source and runs flutter pub get.

BUILD APK
1. Open ForzaMobileCamAndroid.
2. Double-click build_apk.bat.
3. Wait for the build to finish.
4. APK location:
   ForzaMobileCamAndroid\build\app\outputs\flutter-apk\app-release.apk
5. Copy the APK to Android and install it. If Android blocks installation, allow
   installation from the file manager/browser used to open the APK.

RUN DIRECTLY FOR TESTING
- Enable Developer Options and USB Debugging on Android.
- Connect the phone to PC by USB.
- Accept the USB debugging prompt.
- Run run_android.bat inside ForzaMobileCamAndroid.

CONNECT THE APP TO STAGE 1
1. Start Stage 1 run_bridge.bat on the PC.
2. Note the PC LAN IPv4 address shown in the Bridge console.
3. Note the session token shown in the same console.
4. Connect the phone and PC to the same Wi-Fi network.
5. Open Forza Mobile Cam on Android.
6. Tap CONNECT.
7. Enter the PC IP, port 8765, and the current session token.
8. Tap Connect in the dialog.
9. Tap ARM before sending any input.

FIRST TEST
1. Keep Forza closed initially.
2. Open Notepad on the PC and click inside the document.
3. Connect the Android app to the Bridge.
4. Tap ARM.
5. Move the left joystick. W/A/S/D should appear in Notepad.
6. Drag the camera touchpad. The Windows mouse should move.
7. Press STOP.
8. Only after this works, test in Forza Photo Mode or cockpit free look.

GYROSCOPE CALIBRATION
1. Connect and ARM the app.
2. Turn on GYROSCOPE.
3. Hold the phone in the same landscape orientation you will use.
4. Keep it still and tap the calibration icon.
5. Wait until "Kalibrasi selesai" appears.
6. Move the phone gently and adjust Gyro gain.
7. If the direction is reversed, toggle INV X or INV Y.

SAFETY
- ARM is required before any input is sent.
- STOP releases all held keys and mouse buttons.
- The app sends STOP when it is backgrounded or disconnected.
- Do not share the session token.
- Do not expose the Bridge ports to the public internet.
- Test in Notepad before testing in-game.
- Avoid testing camera controls while the game is driving a vehicle at speed.

KNOWN LIMITATIONS IN STAGE 2
- Mode chips (PHOTO / COCKPIT / DRONE) are UI profiles, not automatic game mode switches.
- Photo Mode key mapping must be verified in your actual game configuration.
- Gyroscope axis mapping can vary by phone sensor orientation; use INV X / INV Y and gain.
- This stage does not read the game's camera coordinates or unlock internal camera features.
- Door, hood, trunk, and vehicle animation controls are not implemented.
- The app source is provided; this package does not contain a prebuilt APK because
  APK compilation requires the Android SDK and Flutter toolchain on a build machine.

TROUBLESHOOTING
- Flutter not found: install Flutter and add its bin folder to PATH, then reopen CMD.
- Android licenses: run flutter doctor --android-licenses.
- Gradle/SDK error: open Android Studio > SDK Manager and install the SDK components
  requested by flutter doctor.
- App cannot connect: verify PC IP, port 8765, current token, same Wi-Fi, and Windows
  Firewall Private-network permission for Python.
- Gyro does not move camera: verify the app is ARM, turn gyro on, calibrate while still,
  adjust gain, and try INV X / INV Y.
- Input works in Notepad but not game: check the game's keyboard/mouse bindings and
  the correct camera mode.

NEXT STAGE
Stage 3 will focus on verifying and tuning Forza camera controls:
- Photo Mode camera translation and rotation.
- Cockpit Mouse Free Look.
- Drone mode behavior.
- Correct key bindings for the user's game build.
- Gyroscope smoothing, dead zone, and recenter behavior.


CLOUD BUILD
Untuk membangun APK tanpa Android Studio, ikuti CLOUD_BUILD_GUIDE_ID.txt.
