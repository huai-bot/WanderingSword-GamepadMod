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
- Start 打开人物界面（原为系统菜单）
- 交互判定半径从 35 扩大到 90（可配置）

**世界地图**
- 地图打开时右摇杆交还游戏（原生拖拽、缩放）
- 手柄 `Y` / 键盘 `F` 打开驿路传送面板：按 中原/西域/关外/南疆/北地/海外 分页，只列出到访过的地点，有驿站的城镇落点在驿站
- 面板操作：摇杆/十字键选择，LB/RB 或 Q/E 切换区域，A/回车/鼠标点击传送，B/Esc 关闭

**人物界面背包**
- 打开时切换到配置的默认排序（默认「类型」），之后每次打开自动整理一次
- 隐藏当前选中角色无法使用的物品：游戏置灰的武器、秘籍等，以及「仅限主角 / 某角色不可用 / 仅限某角色」的装备；切换角色或分类后自动重新隐藏
- 「全部」分类里不显示已学成的秘籍/图纸和任务道具，只在各自分类里显示
- 属性高于该角色同部位已穿装备的物品显示高亮框（默认蓝紫色，颜色可配置）

## 安装

1. 安装 UE4SS v4.0.0 到 `<游戏>\Wandering_Sword\Binaries\Win64\`（`dwmapi.dll` + `ue4ss\`）
2. 编译原生部分：`tools\build.bat`（生成 `build\xinput1_3.dll`）
3. 首次需要提取游戏指针图标：`powershell -File tools\extract_cursor.ps1`（游戏资源不随仓库分发）
4. 安装：`powershell -File tools\install.ps1`（会先备份被替换的文件）
5. 启动游戏。UE4SS 控制台出现 `[GamepadTweaks] v4.x loaded`，`D:\TOOLS\AWSdata\WanderingSword\wsmod.log` 出现 `wsmod loaded` 即成功

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
| | `tidy_all_tab` | 「全部」里隐藏已学成秘籍/图纸、任务道具 | 即时 |
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
