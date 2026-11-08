@echo off
setlocal
set "TOOL=%~dp0"
set "SOURCE_URL=https://raw.githubusercontent.com/rensei11/00-tools/2d83a2e4509154350ec8014728a1c23d8cf8a38f/ai-voice/bootstrap/v1/version_archive_manager.py"
set "SOURCE_SHA256=aabf96ea94f5c06742a1f727ec7bcec5c9dd868b837a424b796825ff2bcdf8ea"
set "STAGED=%TOOL%_backup\ai_voice_version_archive\staged\manager-%SOURCE_SHA256%.py"
set "EXITCODE=0"
echo AI Voice version archive preparation
echo ------------------------------------
if not exist "%TOOL%app.py" (
    echo RESULT: FAILED - Save this CMD in the installed AI Voice tool folder.
    goto fail
)
set "PYTHON=py.exe -3"
where py.exe >nul 2>nul
if errorlevel 1 (
    set "PYTHON=python.exe"
    where python.exe >nul 2>nul
    if errorlevel 1 (
        echo RESULT: FAILED - Windows Python was not found.
        goto fail
    )
)
echo Step 1/2: Verify and prepare archive program.
%PYTHON% -c "import sys,pathlib,urllib.request,hashlib; root=pathlib.Path(sys.argv[1]); dest=pathlib.Path(sys.argv[2]); parents=(root,root/'_backup',root/'_backup'/'ai_voice_version_archive',dest.parent); assert not any(p.is_symlink() for p in parents),'Unsafe archive path'; data=urllib.request.urlopen(urllib.request.Request(sys.argv[3],headers={'User-Agent':'AI-Voice-Archive-Prepare/1'}),timeout=45).read(25000); assert hashlib.sha256(data).hexdigest()==sys.argv[4],'Downloaded program checksum mismatch'; dest.parent.mkdir(parents=True,exist_ok=True); assert not dest.exists() or dest.read_bytes()==data,'Existing archive program differs'; dest.write_bytes(data) if not dest.exists() else None" "%TOOL%" "%STAGED%" "%SOURCE_URL%" "%SOURCE_SHA256%"
if errorlevel 1 (
    echo RESULT: FAILED - Could not verify the archive program.
    goto fail
)
echo Step 2/2: Save and verify the currently installed release.
%PYTHON% "%STAGED%" archive --tool-root "%TOOL%"
if errorlevel 1 (
    echo RESULT: FAILED - The release was not verified.
    goto fail
)
echo RESULT: OK - The active published release is saved and verified.
goto finish
:fail
set "EXITCODE=1"
echo Existing app files were not replaced.
:finish
if not "%CI%"=="true" pause
endlocal & exit /b %EXITCODE%
