# 游戏内部结构笔记（v1.24.32）

全部通过 UE4SS 反射和资源包索引实测得到。路径省略前缀 `/Game/JH/` 的写作 `…/`。

## 基本信息

- 主程序 `Wandering_Sword\Binaries\Win64\JH-Win64-Shipping.exe`，UE 4.26，引擎字符串 `++UE4+Release-4.26`
- 资源包 `Wandering_Sword\Content\Paks\Wandering_Sword-WindowsNoEditor.pak`（V11，未加密，Zlib，约 28.9 万条目），可用 [repak](https://github.com/trumank/repak) `list` / `get`
- 手柄通过 `XINPUT1_3.dll` 读取（同时加载了 `xinput1_4`、`dinput8`，但代理 `xinput1_3` 即可生效）
- `UObject::ProcessEvent` 位于模块基址 + `0x179A420`，在 `UObject` 虚表第 67 项
- 存档：`%LOCALAPPDATA%\Wandering_Sword\Saved\<steamid>\SaveGames\*.sav`，`0.sav` 为自动存档

## 输入

- `InputSettings` 的 ActionMappings 只绑定了键盘和几个小游戏的手柄键；主手柄逻辑写在 NeoUI 各界面里（`JHGamepadMainInputManager`、`JHGamepadBattleInputManager` 等），所以模组选择在 XInput 层改键，而不是改映射。
- 键盘：背包/人物 `B`（`OpenBag`、`JHUIOpenPrime`）、技能 `V`、任务 `T`、经脉 `J`、地图 `M`、世界地图 `Tab`、系统 `Esc`、交互 `E`、调息 `Z`、逃跑 `X`、认输 `C`、战斗技能 `1`–`6`。
- 游戏会在键鼠/手柄模式之间切换并设置 `PlayerController.bShowMouseCursor`（日志里有 `键鼠模式 : --- show cursor` / `手柄模式 : --- hide cursor`）。
- 硬件指针：`UserInterfaceSettings.HardwareCursors[1] = Slate/MouseCursor`，图片是 pak 里的原始 PNG `MouseCursor.png`（37×35，热点 0,0），位于 pak 尾部。

## 角色与世界

- 野外主角 pawn：`BP_SceneHero_C`（山洞里是 `BP_SceneHero_InCave_C`）；战斗中 pawn 变为 `BP_FightSpectator_C`，可用来判定战斗。
- 当前关卡：pawn 全名里 `.<关卡>:PersistentLevel`，例如 `LV_25_P`。
- 交互检测：`BP_SceneHero` 里名为 `Sphere` 的 `SphereComponent`，资源默认半径 35（运行时读到 32），重叠事件 `HandleSphereBeginOverlap/EndOverlap`。改 `SetSphereRadius` 即可扩大范围，每次切图都会重建，需要重新设置。
- `JHNeoUISubsystem`：`GotoDefaultStatus()`、`ShouldDisableInput()`、`GetDialogView()`、`CommonHandleGlobalNaviBtnClick(i)`、`OpenWorldMap()`、`OpenCourierStation(id)` 等。**不要在世界未就绪时调用**。
- `SaveManager`（`BP_GameInstance_C` 子对象）：`LoadSlot(i)`、`SaveSlot(i, bAuto, name)`、`AutoSave()`。模组每 120 秒调用原有 `AutoSave()`，沿用游戏的存档检查；定时任务在现有游戏线程循环里每秒检查一次，用 `os.time()` 按现实时间计时，战斗、对话、菜单、加载或未落地时延后。

## 地图与传送

- 世界地图界面：`BPMV_JHNeoUIWorldMap3_C`（父类 `JHNeoUIWorldMapViewBase`，有 `MaxScale=2`、`MoveKeys=WASD`、`GamepadScaleSpeed` 等）。
- 换图：`/Script/JH.Default__AsyncTaskChangeSceneMap`
  `ChangeSceneMap(WorldContext, FName 关卡, FVector 位置, 朝向枚举, bPlayIntoSceneAnim, bPlayShowSceneAnim, bShowHUDOnChanged, bShowGlobalLoading, bReadSaveData)` 返回 task，再调 `task:StartChangeMap()`。
  另有 `ChangeSceneMapWithId(…, MapId, …)`。
- 数据表 `…/Tables/Maps.Maps`：`MapId, MapName(关卡名), ViewName(中文名), bInCave, WorldMapPosX/Y, …`。MapId 段落：9–99 与 1000+ 中原，200 段北地，300 段关外，400 段西域，600 段海外，900 段南疆。
- 数据表 `…/Tables/CourierStation.CourierStation`：`ID, DisplayName, Region(ECourierStationRegion), MapId, Price, TeleportationX/Y/Z, Requirements, NPCId`，共 15 个驿站。
  `ECourierStationRegion`：1 中原 2 西域 3 关外 4 南疆 5 北地 6 海外。
- `MapManager:CanTransToMapWithId(CourierStationId)`。

## 战斗

- 战斗技能栏：`…/JHNeoUI/Modules/Battle/Spell/BPMV_BattleSpell_C`（含认输、撤退、调息按钮）。

## 人物界面与背包

- 打开人物界面：`JHNeoUIPrimeModuleVM:Show()` 会保留上次的栏目；Start 用 `ShowAndGotoTab(0)` 明确打开队伍，关闭用 `Hide()`。栏目编号从 0 开始：0 队伍、1 武学、2 任务、3 经脉；用 `CurrentTabIndex() == 0` 和背包 VM 的 `GetModuleVisibility()` 一起确认打开成功。界面 `BPMV_Prime_C` → `BPMV_PrimeTeam_C` → `BPMV_PrimeTeamBackpack_C`。
- 主角背包 VM：`JHMainCharacterBackpackInTeamVM`（父类 `JHNeoUIItemModuleVM_WDT`）
  - `GetModuleVisibility()` 判断是否打开
  - `GetPairView()` → `BPMV_JHBackpack_Basic_C`
  - `HandleSortTypeItemClick(数据对象)` 切换排序；`HandleBackpackBatchChange()` 重建列表
  - `RootData:DataToString()` 是 JSON，含 `sort_types`（`is_active` + `st_id`）、`filters`、`money`
  - `CurrentDataSrc`：`ItemInfoSpec` 数组
- `BPMV_JHBackpack_Basic_C`
  - 整理按钮事件：`BndEvt__BPMV_JHBackpack_Basic_BTN_BackpackSort_K2Node_ComponentBoundEvent_2_BtnClick__DelegateSignature`
  - 排序弹窗 `VE_SortType_Popup.VE0 / VE0_1 / VE0_2 / VE0_3` 对应 `st_id` 1–4，`:GetData()` 传给 `HandleSortTypeItemClick`
  - `GRID_ITEM`（`BP_ItemGridWDT_C`，TileView）：`GetListItems()`、`RemoveItem(spec)`
- `EBackpackSortType`：1 Value(珍贵) 2 Time 3 Price 4 ItemType(类型)。游戏启动时重置为 1。
- 物品格子：`BPEntry_Item_WDT_C`，`BindedDataObject` → `ItemInfoSpec`；`ItemDisplay.CMP` 里有 `IMG_Focus`（选中框，平时 Hidden）、`IMG_Border`、`IMG_QualityBorder`、`IMG_SolidBG`、`IMG_NewMark`。
- 游戏自己的「当前角色不可用/不可学」判定：格子显示数据（`ItemDisplay:GetData():DataToString()`）里的 `"not_learnable":true`，渲染为 `CMP.IMG_Not_Learnable` 可见（置灰）。游戏会按当前武器类型、秘籍能否学习等计算置灰；v4.23 仅让非装备学习此判定，装备改按明确的角色要求过滤，避免误隐藏可装备武器。`GetBindedDataObj()` 取格子当前绑定的 `ItemInfoSpec`。
- 分类标签：`BP_BackpackFilterBtn_C`（`Btn_All/Wu/Fang/Hao/Shu/Cai/Zhenpin/Ren`）。**按钮的 `bIsActive` 不会随切换更新（始终是 `Btn_All`），`Btn_Zhenpin` 的 `FilterIndex` 也是 0，都不能用来判断当前分类。** 当前分类用 `JHMainCharacterBackpackInTeamVM:GetFilterIndex()`（或 `RootData` 里的 `active_filter_type`），取值同 `EBackpackFilterType_Console`：0 全部 1 武器 2 防具 3 丹药 4 秘籍 5 材料 6 珍宝 7 任务（2026-11-23 实测切换验证）。
- 秘籍「学成」：物品表 `Actions` 中 `ASkill(10)` 的 ID，`TeamInfo:HasSkillById(id)` 为真即已学。图纸学成：格子显示数据 `is_recipe` + `is_acquired`（贴图 `hecheng31_tuzhixuecheng`）。任务道具：`EItemSubType` 60。
- `JHNeoUIItemUtil:BackpackItemCanDoubleClick_WDT(spec, npc)` 不是可用性判定（置灰的拳套也返回 true），不要用。
- 注意：`CMP_BackpackSortButton` 是另一个（移动端/旧版）整理按钮，电脑版人物界面里不存在。

## 人物界面手柄区域（2026-11-23 注入按键实测）

- 界面 `BPMV_PrimeTeam_C`，5 个手柄区域（`BP_GAARegion_C`，`AreaData.RegionID`）：`Region_SideBar` gr_prime_sidebar（头像）、`Region_Property` gr_prime_team_1（属性）、`Region_Equip` gr_prime_team_2（装备）、`Region_Backpack` gr_prime_team_3（背包）、`Region_BottomBtns` gr_prime_bottombtns（底部按钮）。
- 子模块 key（`SubModuleMetadatas`）：`SideBar / Property / Equip / Backpack / Formation / MountPet`，对应视图 `BPMV_TeamSideBar2_C / BPMV_Team_Property_C / BPMV_Team_Equip_V3_C / BPMV_PrimeTeamBackpack_C`。
- 底部按钮从左到右：`BTN_FormatonOut`（上阵）、`CT_BottomBtnsDynamic` 里的 `BTN_QieCuo / BTN_SongLi / BTN_LiDui / BTN_QingJiao`（只对队友显示）、`BTN_MountPet`（坐骑）。
- 当前所在区域：视图 `HasFocusedDescendants()`；底部按钮看 `HasFocusedDescendants()` 或 `JHGPCBtn_ActiveBG:IsVisible()`。`BP_GAADisplay` 和 `Region_*` 的可见性不能用。
- 游戏原生：RT 头像→属性→装备→背包（到背包停住），LT 背包→装备→属性（到属性停住）；属性按左→头像，头像按右→属性；属性连按下 5 次→底部按钮；底部按上或 RT→属性，LT 不动。**LT/RT 在松开时才切换**。
- 程序跳转：`vm = team:GetNeoUIVM()`，`w = vm:ChangeNaviFocus(FName(key), 0, "")` 返回目标控件，**再对它 `:SetFocus()`**（背包必须这样，头像/属性/装备只调 ChangeNaviFocus 也行）。底部按钮：对按钮本身 `:SetFocus()`。`EVT_FocusMountBtn()`、`FocusWidgetForScenario_Direct` 都不移动焦点。
- 扳机状态：`NeoUISubsystem.InputManager.KeyDownStatus`（map，key 为数字），11 = LT，12 = RT；`InputManager:IsGamepadMode()` 区分手柄/键鼠模式。
- **哪些移动经过 `ChangeNaviFocus`**（在 `/Script/NeoUI.NeoUIUniversalModuleVMBase:ChangeNaviFocus` 上 `RegisterHook` 实测）：背包最左列往左 = `ChangeNaviFocus("Equip", 3)`，可以在钩子里 `id:set(FName(...))` 改写目标；头像栏往右、底部按钮往上是 Slate 控件导航，**不经过** ChangeNaviFocus，只能在输入层拦截。把属性/装备设为 HitTestInvisible 对导航没有影响。
- `KeyDownStatus` 的 key：1 左 2 上 3 右 4 下 8 A 11 LT 12 RT（十字键）；左摇杆不出现在这里。
- 背包格子：`GRID_ITEM:NavigateToIndex(i)` 把焦点放到第 i 格（`SetSelectedIndex` 不移动焦点），每行 6 格，`GetIndexForItem(spec)` 取当前格序号。
- 头像栏格子 `BPVE_SideBarCell2_C`（内部按钮 `BTN_SidebarCell`），`:SetFocus()` 可选中指定头像；模块刚拿到焦点后游戏会在约一两帧内再把焦点放回默认头像，需要再设一次。
- 大地图（行走地图）上 pawn 是 `BP_WorldHero1_C`，模组的 `battle.flag` 此时也是 1；真正战斗是 `BP_FightSpectator_C` 或战斗技能栏可见。

## 战斗速度与自动战斗（2026-11-23 实测）

- 游戏的加速按钮只切换 1/2 倍：改当前持久关卡 `WorldSettings.TimeDilation`（1.0/2.0），`MaxGlobalTimeDilation` 默认 20。界面 `BPMV_JHBattleModule_C`：`BTN_SpeedUp1`（显示 ×1 图标）/`BTN_SpeedUp2`（×2），`HandleBtn_SpeedUp_1()` 由 1 倍切到 2 倍，`HandleBtn_SpeedUp_2()` 由 2 倍切到 1 倍。游戏记住这个开关。
- 战斗中游戏会反复把 `TimeDilation` 设回自己的值（一场几十次），要每帧重新写。技能特写时战斗界面整个隐藏。
- 鼠标加速事件的原生反射路径：`/Script/JH.JHNeoUIBattleModuleView:HandleBtn_SpeedUp_1` / `HandleBtn_SpeedUp_2`。本游戏版本没有战斗蓝图 `HandleBtn_SpeedUp`，手柄快捷键不经过这两个鼠标处理函数；模组通过代理接收 Y 单键并写入共享 `trig.req`，LB/RB/LT/RT 与 Y 的组合仍走原生逻辑。`BtnSpeedUpFlagIs1()` 返回持久开关（true = 1 倍）。开场或技能特写会刷新图标，不能据此判断用户按键；模组主动调用两个原生处理函数时必须加重入保护。
- 自动战斗：`EnableAutoBattle()` / `DisableAutoBattle()` / `BtnAutoBattleFlagIsAuto()`（都在战斗界面上），游戏记住这个开关（跨战斗、跨重启）。
- 上一场的 `BPMV_JHBattleModule_C` 实例可能还在，要取**可见**的那个。
- 结算：胜利 `BPMV_BattleWinMaster_C`（VM `JHNeoUIBattleResultVM:HandleModuleClose()` 关闭），失败 `BPMV_BattleFailure_C`（按钮事件 `BndEvt__BPMV_BattleFailure_NeoUIButtonBase_76_..._OnButtonClickedEvent__DelegateSignature`）。
- `FightManager`：`HandlePawnTurnStart`、`ActionWinLose(Type)`、`TurnManager`。战斗界面还有 `EVT_UpdateSkipButtonVisibility` / `BTN_SkipArena`（擂台跳过，未研究）。
- 人物界面切磋：`BPMV_PrimeTeam_C` 的 `BndEvt__BPMV_PrimeTeam_BTN_QieCuo_K2Node_ComponentBoundEvent_2_BtnClick__DelegateSignature`（需选中队友）。

## 观察界面（2026-11-23 实测）

- 界面 `BPMV_Observe_C`（`JHNeoUIObserveView`，VM `JHNeoUIObserveVM`），子模块 key `Property / Equip / Backpack`，`DefaultFocusModuleKey = Property`。视图：`BPMV_Observe_Property_C`、`BPMV_Team_Equip_V3_C`、`BPMV_JHBackpack_Basic_C`（`GRID_ITEM`）。
- 底部按钮（从左到右）：`BTN_QieCuo` 切磋、`BTN_SongLi` 送礼、`BTN_QingJiao` 请教、`BTN_JiSha`、`BTN_LiDui`（后两个按情况显示）。
- 原生导航：LT/RT 无作用，LB/RB 切背包分类；背包最左列往左 = `ChangeNaviFocus("Equip", 3)`，**由背包子模块的 VM（`JHBackpackVMBase`）发出**，不是观察 VM；装备往左 = `ChangeNaviFocus("Property", 3)`；属性连按下 5 次到底部按钮，底部按钮往上回属性（控件导航）。
- `ChangeNaviFocus` 传入界面没有的 key（如 "SideBar"）什么也不做，焦点留在原处，可用来屏蔽某个跳转。
- 背包「学成」标记 = 格子显示数据 `"is_acquired":true`（秘籍 30–38），全队通用，和 `TeamInfo:HasSkillById` 不同（大多数「学成」书全队都没人会）。
- 游戏窗口不在前台时（例如 Steam 窗口盖在上面）游戏不处理手柄输入，注入测试前要把游戏切到前台。

## 物品与装备

- `ItemInfoSpec`：`ItemDefId, Num, Actions[], RandActions[], bOnlyForLayout, GainTime, …`，`GetDef()` 返回 `ItemInfoSetting` 行。
- 数据表 `…/Tables/Items.Items`（`ItemInfoSetting`）：`ID, EquipmentRank, Name, ItemType(EItemSubType), Quality, Requirements[RequirementSetting], Actions[ActionSetting], …`。
- `EItemSubType`：1 剑 2 刀 3 枪棍 4 拳 5 暗器 6 其他兵器；10 衣 11 帽 12 鞋 13 饰品；20+ 丹药、30+ 秘籍、40+ 材料……
- `ERequirementType`（装备实际只用到）：13 OnlyHero、41 ExcludeNPC、42 OnlyDesignatedNPC、60 bBuyDLC2。426 件装备里没有属性门槛。
- `EActionType` 4 = `CAttr`（加属性，`ID` 为属性编号，`Num` 为数值）；5 = `ABuff`。属性编号含义尚未整理。
- `NPCManager:GetNPCInfo(npcId, false)` → `TeamInfo`：`EquipmentSpecs[]`（已穿装备）、`ItemSpecs`、`AttributeSet`、`GetWeaponType()`。主角 npcId = 0。
- 当前在人物界面选中的角色：`TeamModuleVM.RootData` JSON 的 `focus_npc_index` + `data[i].npc_id`。

## v4.23 离线定位（运行效果待用户实机验证）

- `GetWeaponType()` 是当前武器类型，不是角色可装备武器集合；装备资格沿用 `Items.Requirements`，不得用它误删其他类型武器，也不得复用旧置灰缓存。
- `JHPaperFlipbookComponent.DefaultRunAnimalState` / `AnimalState` 的快跑值为 9，普通移动为 2。只映射这两个动画值，保留其他动画、可见性、速度和坐骑效果。主角 `FollowCharacters` 为跟随角色数组。
- `KeepFastRunState()` 会重新应用控制器当前快跑状态及随从动画；关闭外观覆盖时调用一次，不用旧状态猜测，也不调用 `SetFastRun(false)` 或下坐骑。
- `JHMainCharacterGiftBackpackVM` 的实际收礼对象不反射：v1.24.32 原生 vtable RVA `0x432a750`，receiver 偏移 `0x1a8`。`wsmod_gift_context` 由 Lua 在游戏线程提供有效 VM 地址，经原生 vtable 校验后只读 4 字节，通过 `gift_vm.txt` / `gift_context.txt` 返回；未知版本/无对象则返回 -1，禁用关系品质过滤，不猜队伍当前人物。
- `Items.bCantGift` 禁止送礼；原生品质判定 RVA `0x1122f20`：好感度关系等级绝对值 + 1 为最低品质。正向边界 20/40/60/80，负向边界 -20/-40/-60/-80（负向含边界）。关系变化后调用送礼背包的 `HandleBackpackBatchChange()` 让游戏重算 `is_fav`；列表 `RemoveItem` 只隐藏，不删除物品。
- 音频恢复失败时保留原状态并重试；COM 仍只在音频 worker 使用。

## v4.24 实机反馈后的离线修正

- 完整武器权限来自 `NPCs.NPCs` 的 `WeaponLimits`（`EWeaponType`），原生物品 JSON 在 NPC 定义行 `+0x168` 的数组中逐项匹配；`GetWeaponType()` 只描述当前武器。与 `Items.Requirements` 合并过滤，未知角色保守显示。
- 观察背包不是人物背包 VM：从可见 `BPMV_Observe_C:GetNeoUIVM():GetSubModuleByKey(FName("Backpack"))` 获取；观察目标优先从自身 `RootData.npc_id` 读取，未知时只用该观察格子当次、物品编号匹配的原生置灰结果过滤武器，不写入装备资格缓存，不拿队伍头像选择代替。共享格子初始化钩子仍只改透明度。
- 实际送礼点击拒绝锁定 `ItemInfoSpec.bIsLocked`；`bOnlyForLayout` 占位不是可送实体。`BP_Gift_Base` 还检查实际 NPC 的 `GetNPCHobbies()` / 物品子类，再走品质/好感度流程。v4.24 合并这些过滤，并在关系/喜好变化后让原生 VM 重建。
- 原生 `RebuidFollowers` RVA `0xfbe3f0` 长 `3068` 字节：骑乘门槛直接退出，所以仅改已有随从动画无效。`wsmod_walk_rebuild` 在游戏线程运行版本校验的独立副本，重定位 `95` 处引用，只去掉副本偏移 `0x75` / `0xa0` 的两个显示门槛；不修改原游戏代码/骑乘标志，保留场景与剧情保护。复制 unwind 栈恢复信息，异常时禁用副本；游戏更新后代码不匹配则安全停用，不猜新地址。
- 步行覆盖收集每个实际 `JHPaperFlipbookComponent`，仅将骑乘状态 9 映射到普通移动，不接管 `bAutoCalcRunOrIdleState`、不按速度硬写 Idle/Run（跟随位移未必产生 Actor 速度），让原版驱动动画；不改速度、buff。关闭时恢复原显示属性、`FollowerCount`，原生重建随从并 `KeepFastRunState()`。
- 本版仅检查源码、离线模拟和编译，不代表已完成实机回归；需要退出游戏后同时更新 DLL / Lua。

## v4.25 速战输入与恢复

- 被动日志出现两次 v4.24 加载及重复 Y 记录，但不能仅凭日志判定同进程别名或多进程；v4.25 日志补 PID/DLL 地址。同进程命名映射共享 Lua owner、Y 按压锁、累积序号，最新加载实例控制循环；旧实例停止任务及钩子副作用。命名映射只属于当前进程，不读取其他游戏进程。
- `runtime_bridge.inc` 提供 `wsmod_runtime_claim` / `wsmod_runtime_poll`；Lua C 导出的返回值是 Lua 栈结果数量，不能直接返回状态数值。因此仍用每次加载独立的 `runtime_<token>.txt` 回执，字段 `owner|Y序号|GetTickCount64毫秒`，先删除旧回执，失败则不相信旧值。按序号差接收按键，重复轮询不重复计数；Y 不走共享 `trig.req`。500 ms 心跳停止后释放原生 Y，保留 LB/RB/扳机组合。
- 实际战斗角色全名作为生命周期标识，过滤 Default__ 控制器；连续战斗即使未采到场间状态也重置 over。新战按键保留，旧结算页需先消失才允许判定新战结算。
- 速战使用独立单调时钟；超时检查在 HUD/图标就绪返回之前执行，任务异常走同一恢复入口。先释放遮罩、音频、按键拦截，再恢复 1 倍和倍率上限，并只关闭模组开启的自动战斗。此保护依赖游戏线程继续执行，不能解救已经完全死锁的进程。
- 自动战斗必须确认开启后才加速或遮罩；速战倍率限制 3~20，超时限制 5~30 秒。已有用户配置不重写，超出范围时按安全上限运行。
- 步行日志的 `attempt to call a TrivialObject value (method 'GetComponentsByClass')` 不是速战任务报错；离线二进制确认实际反射名 `K2_GetComponentsByClass`，改用该方法收集所有精灵。

## 崩溃记录（避免重蹈）

| 时间 | 现象 | 原因 |
|---|---|---|
| 12:14 | 访问违例 0x9 | `ForEachUObject` 全量扫描 + 读属性 |
| 12:22 | 传送后数秒崩溃 | 换图期间脚本读取已销毁对象 → 加入 `stableWorld` 静默期 |
| 14:39 / 14:52 | 空指针 | 多个 `LoopAsync`+`ExecuteInGameThread`，UE4SS 报 `Ref was not function` → 改为单一游戏线程循环 |
| 22:09 | 启动 1 秒崩溃 | 主菜单阶段调用 `JHNeoUISubsystem:GetBattleModule()`（可能命中 CDO） |
