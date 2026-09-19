@echo off
REM Copy Taxi debug APK + keystore into the running Appium Pod.
REM Windows kubectl cp cannot use C:\... (parsed as a pod name) — we cd first.
REM Edit DEMO if native-appium-demo lives elsewhere.
setlocal EnableDelayedExpansion

set NS=e2e
set DEMO=C:\workspaces\JavaProjects\native-appium-demo

where kubectl >nul 2>&1
if errorlevel 1 (
  echo [ERROR] kubectl not found in PATH.
  exit /b 1
)

if not exist "%DEMO%\apks\app-debug.apk" (
  echo [ERROR] Missing APK: %DEMO%\apks\app-debug.apk
  echo Build Taxi and run copy-apk.bat in native-appium-demo first.
  exit /b 1
)

if not exist "%DEMO%\config\my-debug-keystore.jks" (
  echo [ERROR] Missing keystore: %DEMO%\config\my-debug-keystore.jks
  exit /b 1
)

for /f "delims=" %%i in ('kubectl -n %NS% get pod -l app=appium-emulator -o jsonpath="{.items[0].metadata.name}" 2^>nul') do set POD=%%i

if "%POD%"=="" (
  echo [ERROR] No pod with label app=appium-emulator in namespace %NS%.
  echo Is the Deployment running?  kubectl -n %NS% get pods
  exit /b 1
)

echo [INFO] Pod: %POD%

pushd "%DEMO%\apks"
kubectl -n %NS% cp .\app-debug.apk "%POD%:/home/androidusr/apks/app-debug.apk"
if errorlevel 1 (
  popd
  echo [ERROR] kubectl cp APK failed.
  exit /b 1
)
popd

pushd "%DEMO%\config"
kubectl -n %NS% cp .\my-debug-keystore.jks "%POD%:/home/androidusr/config/my-debug-keystore.jks"
if errorlevel 1 (
  popd
  echo [ERROR] kubectl cp keystore failed.
  exit /b 1
)
popd

echo [INFO] Verifying...
kubectl -n %NS% exec %POD% -- ls -lh /home/androidusr/apks /home/androidusr/config
echo [OK] Copied APK and keystore into %POD%
echo Re-run this script after OOMKilled, RESTARTS, or a rolling update.
exit /b 0
