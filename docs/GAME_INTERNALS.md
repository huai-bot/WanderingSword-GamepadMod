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
- `SaveManager`（`BP_GameInstance_C` 子对象）：`LoadSlot(i)`、`SaveSlot(i, bAuto, name)`、`AutoSave()`。

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

- 打开人物界面 = `JHNeoUIPrimeModuleVM:Show()`；界面 `BPMV_Prime_C` → `BPMV_PrimeTeam_C` → `BPMV_PrimeTeamBackpack_C`。
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
- 游戏自己的「当前角色不可用/不可学」判定：格子显示数据（`ItemDisplay:GetData():DataToString()`）里的 `"not_learnable":true`，渲染为 `CMP.IMG_Not_Learnable` 可见（置灰）。武器按角色的武器类型、秘籍按能否学习计算，模组直接沿用。`GetBindedDataObj()` 取格子当前绑定的 `ItemInfoSpec`。
- `JHNeoUIItemUtil:BackpackItemCanDoubleClick_WDT(spec, npc)` 不是可用性判定（置灰的拳套也返回 true），不要用。
- 注意：`CMP_BackpackSortButton` 是另一个（移动端/旧版）整理按钮，电脑版人物界面里不存在。

## 物品与装备

- `ItemInfoSpec`：`ItemDefId, Num, Actions[], RandActions[], bOnlyForLayout, GainTime, …`，`GetDef()` 返回 `ItemInfoSetting` 行。
- 数据表 `…/Tables/Items.Items`（`ItemInfoSetting`）：`ID, EquipmentRank, Name, ItemType(EItemSubType), Quality, Requirements[RequirementSetting], Actions[ActionSetting], …`。
- `EItemSubType`：1 剑 2 刀 3 枪棍 4 拳 5 暗器 6 其他兵器；10 衣 11 帽 12 鞋 13 饰品；20+ 丹药、30+ 秘籍、40+ 材料……
- `ERequirementType`（装备实际只用到）：13 OnlyHero、41 ExcludeNPC、42 OnlyDesignatedNPC、60 bBuyDLC2。426 件装备里没有属性门槛。
- `EActionType` 4 = `CAttr`（加属性，`ID` 为属性编号，`Num` 为数值）；5 = `ABuff`。属性编号含义尚未整理。
- `NPCManager:GetNPCInfo(npcId, false)` → `TeamInfo`：`EquipmentSpecs[]`（已穿装备）、`ItemSpecs`、`AttributeSet`、`GetWeaponType()`。主角 npcId = 0。
- 当前在人物界面选中的角色：`TeamModuleVM.RootData` JSON 的 `focus_npc_index` + `data[i].npc_id`。

## 崩溃记录（避免重蹈）

| 时间 | 现象 | 原因 |
|---|---|---|
| 12:14 | 访问违例 0x9 | `ForEachUObject` 全量扫描 + 读属性 |
| 12:22 | 传送后数秒崩溃 | 换图期间脚本读取已销毁对象 → 加入 `stableWorld` 静默期 |
| 14:39 / 14:52 | 空指针 | 多个 `LoopAsync`+`ExecuteInGameThread`，UE4SS 报 `Ref was not function` → 改为单一游戏线程循环 |
| 22:09 | 启动 1 秒崩溃 | 主菜单阶段调用 `JHNeoUISubsystem:GetBattleModule()`（可能命中 CDO） |
