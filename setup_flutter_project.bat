@echo off
setlocal
cd /d "%~dp0"
title Forza Mobile Cam - Setup Android Project

echo ==============================================
echo       FORZA MOBILE CAM - ANDROID SETUP
echo ==============================================
echo.

where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter SDK was not found in PATH.
  echo.
  echo Install Flutter and Android Studio first.
  echo Flutter: https://docs.flutter.dev/get-started/install/windows/mobile
  echo Android Studio: https://developer.android.com/studio
  echo.
  pause
  exit /b 1
)

if exist "ForzaMobileCamAndroid" (
  echo Folder ForzaMobileCamAndroid already exists.
  echo Rename or move it before running setup again.
  pause
  exit /b 1
)

echo Creating Android Flutter project...
flutter create --platforms=android --org com.forzamobilecam --project-name forza_mobile_cam ForzaMobileCamAndroid
if errorlevel 1 (
  echo Flutter project creation failed.
  pause
  exit /b 1
)

echo Copying Forza Mobile Cam application files...
copy /y "source\lib\main.dart" "ForzaMobileCamAndroid\lib\main.dart" >nul
copy /y "source\pubspec.yaml" "ForzaMobileCamAndroid\pubspec.yaml" >nul
copy /y "source\android\app\src\main\AndroidManifest.xml" "ForzaMobileCamAndroid\android\app\src\main\AndroidManifest.xml" >nul

(
echo @echo off
echo cd /d "%%~dp0"
echo flutter pub get
echo if errorlevel 1 ^(
echo   pause
echo   exit /b 1
echo ^)
echo flutter build apk --release
echo if errorlevel 1 ^(
echo   pause
echo   exit /b 1
echo ^)
echo echo.
echo echo APK output:
echo echo build\app\outputs\flutter-apk\app-release.apk
echo pause
) > "ForzaMobileCamAndroid\build_apk.bat"

(
echo @echo off
echo cd /d "%%~dp0"
echo flutter pub get
echo flutter run
echo pause
) > "ForzaMobileCamAndroid\run_android.bat"

cd /d "ForzaMobileCamAndroid"
echo.
echo Downloading Flutter dependencies...
flutter pub get
if errorlevel 1 (
  echo Dependency setup failed. Check your internet connection and Flutter installation.
  pause
  exit /b 1
)

echo.
echo Setup complete.
echo Next: run build_apk.bat to build the Android APK.
echo Or run run_android.bat with an Android phone connected by USB and USB debugging enabled.
echo.
pause
