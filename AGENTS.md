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
- 游戏运行中 `xinput1_3.dll` 被锁定：install.ps1 会先改名旧文件（`xinput1_3.old_*`）再复制，下次启动生效。
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

## 3. 必须遵守的规则（都是踩过的坑）

1. **Lua 只用一个 `LoopInGameThreadWithDelay` 调度所有任务。** 多个 `LoopAsync` + `ExecuteInGameThread` 会让 UE4SS 4.0 偶发 `Ref was not function` 并崩溃。
2. **不要对 `Default__` 对象（CDO）调用函数**，也不要在世界未稳定时调用 `JHNeoUISubsystem` 的方法（如 `GetBattleModule`、`GetCurrentFightName`）。曾在主菜单 1 秒内崩溃。用 `live(o)` 过滤，世界相关逻辑先过 `stableWorld()`（切图后静默 5 秒，传送后 12 秒）。
3. **不要 `ForEachUObject` 全量扫描。** 太重，也曾触发访问违例。用 `FindAllOf("类名")` 或 `StaticFindObject`。
4. 写 Lua 文件**不要带 UTF-8 BOM**（UE4SS 报 `unexpected symbol near '<\239>'`）。PowerShell 用 `New-Object Text.UTF8Encoding $false`。
5. 读 UI 几何不能走 UE4SS 的 Lua（`GetCachedGeometry` 在 Lua 里返回空表），所以由 DLL 直接调 `ProcessEvent`：`PE_RVA = 0x179A420`，启动时会在对象虚表里校验，失败则只关闭吸附功能。**游戏更新后要重新确认这个 RVA**（UE4SS.log 开头有 `ProcessEvent address`，减去模块基址即可）。
6. UI 可见性要沿父链判断（`shownChain`），按钮自身 `IsVisible()` 为真并不代表在屏幕上（主菜单 1286 个按钮里只有 10 个真的显示）。
7. `GetListItems()` 返回 Lua table，元素需要 `:get()` 解包；`TArray` 属性用 `:ForEach`。两者不要混用。
8. **传送只调用 `ChangeSceneMap`**，它自己会开始加载；再调 `task:StartChangeMap()` 会加载两次并可能把角色放到地图外。到访点只记录角色在地面（`CharacterMovement` 非下坠、Walking/NavWalking）站稳 2 秒后的位置。
9. 背包隐藏使用 `GRID_ITEM:RemoveItem(spec)`，只影响显示；切换角色时调用 `vm:HandleBackpackBatchChange()` 恢复。

## 4. 用户偏好（务必保持）

- 交流用中文。
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
- 装备比较只看 `Actions`/`RandActions` 里的 `CAttr(4)` 数值，不考虑特效 buff；属性 ID 与中文属性名的对应关系尚未整理。
- 切换背包分类标签时被隐藏的装备会闪现约 0.3 秒。
- 高亮通过给物品格子自带的 `IMG_Focus` 着色实现，原图偏金色，所以内圈仍带一点金色。
