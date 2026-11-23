# AGENTS.md — 接手开发指南

写给接手本项目的开发者和 AI agent（Claude Code、Kiro、Codex 等）。先读完本文再改代码。

## 1. 架构

模组分两层，通过 `D:\TOOLS\AWSdata\WanderingSword\`（下称 DATA）里的小文件通信。

```
手柄 ──XInput──> xinput1_3.dll（本项目，src/native）──过滤后的状态──> 游戏
                  │  右摇杆→SendInput 鼠标；叠加层窗口（指针/传送面板/调速提示）
                  │  读 map.flag / battle.flag；写 ptr.flag / teleport.req / scan_mid.txt
                  ▼
               DATA\*.flag / *.txt / *.req
                  ▲
                  │  写 map.flag / battle.flag / cur.txt / visited.txt；读 teleport.req / wsmod.ini
UE4SS ──Lua──> GamepadTweaks/Scripts/main.lua（src/lua）──反射调用──> 游戏对象
```

| 层 | 文件 | 运行位置 | 职责 |
|---|---|---|---|
| 原生 | `src/native/wsmod.cpp` | 游戏进程，作为 `xinput1_3.dll` 被游戏加载，再转调 `System32\xinput1_3.dll` | 手柄过滤、右摇杆鼠标、A 键鼠标优先、Start→B、View 调速、指针叠加层、传送面板 UI 和键盘钩子、UI 几何读取（`wsmod_scan` / `wsmod_commit` 导出给 Lua） |
| Lua | `src/lua/main.lua` | UE4SS，游戏线程 | 世界状态检测（地图、战斗、当前关卡）、到访记录、执行传送、背包排序/隐藏/高亮、交互半径、UI 按钮扫描、维护用命令通道 |

### DATA 目录文件协议

| 文件 | 写入方 | 内容 |
|---|---|---|
| `map.flag` | Lua | `1` = 世界地图打开（DLL 把右摇杆还给游戏，Y 打开传送面板） |
| `battle.flag` | Lua | `1` = 战斗中（DLL 完全放行手柄、隐藏自绘指针） |
| `ptr.flag` | DLL | `1` = 4 秒内用过右摇杆（Lua 只在此时扫描 UI） |
| `cur.txt` | Lua | 当前关卡名，如 `LV_25_P` |
| `visited.txt` | Lua | `关卡|x|y|z`，该关卡最近一次站在地面上的位置（安全落点） |
| `places.txt` | 仓库 data/ | `区域\t名称\t关卡,关卡\t驿站关卡\t驿站坐标` |
| `teleport.req` | DLL | `关卡|x|y|z`，Lua 读取后删除并执行 |
| `scan_in.txt` / `scan_mid.txt` / `scan_ok.txt` | Lua/DLL | UI 扫描的两阶段交接（见 wsmod.cpp 注释） |
| `cmd.lua` → `cmd_out.txt` | 开发者 | 维护通道：Lua 每秒检查，存在就在游戏线程执行一次并删除，`W(...)` 写输出 |
| `npc_override.txt` | 开发者 | 测试用，强制背包逻辑把当前角色当成该 NPC id |
| `cursor.png` | extract_cursor.ps1 | 游戏剑形指针 37×35 |
| `wsmod.ini` | 用户 | 配置，GBK 编码 |
| `wsmod.log` | DLL | 原生层日志 |

Lua 日志在 `<Win64>\ue4ss\UE4SS.log`，过滤 `GamepadTweaks`。

## 2. 构建、安装、测试

```bat
tools\build.bat                 :: 需要 VS（脚本里写的是 D:\TOOLS\VS\VS\VC\Auxiliary\Build\vcvars64.bat）
powershell -File tools\install.ps1
```

- DLL 改完必须重启游戏；Lua 改完可在游戏里按 `Ctrl+R` 热重载（UE4SS 设置里已开 `EnableHotReloadSystem`），但修改调度循环后建议重启。
- 必须正常退出游戏后安装；install.ps1 会拒绝向运行中的游戏安装。备份统一放在 `D:\TOOLS\dshdata\dshbackup\WanderingSword-install_<时间>\`，保留 game/data 目录结构；`-Backup` 可复用任务已有备份，不覆盖原始备份。
- 安装时把 UE4SS `[Debug]` 的 `ConsoleEnabled` / `GuiConsoleEnabled` / `GuiConsoleVisible` 设为 0，只隐藏窗口，文件日志仍保留。
- 编译后确认新 DLL 里真的包含你的改动（例如搜索新加的日志字符串），曾经出现过两次编辑互相覆盖、编出来的是旧代码。

### 不打扰用户的自动化测试流程

1. 确认用户没在玩：`Get-Process JH-Win64-Shipping`，看 `StartTime`。**用户在玩时不要做任何探测或重启**（已经因此导致过崩溃）。
2. 启动测试实例：`Start-Process "<游戏>\JH.exe"`，等约 40 秒到主菜单。
3. 读档（只读，不存档）：往 `cmd.lua` 写
   `local sm; for _,o in ipairs(FindAllOf("SaveManager")) do if o:IsValid() and not o:GetFName():ToString():find("^Default__") then sm=o end end; sm:LoadSlot(0)`
   `0` 是自动存档槽。再等约 25 秒。
4. 打开人物界面：`JHNeoUIPrimeModuleVM` 的实例调用 `:Show()`，关闭用 `:Hide()`。
5. 截图（不抢焦点）：`powershell -File tools\capture.ps1 -out x.png [-cx -cy -cw -ch 裁剪]`。
6. 测完 `Stop-Process`，并恢复系统指针（`SystemParametersInfo(SPI_SETCURSORS)` + `ClipCursor(NULL)`），因为强杀时 DLL 来不及还原。
7. 测试前备份 `%LOCALAPPDATA%\Wandering_Sword\Saved\<steamid>\`，测试后确认存档修改时间没变。

### 不抢前台的测试（用户在用电脑时优先用这些）

- **重载 Lua 不用 Ctrl+R**：在 cmd.lua 里 `ExecuteWithDelay(200, function() RestartCurrentMod() end)`，UE4SS 会卸载并重装本模组（`tools/test/mod_restart.ps1`：游戏内语法检查 → 安装 → 重启模组）。Ctrl+R 只在游戏窗口有焦点时生效。
- 后台点击：`bg_click.ps1` 用 PostMessage 往游戏窗口发鼠标/键盘消息，不切前台（关胜利结算画面可用；失败画面用它的按钮事件）。
- 战斗测试：人物界面选中队友 → 调切磋按钮事件 → 用 `HandleBtn_SpeedUp_1/2` 模拟按加速键 → `qb_verify.ps1`（速战全流程）。切磋没有收益，输赢都无影响。
- 注入手柄（wspad）需要游戏在前台；游戏窗口被别的窗口盖住时游戏不处理手柄输入。
- PowerShell 变量不区分大小写：脚本里别用 `$w`/`$r` 之类和 `$W`/`$R` 撞名。

### 注入手柄按键做自动测试（不用重启游戏）

`tools/test/`（运行时文件在 `D:\TOOLS\AWSdata\WanderingSword\tools\`）：
- `wspad.cpp` → `wspadN.dll`：Lua 用 `package.loadlib(dll, "wspad_install")()` 加载，把代理 DLL 里保存的系统 `XInputGetState` 指针换成自己的钩子，按 `pad.req` 脚本（每行 `按键[+按键] 毫秒` 或 `- 毫秒`）叠加按键，完成写 `pad_out.txt`；`wspad_uninstall` 还原。DLL 加载后文件被锁，改了要换文件名编译。
- 手柄休眠断开后游戏不再读取 XInput：创建 `pad_connect.flag`（让 0 号手柄报告已连接）并给游戏窗口发 `WM_DEVICECHANGE`（0x219, wParam 7）。
- `hot_reload.ps1`：游戏在前台时发 Ctrl+R 热重载并等日志；`install_reload.ps1`：游戏内语法检查 → 安装 → 关闭人物界面 → 热重载。
- `nav_verify.ps1`：人物界面切区回归测试（每步读区域 + 截图）。
- `wspad` 新版本支持左摇杆（`SL/SR/SU/SD`），脚本运行中检测到真实手柄有输入会立即中止（写 `pad_user.flag`）。2026-11-23 重启游戏后注入的十字键不再生效（左摇杆正常，原因未查明），区域内移动用左摇杆测。
- `nav_verify2.ps1`：v4.12 回归测试（LT/RT 循环、十字键/左摇杆出入各边缘、位置记忆），同时检查日志里没有「d-pad into」即焦点没进过属性/装备。

## 3. 必须遵守的规则（都是踩过的坑）

1. **Lua 只用一个 `LoopInGameThreadWithDelay` 调度所有任务。** 多个 `LoopAsync` + `ExecuteInGameThread` 会让 UE4SS 4.0 偶发 `Ref was not function` 并崩溃。
2. **不要对 `Default__` 对象（CDO）调用函数**，也不要在世界未稳定时调用 `JHNeoUISubsystem` 的方法（如 `GetBattleModule`、`GetCurrentFightName`）。曾在主菜单 1 秒内崩溃。用 `live(o)` 过滤，世界相关逻辑先过 `stableWorld()`（切图后静默 5 秒，传送后 12 秒）。
3. **不要 `ForEachUObject` 全量扫描。** 太重，也曾触发访问违例。用 `FindAllOf("类名")` 或 `StaticFindObject`。
4. 写 Lua 文件**不要带 UTF-8 BOM**（UE4SS 报 `unexpected symbol near '<\239>'`）。PowerShell 用 `New-Object Text.UTF8Encoding $false`。
5. 读 UI 几何不能走 UE4SS 的 Lua（`GetCachedGeometry` 在 Lua 里返回空表），所以由 DLL 直接调 `ProcessEvent`：`PE_RVA = 0x179A420`，启动时会在对象虚表里校验，失败则只关闭吸附功能。**游戏更新后要重新确认这个 RVA**（UE4SS.log 开头有 `ProcessEvent address`，减去模块基址即可）。
6. UI 可见性要沿父链判断（`shownChain`），按钮自身 `IsVisible()` 为真并不代表在屏幕上（主菜单 1286 个按钮里只有 10 个真的显示）。
7. `GetListItems()` 返回 Lua table，元素需要 `:get()` 解包；`TArray` 属性用 `:ForEach`。两者不要混用。
8. **传送只调用 `ChangeSceneMap`**，它自己会开始加载；再调 `task:StartChangeMap()` 会加载两次并可能把角色放到地图外。到访点只记录角色在地面（`CharacterMovement` 非下坠、Walking/NavWalking）站稳 2 秒后的位置。
9. **调度基准是 20 ms**（`LoopInGameThreadWithDelay(20, …)`，`every` 以拍计）。背包隐藏在 `taskHide` 每拍运行；防闪烁依赖对 `BP_OnEntryInitialized_Event_0` 的 `RegisterHook`，回调里**只改格子透明度，不要改列表**（此时游戏正在遍历列表生成格子）。
10. 背包隐藏使用 `GRID_ITEM:RemoveItem(spec)`，只影响显示；切换角色时调用 `vm:HandleBackpackBatchChange()` 恢复。

11. **人物界面切区（`taskNav`，v4.12）**：Lua 每拍通过 `wsmod_nav_*` 导出函数告诉代理 DLL 当前哪些输入会走进属性/装备（任意位置 LT/RT、头像栏右、底部按钮上），代理把这些按键（十字键和左摇杆）藏起来写进 `trig.req`，Lua 再自己跳；背包左边缘靠 `ChangeNaviFocus` 钩子改写目标。300 ms 没刷新掩码代理就恢复放行，Lua 卡住不会锁死手柄。自己调用 `ChangeNaviFocus` 时置 `NAV.self` 以免被钩子改写。只在手柄模式（`IsGamepadMode()`）下工作。
12. `inBattle`（= `battle.flag`）在大地图上也为真；只在**真正战斗**时停用的功能用 `inFight`。

13. **观察界面（`taskObs`）** 与人物界面共用代理的输入掩码（`maskSet(owner, m)` 合并）和同一份 `trig.req` 事件（`taskPadEv` 每拍读一次，`PADEV`）。改其中一边时不要单独调用 `navMask` / `navPadEvents`。`ChangeNaviFocus` 钩子里先交给 `OBS_HOOK`（观察界面可见时屏蔽所有 Property/Equip 请求），再走人物界面的改写。
14. 不要在 Lua 探测里读控件的 `Slot`、`Font` 等结构（2026-11-23 12:20 读战斗界面这类属性导致 UE4SS 访问冲突崩溃）；只读类反射、名字、可见性、焦点和简单数值。

15. **速战（`taskSpeed`）**：倍率要每拍重写（游戏会改回去），战斗界面隐藏时（技能特写）也要继续维持；自动战斗只在「是模组打开的」（`quick_auto.flag`）时才替用户关掉。Lua 里别写 `a and f() or nil` 取布尔返回值（false 会变 nil，v4.15 初版因此在 1 倍时不工作）。
16. 加速循环由 `/Script/JH.JHNeoUIBattleModuleView:HandleBtn_SpeedUp_1/2` 的钩子累计按键，不能根据图标刷新猜输入。`SPD.correcting` 屏蔽自己修正图标产生的事件；开场按键应保留到战斗界面就绪。
17. `wsmod_mute_0/1` 只控制当前游戏进程的 Windows 音频会话，COM 操作在独立线程；保留原静音状态、不改音量。静音与遮罩独立，500 ms 没收到 Lua 更新就恢复；不要在 DllMain 里调用 COM。

## 4. 用户偏好（务必保持）

- 交流用中文。
- 用户在用电脑时，测试尽量在后台进行（不抢焦点、不注入手柄）；必须前台时先告诉用户。
- **鼠标优先**：用过右摇杆后 A 是鼠标左键，原生 A 逻辑让位；只有按十字键或推左摇杆才恢复原生 A。
- 战斗中右摇杆不能有鼠标效果，所有按键用游戏原生手柄逻辑。
- 一次把需求做完再汇报，不要做一点停一点让用户测试；能自己验证的自己验证（读日志、测试实例、截图）。
- 指针速度恒定，不随推杆幅度加速。

## 5. 已知问题和待办

- DATA 目录和游戏路径写死在 `wsmod.cpp`（`DATA_DIR`）和 `main.lua`（`DIR`、`DLLPATH`），换机器要改；可以改成从 DLL 所在目录推导。
- `ProcessEvent` RVA 按版本写死（见规则 5）。
- 战斗判定依赖 `BP_FightSpectator_C` 作为 pawn 或战斗技能栏出现，特殊战斗（切磋、擂台、小游戏）未逐一验证。
- 传送用 `AsyncTaskChangeSceneMap.ChangeSceneMap`，跳过剧情触发可能卡任务；已在战斗、对话、加载时禁止。落地保护（`taskArrival`）兜底：下坠/掉出地图时送回 PlayerStart。
- 掉出地图后游戏会销毁角色（日志 `is outside the world bounds`），此时 `pc.Pawn` 为空，用 `ChangeSceneMap` 回到该图的 PlayerStart 可以恢复（2026-11-22 实际救援过一次）。
- 装备属性 = **物品表 `Items` 行的 `Actions`（基础值）+ `ItemInfoSpec.Actions`/`RandActions`（这一件的随机加成）**，只取 `CAttr(4)`；结果与游戏提示框一致（例：亮银甲 44.2+3 → 显示 47）。只比加成会严重误判（v4.4 及以前的 bug）。不考虑特效 buff；属性 ID 与中文名的对应尚未整理（已知 11=防御力、2=气血上限）。
- `GetDef()` 返回的是 Lua table，其中 `Actions` 也是 table，用 `:ForEach` 会静默失败；读基础属性请直接遍历数据表。
- 不要按 `ItemInfoSpec` 地址缓存任何东西：`HandleBackpackBatchChange` 会重建对象，地址会被别的物品复用。
- 高亮通过给物品格子自带的 `IMG_Focus` 着色实现，原图偏金色，所以内圈仍带一点金色。
