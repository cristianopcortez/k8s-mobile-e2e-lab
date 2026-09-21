@echo off
REM Run native-appium-demo TestNG suite against Appium on localhost:4723 (kubectl port-forward).
REM Run on the Docker Desktop / kubectl host. Keep port-forward 4723 open in another window.
REM Edit DEMO if native-appium-demo lives elsewhere.
setlocal

set DEMO=C:\workspaces\JavaProjects\native-appium-demo
set APPIUM_SERVER_URL=http://localhost:4723

where mvn >nul 2>&1
if errorlevel 1 (
  echo [ERROR] mvn not found in PATH.
  exit /b 1
)

if not exist "%DEMO%\pom.xml" (
  echo [ERROR] No pom.xml in %DEMO%
  echo Edit DEMO at the top of this script if the project path differs.
  exit /b 1
)

echo [INFO] APPIUM_SERVER_URL=%APPIUM_SERVER_URL%
echo [INFO] SELENIUM_REMOTE_URL unset (Chrome on host; no Grid in this cluster).
echo [INFO] Requires: kubectl -n e2e port-forward svc/appium 4723:4723
echo.

set "SELENIUM_REMOTE_URL="
pushd "%DEMO%"
call mvn test
set "MVN_EXIT=%ERRORLEVEL%"
popd
exit /b %MVN_EXIT%
