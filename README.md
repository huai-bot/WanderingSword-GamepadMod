# WanderingSword-GamepadMod

《逸剑风云决》(Wandering Sword, UE 4.26) 的手柄操作增强模组：右摇杆当鼠标、UI 吸附、世界地图驿路传送、背包自动整理/隐藏/高亮等。

> 接手开发（人或 AI agent）请先读 [AGENTS.md](AGENTS.md)，游戏内部结构见 [docs/GAME_INTERNALS.md](docs/GAME_INTERNALS.md)。

## 适用版本

| 项目 | 版本 |
|---|---|
| 游戏 | v1.24.32（`JH-Win64-Shipping.exe`，UE 4.26） |
| UE4SS | RE-UE4SS v4.0.0 |
| 编译器 | Visual Studio（MSVC x64，C++17） |

原生部分有一处按游戏版本写死的地址（`ProcessEvent` RVA），游戏更新后需要重新确认，见 AGENTS.md。

## 功能

**右摇杆鼠标**
- 右摇杆移动指针，速度恒定（推杆幅度只决定方向）；游戏内可实时调速：`View + 十字键`（↑↓ ±50，←→ ±200）或键盘 `[` `]`（Shift 为 ±200）
- 指针使用游戏原版剑形图标，绘制在最上层，不会被游戏 UI 遮挡；游戏在前台时隐藏系统指针，并把指针限制在游戏窗口内
- UI 吸附：指针经过按钮时减速，松开摇杆时吸到附近按钮中心
- **鼠标优先**：用过右摇杆后 A = 鼠标左键；按十字键或推左摇杆后 A 恢复游戏原生功能（对话、选项、交互）
- 战斗中自动停用以上全部功能，手柄完全交还游戏

**按键**
- Start 固定打开人物界面的「队伍」栏目，再按关闭；不再沿用上次的任务、武学或经脉栏目（原为系统菜单）
- 交互判定半径从 35 扩大到 90（可配置）

**自动存档**
- 每 120 秒请求一次游戏原有自动存档，按现实时间计时；战斗、对话、菜单、加载或角色未落地时延后，恢复安全后再存

**世界地图**
- 地图打开时右摇杆交还游戏（原生拖拽、缩放）
- 手柄 `Y` / 键盘 `F` 打开驿路传送面板：按 中原/西域/关外/南疆/北地/海外 分页，地点按拼音字母排序；未到访的地点显示为灰色「未解锁」，不能传送，有驿站的城镇落点在驿站
- 面板操作：摇杆/十字键选择，LB/RB 或 Q/E 切换区域，A/回车/鼠标点击传送，B/Esc 关闭

**人物界面背包**
- 打开时切换到配置的默认排序（默认「类型」），之后每次打开自动整理一次
- 隐藏当前选中角色无法使用的物品：游戏置灰的武器、秘籍等，以及「仅限主角 / 某角色不可用 / 仅限某角色」的装备；切换角色或分类后自动重新隐藏
- 「全部」分类里不显示已学成（含游戏标「学成」）的秘籍/图纸、任务道具、烹饪/锻造/缝制材料和珍宝（书画、棋具、茶具、古籍、琴、花等），只在各自分类里显示；切换角色或分类时不闪烁
- 人物界面手柄跳过「属性」「装备」两栏：LT/RT 在头像、背包、底部按钮（上阵/坐骑/切磋/送礼）之间循环，十字键/左摇杆也不会停在这两栏，切换无闪烁；切回时回到原来的头像和背包格子
- 观察界面同样跳过「属性」「装备」：打开时焦点在切磋，LT/RT 在背包和底部按钮间切换，按上从底部按钮进入背包
- 战斗加速按钮 1 倍 → 2 倍 → 速战 → 1 倍循环：速战 = 游戏自带自动战斗 + 50 倍速，胜负照常由游戏判定；直接识别加速按钮操作，开场按键不会被忽略
- 速战期间默认遮住闪烁画面并临时静音**本游戏**，不影响其他应用；退出速战、结算或超时回退后恢复原来的静音状态，不改游戏音量设置
- 属性高于该角色同部位已穿装备的物品显示高亮框（默认蓝紫色，颜色可配置）

## 安装

1. 安装 UE4SS v4.0.0 到 `<游戏>\Wandering_Sword\Binaries\Win64\`（`dwmapi.dll` + `ue4ss\`）
2. 编译原生部分：`tools\build.bat`（生成 `build\xinput1_3.dll`）
3. 首次需要提取游戏指针图标：`powershell -File tools\extract_cursor.ps1`（游戏资源不随仓库分发）
4. 正常退出游戏后安装：`powershell -File tools\install.ps1`（备份放在 `D:\TOOLS\dshdata\dshbackup\WanderingSword-install_<时间>\`，保留目录结构；可用 `-Backup` 指定已有备份目录，明确不需要备份时用 `-NoBackup`）
5. 启动游戏。安装时默认关闭两个 UE4SS 日志窗口，但仍写日志：[UE4SS.log](<D:/GAME/Wandering Sword/Wandering_Sword/Binaries/Win64/ue4ss/UE4SS.log>) 中出现 `[GamepadTweaks] v4.x loaded`，[wsmod.log](<D:/TOOLS/AWSdata/WanderingSword/wsmod.log>) 中出现 `wsmod loaded` 即成功

卸载：删除 `Win64\xinput1_3.dll`，并在 `ue4ss\Mods\mods.txt` 里把 `GamepadTweaks` 改为 `0`。

## 配置

`D:\TOOLS\AWSdata\WanderingSword\wsmod.ini`（GBK 编码，模板见 `data/wsmod.ini`）：

| 段 | 键 | 说明 | 生效 |
|---|---|---|---|
| `[mouse]` | `speed` | 指针速度（像素/秒） | 游戏内调速会自动写回 |
| | `deadzone` | 摇杆死区 | 重启游戏 |
| `[snap]` | `enable` / `radius` / `friction` | 吸附开关 / 吸附距离（1080p 基准）/ 按钮上减速百分比 | 重启游戏 |
| `[interact]` | `range` | 交互判定半径（原值 35） | 3 秒内 |
| `[backpack]` | `auto_sort` | 打开人物界面自动整理 | 即时 |
| | `default_sort` | 1 珍贵 2 时间 3 价钱 4 类型 | 即时 |
| | `hide_unusable` | 隐藏当前角色用不了的装备 | 即时 |
| | `highlight_better` | 更好装备高亮 | 即时 |
| | `better_mode` | 0 严格（无属性更低且至少一项更高）/ 1 综合 | 即时 |
| | `same_weapon_type` | 武器只和同类型武器比较 | 即时 |
| | `tidy_all_tab` | 「全部」里隐藏已学成秘籍/图纸、任务道具、材料、珍宝 | 下次打开人物界面 |
| | `cell_hook` | 切换时防闪烁（生成格子时即隐藏） | 重启游戏 |
| | `prime_skip_panels` | 人物界面手柄跳过「属性」「装备」，LT/RT 在 头像→背包→底部按钮 间循环 | 下次打开人物界面 |
| | `quick_battle` | 加速按钮循环里加入速战（0 = 只有原版 1/2 倍） | 下一场战斗 |
| | `quick_speed` | 速战倍率 3~200（实测 20/50/100 都稳定） | 下一场战斗 |
| | `quick_timeout` | 速战超过这么多秒没打完就退回 2 倍，恢复声音，保留自动战斗直到结算 | 下一场战斗 |
| | `quick_mask` | 速战时遮住闪烁画面（默认 1） | 下一场战斗 |
| | `quick_mute` | 速战时临时静音本游戏（默认 1），退出后恢复原来的静音状态 | 下一场战斗 |
| | `highlight_rgb` | 高亮颜色，sRGB 十六进制，默认 `5C6CFF` | 即时 |

## 目录

```
src/native/wsmod.cpp       xinput1_3 代理 DLL：手柄过滤、鼠标、指针/传送面板/调速提示叠加层、UI 几何读取
src/native/xinput1_3.def   导出表（含序号 100-103）
src/lua/main.lua           UE4SS Lua 模组 GamepadTweaks：游戏状态检测、传送、背包、交互半径、UI 扫描
data/places.txt            传送地点表（由游戏 Maps / CourierStation 表整理）
data/wsmod.ini             默认配置
tools/                     编译、安装、提取指针、截取游戏画面
docs/                      游戏内部结构、更新记录
```

## 许可证

代码以 [MIT](LICENSE) 许可发布。游戏本体及其资源（包括由 `tools/extract_cursor.ps1` 从本机游戏中提取的指针图标）版权归原开发商所有，不在此许可范围内。

## 免责声明

非官方模组，与游戏开发商无关。仓库不包含任何游戏文件或资源。修改游戏可能导致存档异常，使用前请备份 `%LOCALAPPDATA%\Wandering_Sword\Saved`。
