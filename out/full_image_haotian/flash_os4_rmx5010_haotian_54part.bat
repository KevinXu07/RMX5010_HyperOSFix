@echo off
chcp 936 >nul
setlocal EnableExtensions EnableDelayedExpansion

rem 参数 force = 强力模式：允许重建缺失或容量不足的 super 逻辑分区
set "FORCE="
if /i "%~1"=="force" set "FORCE=1"

set "ROOT=%~dp0"
set "PKG=%ROOT%images"
set "OFFICIAL=%ROOT%official_vbmeta"
set "VERIFY=%ROOT%verify_package.ps1"
set "DEVCHECK=%ROOT%flash_device_check.ps1"
set "TOOLS=%ROOT%platform-tools"
set "FASTBOOT=%TOOLS%\fastboot.exe"
set "INIT_BOOT=%PKG%\init_boot.img"
set "VERIFY_EXTRA="
set "STATEFILE=%TEMP%\os4_rmx5010_v8_state_%RANDOM%.txt"
set "PATH=%TOOLS%;%PATH%"

for %%F in (adb.exe fastboot.exe AdbWinApi.dll AdbWinUsbApi.dll libwinpthread-1.dll make_f2fs.exe make_f2fs_casefold.exe mke2fs.exe mke2fs.conf) do if not exist "%TOOLS%\%%F" (echo [错误] 缺少内置工具 %%F，请完整解压刷机包。&goto :err)
where powershell.exe >nul 2>&1 || (echo [错误] 未找到 PowerShell。&echo 按任意键退出。&pause >nul&exit /b 1)
if not exist "%VERIFY%" (echo [错误] 缺少校验脚本 verify_package.ps1。&echo 按任意键退出。&pause >nul&exit /b 1)
if not exist "%DEVCHECK%" (echo [错误] 缺少设备预检脚本 flash_device_check.ps1。&echo 按任意键退出。&pause >nul&exit /b 1)

echo.
echo OS4 RMX5010 haotian OS4.0.0.19 全量镜像包（54 分区）
echo 适用机型：真我 GT7 Pro / RMX5010，请勿用于其它机型。
echo 本次首次刷入会清除所有用户数据，包括应用、照片和内置存储文件；请先完成备份。
echo 使用包内 platform-tools，无需配置 ADB 环境；电脑仍需安装 USB 驱动。
echo 先在 bootloader 写入启动相关分区，再切换 fastbootd 写入动态分区。
if defined FORCE (echo [模式] 强力模式：允许重建 super 逻辑分区，仅在普通刷写报分区缺失或空间不足时使用。) else (echo [模式] 普通刷写。)
echo.
set "INIT_BOOT=%ROOT%optional\init_boot_sukisu.img"
set "VERIFY_EXTRA=-IncludeSukisu"
echo.
echo 本包默认刷入 SukiSU init_boot（含 KernelSU/SukiSU Root），不再提供免 Root 选项。
echo SukiSU 管理器 APK 在 optional 目录，首次开机后手动安装。
echo 相机模块在 SukiSU/KSU 管理器中本地安装，Sense APK 用 LSPosed 启用。

:confirm_flash
echo.
set "CONFIRM="
set /p "CONFIRM=确认刷入并清除所有用户数据请输入 y 并回车，直接回车或输入其它内容取消："
if /i not "!CONFIRM!"=="y" (echo 已取消，未操作手机。&exit /b 2)
if defined FORCE (
    set "CONFIRM_FORCE="
    set /p "CONFIRM_FORCE=强力模式会删除并重建缺失或过小的逻辑分区，输入 force 确认，直接回车取消："
    if /i not "!CONFIRM_FORCE!"=="force" (echo 已取消，未操作手机。&exit /b 2)
)

echo [校验] 开始校验全部 54 个镜像及已选的可选镜像，请稍候...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%VERIFY%" -Strict %VERIFY_EXTRA% || goto :err
call :one_device >nul 2>&1
if errorlevel 1 (
    echo 未检测到 fastboot，正在尝试使用包内 ADB 重启到 bootloader...
    call :one_adb_device || goto :no_device
    "%TOOLS%\adb.exe" -s "!ADB_DEVICE!" reboot bootloader || goto :err
    echo 已发送重启命令，等待 bootloader 重新连接...
    timeout /t 8 /nobreak >nul
    call :wait_bootloader || goto :no_device
)
call :one_device || goto :no_device
echo [1/3] 正在检查 bootloader 模式...
"%FASTBOOT%" getvar is-userspace 2>"%STATEFILE%" || goto :err
findstr /i /c:"is-userspace: yes" "%STATEFILE%" >nul
if not errorlevel 1 (
    echo 当前处于 fastbootd，正在返回 bootloader 以刷写启动相关分区。
    "%FASTBOOT%" reboot bootloader || goto :err
    timeout /t 5 /nobreak >nul
    call :wait_bootloader || goto :err
)
"%FASTBOOT%" getvar is-userspace 2>"%STATEFILE%" || goto :err
findstr /i /c:"is-userspace: no" "%STATEFILE%" >nul || goto :err

echo [预检] 核对设备 product、槽位、解锁状态与目标分区表...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DEVCHECK%" -Stage bootloader -Fastboot "%FASTBOOT%" -Images "%PKG%" -Partitions "vbmeta,vbmeta_system,vbmeta_vendor,boot,vendor_boot,init_boot,dtbo,recovery" || goto :err

if defined FORCE (
    echo [强力] 将启动槽位切换到 A...
    "%FASTBOOT%" set_active a || goto :err
    timeout /t 3 /nobreak >nul
    "%FASTBOOT%" getvar current-slot 2>"%STATEFILE%"
    findstr /i /c:"current-slot: a" "%STATEFILE%" >nul || (echo [错误] 切换 A 槽失败，已停止。&goto :err)
)

echo [2/3] 正在 bootloader 中刷写启动相关分区...
for %%F in (vbmeta.img vbmeta_system.img vbmeta_vendor.img boot.img vendor_boot.img init_boot.img dtbo.img recovery.img) do if not exist "%PKG%\%%F" (echo [错误] 缺少镜像 %%F。&goto :err)
for %%F in (vbmeta.img vbmeta_system.img vbmeta_vendor.img) do if not exist "%OFFICIAL%\%%F" (echo [错误] 缺少 official_vbmeta\%%F。&goto :err)
echo [1/5] 刷入官方 vbmeta（用于进入 fastbootd）...
"%FASTBOOT%" flash vbmeta "%OFFICIAL%\vbmeta.img" || goto :err
"%FASTBOOT%" flash vbmeta_system "%OFFICIAL%\vbmeta_system.img" || goto :err
"%FASTBOOT%" flash vbmeta_vendor "%OFFICIAL%\vbmeta_vendor.img" || goto :err
"%FASTBOOT%" flash boot "%PKG%\boot.img" || goto :err
"%FASTBOOT%" flash vendor_boot "%PKG%\vendor_boot.img" || goto :err
"%FASTBOOT%" flash init_boot "%INIT_BOOT%" || goto :err
"%FASTBOOT%" flash dtbo "%PKG%\dtbo.img" || goto :err
"%FASTBOOT%" flash recovery "%PKG%\recovery.img" || goto :err
echo bootloader 阶段刷写完成。
echo [清除数据] 正在执行 fastboot -w，将清除 userdata 和 cache...
"%FASTBOOT%" -w
if errorlevel 1 (
    echo [警告] fastboot -w 未成功，改用 erase userdata + erase metadata...
    "%FASTBOOT%" erase userdata || goto :err
    "%FASTBOOT%" erase metadata 2>nul
)
echo userdata 和 cache 已清除。

echo 正在重启至 fastbootd，请等待设备重新连接...
"%FASTBOOT%" reboot fastboot || goto :err
set /a N=0
:wait_userspace
call :one_device >nul 2>&1 || goto :wait_userspace_retry
"%FASTBOOT%" getvar is-userspace 2>&1 | findstr /i /c:"is-userspace: yes" >nul
if not errorlevel 1 goto :fastbootd_ready
:wait_userspace_retry
set /a N+=1
if !N! GEQ 90 (echo [错误] 等待 fastbootd 就绪超时。&goto :err)
timeout /t 2 /nobreak >nul
goto :wait_userspace

:fastbootd_ready
echo 已检测到 fastbootd，额外等待 5 秒，确保驱动及连接稳定...
timeout /t 5 /nobreak >nul
call :wait_one_device || goto :no_device
echo [3/3] 正在核对 fastbootd 分区表并清理 COW 快照...
if defined FORCE goto :check_force
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DEVCHECK%" -Stage fastbootd -Fastboot "%FASTBOOT%" -Images "%PKG%" -Partitions "my_engineering,my_carrier,my_region,my_manifest,my_bigball,my_heytap,my_product,my_stock,vendor,odm,system_dlkm,vendor_dlkm,system,system_ext,product" -CleanCow || goto :err
goto :check_done
:check_force
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DEVCHECK%" -Stage fastbootd -Fastboot "%FASTBOOT%" -Images "%PKG%" -Partitions "my_engineering,my_carrier,my_region,my_manifest,my_bigball,my_heytap,my_product,my_stock,vendor,odm,system_dlkm,vendor_dlkm,system,system_ext,product" -CleanCow -Repair || goto :err
:check_done
echo 正在刷写动态分区，请勿拔线。保持 my_* 优先；镜像大于分区时 fastboot 会自动扩容。
for %%P in (my_engineering my_carrier my_region my_manifest my_bigball my_heytap my_product my_stock vendor odm system_dlkm vendor_dlkm system system_ext product) do "%FASTBOOT%" -S 128M flash %%P "%PKG%\%%P.img" || goto :err
echo [收尾] 擦除 FRP 分区，失败不影响系统可忽略...
"%FASTBOOT%" erase frp 2>nul
echo 覆盖刷入已预置 flags=3 的 vbmeta 三件套（关闭 AVB 验证与 hashtree）...
"%FASTBOOT%" flash vbmeta "%PKG%\vbmeta.img" || goto :err
"%FASTBOOT%" flash vbmeta_system "%PKG%\vbmeta_system.img" || goto :err
"%FASTBOOT%" flash vbmeta_vendor "%PKG%\vbmeta_vendor.img" || goto :err
echo.
echo [完成] 本脚本指定的 haotian 分区已刷写完成，用户数据已清除。
echo 已完成的检查：设备型号/槽位/解锁状态、分区表匹配、COW 快照清理、镜像尺寸。
echo 手机将停留在 fastbootd，请确认结果后手动重启；脚本不会自动重启。
echo 按任意键关闭窗口。
echo.
echo.
echo 首次开机进入系统后：
echo 1) 安装 optional\SukiSU_v4.2.0_40900-release.apk；
echo 2) 安装 camera_fix 目录下的 rmx5010_fod_bridge-1.7.1-full.zip，重启生效；
echo 模块自带 ZygiskNext / LSPosed / Sense 与 ColorOS 钱包，安装时自动部署。
pause >nul
exit /b 0

:one_device
set "DEVICE="
set /a DEVICE_COUNT=0
"%FASTBOOT%" devices >"%STATEFILE%" 2>nul
if errorlevel 1 (
    echo [设备] fastboot devices 执行失败，检查 USB 驱动或换一根数据线。
    exit /b 1
)
for /f "usebackq tokens=1" %%A in ("%STATEFILE%") do (
    set /a DEVICE_COUNT+=1
    set "DEVICE=%%A"
)
if !DEVICE_COUNT! EQU 1 exit /b 0
if !DEVICE_COUNT! EQU 0 (
    echo [设备] 当前 fastboot 设备数：0。
    exit /b 1
)
echo [设备] 当前 fastboot 设备数：!DEVICE_COUNT!，清单如下：
type "%STATEFILE%"
exit /b 1

:wait_one_device
rem bootloader 切 fastbootd 时 USB 会重新枚举，设备可能短暂掉线；最多重试 10 次（约 20 秒）。
set /a WAITD=0
:wait_one_device_loop
set /a WAITD+=1
if !WAITD! GEQ 10 goto :wait_one_device_last
call :one_device >nul 2>&1
if not errorlevel 1 exit /b 0
timeout /t 2 /nobreak >nul
goto :wait_one_device_loop
:wait_one_device_last
call :one_device
exit /b 1

:one_adb_device
set "ADB_DEVICE="
set /a ADB_COUNT=0
"%TOOLS%\adb.exe" devices >"%STATEFILE%" 2>nul || exit /b 1
for /f "usebackq skip=1 tokens=1,2" %%A in ("%STATEFILE%") do if "%%B"=="device" (
    set /a ADB_COUNT+=1
    set "ADB_DEVICE=%%A"
)
if !ADB_COUNT! EQU 1 exit /b 0
if !ADB_COUNT! EQU 0 (
    echo [错误] 未检测到已授权的 ADB 设备，请手动进入 bootloader 并重试。
    exit /b 1
)
echo [错误] 检测到多台已授权的 ADB 设备，请断开其它手机。
exit /b 1

:wait_bootloader
set /a B=0
:wait_bootloader_loop
call :one_device >nul 2>&1 || goto :wait_bootloader_retry
"%FASTBOOT%" getvar is-userspace 2>"%STATEFILE%"
findstr /i /c:"is-userspace: no" "%STATEFILE%" >nul
if not errorlevel 1 exit /b 0
:wait_bootloader_retry
set /a B+=1
if !B! GEQ 30 exit /b 1
timeout /t 2 /nobreak >nul
goto :wait_bootloader_loop

:no_device
echo [错误] 没有拿到唯一的 fastboot 设备。上一行的 [设备] 信息会给出实际数量。
echo 0 台：换 USB 口或数据线，确认手机停在 fastbootd 界面，且没有被其它程序占用。
echo 多台：只保留目标手机（拔掉其它手机、关掉其它 fastboot 窗口）后重跑本脚本。
echo 按任意键退出。
pause >nul
exit /b 1

:err
echo [错误] 校验或刷写失败，操作已停止，手机不会自动重启。
echo 请保留上方错误信息，排查前不要强行继续刷写。
echo 已写好的分区不会回滚；设备保持连接并停在 fastboot 时，排除问题后可直接重跑本脚本。
echo 若报分区缺失、super 空间不足或 data too large，可用强力模式重跑：flash_os4_rmx5010_haotian_54part.bat force
echo 按任意键退出。
echo.
pause >nul
exit /b 1
