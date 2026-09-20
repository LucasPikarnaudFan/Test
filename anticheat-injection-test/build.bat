@echo off
setlocal

set SRC=src
set OUT=out

if not exist %OUT% mkdir %OUT%

javac -d %OUT% %SRC%\TestPayloadAgent.java
if errorlevel 1 goto :error

javac --add-modules jdk.attach -d %OUT% %SRC%\Injector.java
if errorlevel 1 goto :error

jar --create --file %OUT%\agent.jar --manifest %SRC%\agent-manifest.mf -C %OUT% TestPayloadAgent.class
if errorlevel 1 goto :error

echo.
echo Build OK.
echo   Agent jar:  %OUT%\agent.jar
echo   Injector:   %OUT%\Injector.class
echo.
echo Run against your own running Recube/Minecraft process:
echo   java --add-modules jdk.attach -cp %OUT% Injector --list
echo   java --add-modules jdk.attach -cp %OUT% Injector recube %OUT%\agent.jar
goto :eof

:error
echo Build failed.
exit /b 1
