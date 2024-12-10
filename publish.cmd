@echo off
SETLOCAL EnableDelayedExpansion
cd %~dp0
SET ROOT=%~dp0
set WINGET_SRC=%ROOT%..\winget-pkgs
for /f "usebackq" %%i in (`%ROOT%\tools\xsl -e -s %ROOT%\src\Version\version.xsl %ROOT%\src\Version\version.props`) do (
    set VERSION=%%i
)

if "%VERSION%" == "" goto :noversion

echo ### Publishing version %VERSION%...
set WINGET=1
set GITRELEASE=1
set UPLOAD=1
set PUBLISH=%ROOT%\src\Application\bin\Release\app.publish
set WIXBIN=%ProgramFiles% (x86)\WiX Toolset v3.14\bin

:parse
if "%1"=="/nowinget" set WINGET=0
if "%1"=="/norelease" set GITRELEASE=0
if "%1"=="/noupload" set UPLOAD=0
if "%1"=="" goto :done
shift
goto :parse

:done
where sed > nul 2>&1
if ERRORLEVEL 1 goto :nosed

if EXIST "%ROOT%\publish" rd /s /q "%ROOT%\publish"
if EXIST "%PUBLISH%" rd /s /q "%PUBLISH%"

git clean -dfx

call .\build.cmd

msbuild /target:publish src\xmlnotepad.sln /p:Configuration=Release "/p:Platform=Any CPU"
if ERRORLEVEL 1 goto :nobits
if not EXIST %PUBLISH%\XmlNotepad.application goto :nobits

move "%PUBLISH%" "%ROOT%\publish"

if not EXIST "%WIXBIN%\WixUtilExtension.dll" goto :nowix

echo Building XmlNotepadSetup.msi...
msbuild src\xmlnotepadsetup.sln /p:Configuration=Release /target:XmlNotepadSetup /p:OutDir=bin\Release\
if ERRORLEVEL 1 goto :err_setup
if not EXIST src\XmlNotepadSetup\bin\Release\XmlNotepadSetup.msi goto :nomsi

echo Building XmlNotepadPackage and Bundle...
msbuild /target:build src\xmlnotepadsetup.sln /p:Configuration=Release "/p:Platform=Any CPU"
if ERRORLEVEL 1 goto :noappx

if EXIST src\XmlNotepadSetup\bin\Release\XmlNotepadSetup.zip del src\XmlNotepadSetup\bin\Release\XmlNotepadSetup.zip
if "%LOVETTSOFTWARE_STORAGE_CONNECTION_STRING%" == "" goto :nokey

copy /y src\Updates\Updates.xml publish\
if ERRORLEVEL 1 goto :eof
copy /y src\Updates\Updates.xslt publish\
if ERRORLEVEL 1 goto :eof
copy /y src\Updates\Updates.xsd publish\
if ERRORLEVEL 1 goto :eofn
copy /y src\Updates\Updates.xml src\XmlNotepadSetup\bin\Release\
if ERRORLEVEL 1 goto :eof
copy /y src\Updates\Updates.xslt src\XmlNotepadSetup\bin\Release\
if ERRORLEVEL 1 goto :eof
copy /y src\Updates\Updates.xsd src\XmlNotepadSetup\bin\Release\
if ERRORLEVEL 1 goto :eof
if exist publish\XmlNotepadSetup.zip del publish\XmlNotepadSetup.zip
pwsh -command "Compress-Archive -Path src\XmlNotepadSetup\bin\Release\* -DestinationPath publish\XmlNotepadSetup.zip"

set bundle=%ROOT%\src\XmlNotepadPackage\AppPackages\%VERSION%\XmlNotepadPackage_%VERSION%_Test\XmlNotepadPackage_%VERSION%_AnyCPU.msixbundle
if not EXIST %bundle% goto :noappx
set zipfile=publish\XmlNotepadSetup.zip

if "%GITRELEASE%" == "0" goto :upload

echo Creating new release for version %VERSION%
%ROOT%\tools\xsl -e -s src\Updates\LatestVersion.xslt src\Updates\Updates.xml > notes.txt
gh release create %VERSION% "%bundle%" "%zipfile%" --notes-file notes.txt --title "Xml Notepad %VERSION%"
if ERRORLEVEL 1 goto :nogh
del notes.txt

:upload
if "%UPLOAD%" == "0" goto :winget

echo Uploading ClickOnce installer to XmlNotepad
call AzurePublishClickOnce.cmd publish downloads/XmlNotepad "%LOVETTSOFTWARE_STORAGE_CONNECTION_STRING%"
if ERRORLEVEL 1 goto :uploadfailed


echo ============ Done publishing ClickOnce installer to XmlNotepad ==============
:winget

where wingetcreate > nul 2>&1
if ERRORLEVEL 1 winget install wingetcreate
winget upgrade wingetcreate

if "%WINGET%"=="0" goto :skipwinget
if not exist %WINGET_SRC% goto :nowinget

echo Syncing winget master branch
pushd %WINGET_SRC%\manifests\m\Microsoft\XMLNotepad
git checkout master
if ERRORLEVEL 1 goto :eof
git pull
if ERRORLEVEL 1 goto :eof
git fetch upstream master
if ERRORLEVEL 1 goto :eof
git merge upstream/master
if ERRORLEVEL 1 goto :eof
git push
if ERRORLEVEL 1 goto :eof

set OLDEST=
for /f "usebackq" %%i in (`dir /b`) do (
  if "!OLDEST!" == "" set OLDEST=%%i
)

if "!OLDEST!" == "" goto :prepare
echo ======================== Replacing "!OLDEST!" version...

git mv "!OLDEST!" %VERSION%
if ERRORLEVEL 1 goto :gitError "git mv !OLDEST! %VERSION%"

:prepare
popd

echo Preparing winget package
set TARGET=%WINGET_SRC%\manifests\m\Microsoft\XMLNotepad\%VERSION%\
if not exist %TARGET% mkdir %TARGET%
copy /y tools\Microsoft.XMLNotepad*.yaml  %TARGET%
winget update wingetcreate
wingetcreate update Microsoft.XMLNotepad --version %VERSION% -o %WINGET_SRC% -u https://github.com/microsoft/XmlNotepad/releases/download/%VERSION%/XmlNotepadPackage_%VERSION%_AnyCPU.msixbundle
if ERRORLEVEL 1 goto :eof

pushd %TARGET%
winget validate .
if ERRORLEVEL 1 goto :installfailed
winget install -m .
if ERRORLEVEL 1 goto :installfailed

git checkout -b "clovett/xmlnotepad_%VERSION%"
if ERRORLEVEL 1 call :gitError "git checkout -b clovett/xmlnotepad_%VERSION%"
git add *
if ERRORLEVEL 1 call :gitError "git add *"
git commit -a -m "XML Notepad version %VERSION%"
if ERRORLEVEL 1 call :gitError "git commit -a -m 'XML Notepad version %VERSION%'"
git push -u origin "clovett/xmlnotepad_%VERSION%"
if ERRORLEVEL 1 call :gitError "git push -u origin clovett/xmlnotepad_%VERSION%

echo =============================================================================================================
echo Please create Pull Request for the new "clovett/xmlnotepad_%VERSION%" branch.

call gitweb
:skipwinget
goto :eof

:noversion
echo Failed to find the VERSION in src\Version\version.props
exit /b 1

:nobits
echo '%PUBLISH%' folder not found, so the build failed, please manually run release build and publish first.
exit /b 1

:nomsi
echo 'XmlNotepadSetup\bin\Release\XmlNotepadSetup.msi' not found, please use src\XmlNotepadSetup.sln to build the msi.
exit /b 1

:nokey
echo Please set your LOVETTSOFTWARE_STORAGE_CONNECTION_STRING
exit /b 1

:noappx
echo Please build the .msixbundle using src\XmlNotepadSetup.sln XmlNotepadPackage project, publish/create appx packages.
exit /b 1

:nosed
echo Missing sed.exe tool, please add c:\Program Files\Git\usr\bin to your PATH
exit /b 1

:installfailed
echo winget install failed
exit /b 1

:nowinget
echo Please clone git@github.com:lovettchris/winget-pkgs.git into %WINGET_SRC%
exit /b 1

:nowix
echo Please install the wixtoolset to %WIXBIN%, and add this to your PATH
exit /b 1

:err_setup
popd
echo src\XmlNotepadSetup build failed, try building inside XmlNotepadSetup.sln and ensure candle.exe command line matches this script
exit /b 1


:skipwinget
echo Skipping winget setup
exit /b 1

:uploadfailed
echo Upload to Azure failed.
exit /b 1

:gitError
echo ### error : %1
exit /b 1

:nogh
echo ### gh release failed, do you need to run gh auth login?
exit /b 1