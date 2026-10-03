# 3D Views — 交接文档

> 生成于 HEAD `8c34cb4`（`main`）。**实测**=量过且有数据；**推断**=基于实测的推论，未直接验证。

---

## 〇、硬性规则（优先级最高）

- **语言**：所有回复一律中文（长期有效）。
- **技术栈**：iOS 开发用 Swift 6.2；优先 Apple 官方套件（SwiftUI、SwiftData、Observation、NavigationStack、App Intents 等），不造轮子、不引第三方替代；确实无法满足时先说明原因并征得确认。
- **方向确认流程（不得跳步）**：提想法 → 需求识别 → GitHub 调研相似实现 → 列候选方案 → **等用户明确确认方向** → 再动手写代码。
- **禁止死循环**：同一操作重复（相同工具+相同或近似参数）、或推理原地打转，累计达 **10 次**即自动终止——停止重试，总结已尝试内容与失败原因，向用户报告并等待指示。
- **思维原则**：① 执行前先检查前提，核对有无错误前提/逻辑跳跃/信息缺失；② 独立判断，不一味迎合，区分事实、预测、主观观点；③ 核实来源，涉及数字、人物、结论不凭印象断言；④ 发现用户说得不对直接指出，说明依据与风险；⑤ 主动提醒用户可能忽略的变量、成本、偏差。
- **协作约定**：重要决策、新约定、新项目追加到本文件对应章节；只记持久信息，不记过程流水账；保持短小可扫读。

---

## 一、当前状态

| 项 | 值 |
|---|---|
| 仓库 | `C:\Users\14548\Documents\GitHub\3D-Views` |
| 分支 / HEAD | `main` / `8c34cb4 Keep only the share extension as the import path` |
| 工作区 | **干净**，无未提交改动 |
| 支持格式 | `step` `stp` `stl` `iges` `igs` `obj` `brep` `sldprt` |
| 明确不支持 | `sldasm` `slddrw` `x_t` `x_b` `jt` |

**定位**：iOS CAD 查看器，SwiftUI + SceneKit，经 `OCCTSwift` 桥接 OpenCASCADE。带 SolidWorks 风格测量功能。

**唯一保留的导入链路**：分享扩展 → 拷进 App Group 收件箱 → 主 App 每次激活扫描导入。整条链路**不依赖任何 URL 投递**——文件是扩展亲手放进共享容器的，这是它比系统文档打开路径可靠的地方（实测）。

### 关于 `.github/workflows/ios-build.yml`

**以用户文件夹里的为准，不要推送**（用户明确要求，长期有效）。当前工作区版本已含打包加固步骤（上报编译错误到 Issue、打包 IPA、发布 IPA 到 Release、上传 IPA），与 HEAD 一致。

---

## 二、已实测证伪、不要再试的路

### 1. 扩展拉起主 App —— 不可行

- `extensionContext.open` 回调**每次都是 `didOpen == false`**
- Safari 也**打不开** `3dviews://import`

依据：`Views/Views-Share/ShareViewController.swift:15-16` 与 `:207-209`（注释形式的历史记录）。

**iOS 从设计上不给 share extension 拉起宿主 App 的能力**。不要再为「分享后自动跳转」花构建次数。可行流程是：分享 → 用户手动切回 → App 自己打开刚导入的文件（用户已确认后半段工作正常）。

### 2. 文档打开路径（Files 的「打开方式」）—— 三种配置全部失败

真机实测矩阵（每行一次构建 + 安装）：

| LSHandlerRank | LSSupportsOpeningDocumentsInPlace | 拷进 Inbox | URL 送达 |
|---|---|---|---|
| `Alternate` | `false` | 否 | 否 |
| `None` | `false` | 是（用一个无人声明的 `.ipa` 验证） | — |
| `Alternate` | `true` | 否（设计如此） | 否 |

原因（推断）：文档打开路径的 URL 只走 scene 的 `connectionOptions.urlContexts`，而本 App **没有接管 scene**——自定义 `SceneDelegate` 会让应用启动即爆栈，已删除。

崩溃签名：`Thread stack size exceeded due to excessive recursion` / `AppSceneDelegate.responds(to:) ← repeating, self-recursive`，来自提交 `72fdde7`，报告 `3D-Views-2026-10-01-162946.ips`。

带 `LSHandlerRank: None` 的构建还让 App 从「打开方式」列表里消失（用户原话：「打开方式没有3dviews了」）。

### 3. `3dviews://` URL scheme —— 已整体删除

`CFBundleURLTypes`、6 条 `CFBundleDocumentTypes`、6 条 `UTExportedTypeDeclarations` 都在 `8c34cb4` 里从 `project.yml` 和 `Info.plist` 删掉了。`AppGroup.swift` 里的 `wakeUpScheme` / `wakeUpURL` / `wakeUpURLText` 一并删除。

---

## 三、`.sldasm` 支持：查到哪一步

### 已查实（实测）

样本：`E:\00.魏淳辉-设计文件\A.截止阀\2026-翻盘方案\EGH20CA-2-R1200.SLDASM`（1,224,918 字节）

| 探测项 | 结果 |
|---|---|
| OLE2 签名（前 4096 字节） | **未命中**（offset = −1） |
| 明文 `TRANSMIT` / `P_S_` / `PARA` / `Contents` | **各 0 次** |
| `14 00 06 00 08 00`（`SL_SW3D_SECTION_MARKER`） | **111 处**，第一处在**偏移 20** |
| 可解压分节 | **40 个**，全部成功 |
| 通过 `slIsParasolidBuffer` 的分节 | **0 个** |

**结论（实测）：`.sldasm` 是 SW3D 存储格式，不是 OLE2。它没有 Parasolid transmit。**

这与 `.sldprt` 的区别就是全部问题所在：`.sldprt` 能打开，是因为零件容器里**藏着 Parasolid XT transmit**，`Models/SLDPRT/` 把它挖出来转成 STEP 文本，再交给 `Shape.loadSTEP`。

装配体没有这个 transmit，喂给 `SLDPRTConverter.convert(data:fileName:)` 会在第一道门抛 `no_parasolid_geometry`——即 `Views/Models/SLDPRT/SLDPRTConverter.swift:40-42`。

### 好消息：装配体结构是明文可读的

分节 `0x00001d1e`（24,908 字节）里直接可见：

```
moAssembly_c
moNodeName_c
moReference_c
moCStringHandle_c
moVisualProperties_c
moUnitsTable_c
moLengthUserUnits_c
```

分节 `0x00000174`（45,056 字节）里有 **44 个组件条目**，每个带 GUID + 变换矩阵（`mgXform_c`，`swRefPlaneSWStandard` / `swRefPlaneUnrecognized`）。

最大的分节 `0x00005f70`（1,198,991 字节）里有 tessellation 类名：

```
uoTempPartTessData_c
uoTempBodyTessData_c
uoTempFaceTessData_c
uoTempSubAssemblySHDData_c
uoTempAssemblySHDData_c
```

**也就是说几何数据是在文件里的**，只是按 SW3D 自己的编码存放。

### 卡在哪

**没能解出 `0x5f70` 的布局。**

已知结构线索：
- 三个 Tess 类名集中在分节**前 0.6%**（`uoTempPartTessData_c` 在 `0x000019dc`）
- 分节的 `u32`/`f64` 头是**混合宽度**：`[1, 1, 858993459, 1070805811, ...]`，其中 `858993459` 与 `1070805811` 正是 double `0.3` 与 `1000.0` 的两半
- `01 00 00 00 01 00 00 00` 这个 8 字节模式重复 **715 次**

> ⚠️ **一个作废的数据，不要引用**：早期探针报过「17.31% 疑似坐标」。**那个数字不算证据**——随机 `f32` 字节流本来就会产生大量小数值（`f32` 指数分布所致），17% 不显著高于噪声。同理 `i32` 扫描的「225/1024 落在 [0,200000)」也是噪声水平。**这两个数字什么都没证明。**

### 已排除的上游

`THIRD-PARTY-NOTICES.md` 记录的 `Models/SLDPRT/` 上游 **[`BlinkingSun/sldprt2step`](https://github.com/BlinkingSun/sldprt2step)**，其 README 明确写着：

> - **Parts only.** `.SLDASM` assemblies and `.SLDDRW` drawings are not supported.

上游自己也不支持装配体，缺口一致。其管线第 1 步依赖 **[MS-CFB] OLE** 容器——而 `.sldasm` 不是 OLE 容器，连这一步都过不了。

上游许可声明（写新代码时的约束）：clean-room implementation，**不含任何 CAD 厂商的专有源码/SDK/API 文档**。

---

## 四、`.easm`（eDrawings）—— 顺带查实的

样本：`EGH20CA-2-R1200.EASM`（92,485 字节，与上面 `.SLDASM` 同款零件）

### 已查实（实测）

它是 **ZIP**（首字节 `50 4b 03 04`），5 个条目：

| 条目 | 原始 / 压缩 |
|---|---|
| `eModel` | 87877 / 86596 |
| `preview.jpg` | 4680 / 4343 |
| `materials.xml` | 8535 / 759 |
| `scene.xml` | 805 / 295 |
| `OLE` | 12 / 6 |

- `eModel` 开头是明文 ASCII **`;; HSF V19.10\n`** → **HOOPS Stream File**（Tech Soft 3D），eDrawings 用的就是它。**不是 Parasolid transmit**，`Models/SLDPRT/` 那套挖法用不上。
- `scene.xml` 805 字节全是光照/环境，**无装配树、无组件表、无零件引用**
- `materials.xml` 实体名 `shared/body4`、`shared/body4/body4sub0` → **确实是多体装配**
- `OLE` 条目 12 字节 ASCII `.2..........`，只是版本标记

### 卡在哪（推断）

- 版本串之后 `49 04 00 00` = 1097、`42 00 00 00` = 66，疑似段长度/计数
- 0x00 字节仅 221 个（0.25%）；**字节直方图最高频仅 0.51%**，前 12 名全在 0.47–0.51% → 分布近乎均匀 = **内部已压缩**（正好解释外层 ZIP 为何压不动它，86596/87877）
- HSF 格式定义**不像 STEP 那样公开**；Tech Soft 3D 只提供商业库（HOOPS Exchange / Visualize）
- 即便解开，拿到的也是**场景图 + 几何流**，更接近「一堆网格」而非 `ViewerViewModel.swift:596` 期望的 B-rep 拓扑

---

## 五、待办与阻塞

### 阻塞项

| 项 | 状态 |
|---|---|
| `8c34cb4` 真机验证 | **未回报** |
| 推送凭据缺 `workflow` scope | 已不适用：**用户要求不要推送** |

### 待办（按优先级）

1. **测量功能重构**（用户痛点：测量「一点也不好用」、显示「不清晰」）
   - 已产出调研报告 [3dviews-research-report.md](3dviews-research-report.md)，核心结论：
     - 主流 CAD 工具（Onshape / Fusion 360 / SOLIDWORKS / Shapr3D）测量**全部是基于实体**（边/面/顶点/圆柱/圆）的拾取，点拾取只是辅助层；本项目「孤立点收集候选数组、逐个点击」的模型**与所有主流产品相反**，需重构为实体拾取
     - **预选高亮（hover / dynamic highlighting）与选中高亮是两个独立状态**，必须分开实现（OCCT 的 `GetHilightPresentation` vs `GetSelectPresentation`）
     - 移动端特有问题：手指遮挡目标（详见报告）
   - 下一步：实体拾取 + 预选高亮 + 测量 HUD——**动手前仍需走方向确认流程**
2. **`8c34cb4` 真机验证**（唯一判据：诊断页 `扩展启动于`）
   - 分享一个 `.STEP`，弹窗应显示 `已导入 xxx.STEP` / `打开 3D Views 查看` / `完成`
   - 进「导入诊断」看 **`扩展启动于`**：**时间变新** = 扩展跑起来了；**仍是旧值** = 扩展进程未启动，方向转 `NSExtensionPrincipalClass` / 签名
   - `ae49100`（模块限定类名 `$(PRODUCT_MODULE_NAME).ShareViewController`）骑在同批构建里，一次验证两件事
3. **`.sldasm` 原生读几何**（用户已明确要求）
4. **`.sldasm` 拒绝提示改写**（确定收益，与路线选择无关）
   - 当前提示在 `Views/ViewModels/ViewerViewModel.swift:648-649`：
     > 暂不支持 SolidWorks 装配体（.sldasm）原生格式。请在原软件里另存为 STEP 或 IGES 后再打开。
   - 问题：**没提本 App 其实支持 `.sldprt`**，也没提装配体可以**另存为零件**
5. **`.easm` / HSF 支持**（暂缓，用户说「先做 `.sldasm`」）

---

## 六、`.sldasm` 下一步：三条路线

| 路线 | 内容 | 可行性 |
|---|---|---|
| **一** | 继续硬啃 `0x5f70` 的 tessellation 布局 | **未证实**。当前样本 1.2MB / 44 组件 / 含大量标准件，是盲解的最坏情况，且**没有已知答案可对照**，无法分辨「解对了」还是「巧合」 |
| **二** | 提供一个**单组件最小 `.sldasm`**（一个长方体/圆柱，不导入标准件）作为 ground truth | 让路线一**可验证**。知道预期三角形数与包围盒后，候选布局要么对上要么对不上 |
| **三** | SolidWorks 里**另存为零件**（Save As → `.sldprt`） | **很可能可行，零新代码**。装配体被烘焙成单文件，里面就有 Parasolid transmit |

关于路线三的实测依据：`Views/Models/SLDPRT/SLDPRTConverter.swift:63-65` **已经**会把多个 `body_type == 1` 实体合并成一个 STEP 并命名为 `Body1`、`Body2`…… —— **多实体处理本来就有**。

### 若要按路线一/二推进，建议的下一步探针

1. 检查 `0x5f70` 内部是否还有**嵌套记录头**——按 `SLDPRTContainer.swift:415-422` 的读法：`typeID` 在 `idx+6`、`csz` 在 `idx+14`、`dsz` 在 `idx+18`、`nl` 在 `idx+22`
2. 若能走通记录链，应能拿到带声明数量的顶点缓冲与索引缓冲
3. **用 ground truth 校验**：找一个面的三角形数，验证其后字节是否恰好构成那么多 `f32` 三元组，且包围盒与模型尺寸吻合

**除此之外的一切都是对噪声做模式匹配。**

---

## 七、`.sldasm` 落地时必须同时改的 8 个注册点

| # | 位置 | 说明 |
|---|---|---|
| 1 | `Views/Models/FileHistory.swift:72-79` | `supportedExtensions` —— 运行时门禁，交接 / 沙箱扫描 / 拒绝提示三处都查它 |
| 2 | `Views/Models/FileHistory.swift:91-97` | `knownUnsupportedFormats` |
| 3 | `Views/ViewModels/ViewerViewModel.swift:581-587` | `ModelFormat` 枚举 case |
| 4 | `Views/ViewModels/ViewerViewModel.swift:596-601` | `isBrep`（穷尽 switch） |
| 5 | `Views/ViewModels/ViewerViewModel.swift:603-612` | `label`（穷尽 switch） |
| 6 | `Views/ViewModels/ViewerViewModel.swift:619-629` | `ModelFormat.named(_:)` |
| 7 | `Views/ViewModels/ViewerViewModel.swift:668-687` | `loadFile` 装载 switch（穷尽） |
| 8 | `Views/Views/HomeView.swift:22`、`Views/Views/SettingsView.swift:44` | 用户可见文案（**这两处目前连 sldprt 都没提**） |

> **关键约束**：`Views/Models/FileHistory.swift:65` 写着
> 「Every entry here has a real reader behind it, which is the only thing that makes it honest to list.」
> —— **`supportedExtensions` 里每一项都必须有真实读取器**。没有读取器就加后缀是撒谎。

### 结构性硬阻塞

全仓库 `grep` `TopoDS_Compound|addShape|BRep_Builder|makeCompound|Compound` 只命中**两处注释**（`Views/Models/SLDPRT/SLDPRTCompat.swift:18`、`Views/Models/SLDPRT/SLDPRTContainer.swift:28`，均为 MS-CFB 说明）。

**代码中不存在任何 compound 或多 shape 概念**，而量测按单一 shape 设计：
- `Views/ViewModels/ViewerViewModel.swift:596` — `var isBrep: Bool`
- `Views/ViewModels/ViewerViewModel.swift:1943` — `var usesEntityMeasurement: Bool { isBrep }`

装配体必须先决定：**合并成 `TopoDS_Compound` 当一个 shape**，还是**改造成多 shape 模型**。

---

## 八、环境与运维事实

| 项 | 值 |
|---|---|
| 本机 Xcode | **无**。CI 是 Swift 编译的权威 |
| CI | GitHub Actions macOS（macos-latest，Xcode 26.6） |
| 工程真源 | **`Views/project.yml`**（XcodeGen） |
| ⚠️ | CI 每次跑 `xcodegen generate`，用 `project.yml` 的 `info.properties` **重写** `Info.plist`。**只改 `Info.plist` 无法影响产物** |
| App Group | `group.ffcd1c12e1a9728e.1`（容器在重装后仍存活） |
| Release tag | `unsigned-ipa` 每次推送都删除重建，所以总是最新 IPA |
| 推送代理 | `git config http.https://github.com.proxy http://127.0.0.1:7897`<br>`git config https.https://github.com.proxy http://127.0.0.1:7897` |

### 已知噪声（无害，别当故障）

- 每次提交都有 `warning: in the working copy of '...', LF will be replaced by CRLF the next time Git touches it`
- `git push` 进度写 stderr，PowerShell 报 `NativeCommandError`，但**推送成功**（当前已不推送）

### 本机 Python

系统 `python` 是 Windows Store 桩（`WindowsApps\python.exe`），**exit 9009 无输出**。真解释器：

```
C:\Users\14548\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe
```

### 探针脚本位置

`sldasm-probe\`（`probe.py` 分节扫描、`probe2.py` 分节分类、`probe3.py`/`probe4.py` 结构剖析、`dump_names.py` 类名提取）与 `easm-probe\`（解出的 EASM 条目）。**纯探针产物，随时可删。原始 `.sldasm` / `.EASM` 文件全程未被修改。**

### GitHub 通道（host 侧探针结果）

```
[OK ] token            0ms
[OK ] api-direct       531ms  HTTP 200; rate limit 5000/5000
[OK ] html-direct      1997ms HTTP 200
[FAIL] gh-installed    gh not on PATH
[FAIL] git-installed   git not on PATH
```

→ 读仓库用 `github_*` 工具（host 侧直连），**不要用 shell 里的 `curl`/`gh`/`git`** 去访问 GitHub（沙箱常破坏 TLS/代理）。

### 用户偏好

- **不要推送**：`ios-build.yml` 以用户文件夹里的为准，不要 `git push`。

---

## 九、踩坑记录（别重犯）

1. **`ZipFile.ExtractToDirectory($src,$dst,$true)` 在 PowerShell 里炸。** `$true` 被绑到 `entryNameEncoding` 参数：
   `无法将“ExtractToDirectory”的参数“entryNameEncoding”(其值为“True”)转换为类型“System.Text.Encoding”`
   → 解压整体失败，后续读取全打在不存在文件上，token 计数扫描**输出全 0**。**那份结果整体作废。** 改用两参数重载。
   **教训：探针返回可疑的全 0 时，先查 stderr 里有没有失败的准备步骤。**
2. **不要推测「用户测的是旧版本」。** 用户已明确纠正：「我每次测试都是按照最新构建的来的 不要推测版本问题了」。
3. **`.appex` 不会被 `find -name "*.app"` 匹配**（glob 是尾部锚定的）——这个理论已实证证伪。
4. **`~` 前缀在 `knownUnsupportedFormats` 里查不到**：iOS 给的临时文件路径可能带 `~` 或大写，`coordinate`/`coordination` 类小动作会漏。
5. **文档数字要与代码现状对账。** 本次核对发现 `Views/Views/HomeView.swift:22` 实际文案是「支持 STEP、IGES、STL、OBJ、BREP。」——**漏了 sldprt**，与第五节待办 8 的描述一致。改文档时不要照抄旧结论，回到源文件核。
