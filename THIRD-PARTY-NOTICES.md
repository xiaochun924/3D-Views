# 第三方组件与许可声明

本仓库包含第三方开源代码的移植版本。按各自许可要求，此处保留原始署名。

---

## sldprt2step

- **上游仓库**：https://github.com/BlinkingSun/sldprt2step
- **上游作者**：BlinkingSun
- **许可**：Apache License 2.0（全文见 `LICENSE` 一节所附链接）
- **用途**：`3D-Views/Models/SLDPRT/` 下的 Swift 代码是该项目的忠实移植，用于把
  SolidWorks 零件文件（`.sldprt`）里的 Parasolid B-rep 转成 ISO 10303-21（STEP AP214）文本，
  再交给本 App 已有的 OpenCASCADE 管线读取。
- **对应关系**：

  | 上游 Python 文件 | 本仓库 Swift 文件 |
  | --- | --- |
  | `sldprt2step.py` | `3D-Views/Models/SLDPRT/SLDPRTConverter.swift` |
  | `sldprt2step_lib/jscompat.py` | `3D-Views/Models/SLDPRT/SLDPRTCompat.swift` |
  | `sldprt2step_lib/container/{blobs,sw3d,ole_cfb,container}.py` | `3D-Views/Models/SLDPRT/SLDPRTContainer.swift` |
  | `sldprt2step_lib/xt/schema.py` | `3D-Views/Models/SLDPRT/SLDPRTXTSchema.swift` |
  | `sldprt2step_lib/xt/reader.py` | `3D-Views/Models/SLDPRT/SLDPRTXTReader.swift` |
  | `sldprt2step_lib/xt/geom.py` | `3D-Views/Models/SLDPRT/SLDPRTGeometry.swift` |
  | `sldprt2step_lib/step/mapper.py` | `3D-Views/Models/SLDPRT/SLDPRTStepMapper.swift` |
  | `sldprt2step_lib/step/convert.py` | `3D-Views/Models/SLDPRT/SLDPRTConverter.swift` |

### 更上游：open-sld-to-step

`sldprt2step` 本身是 **open-sld-to-step 0.1.0** 的 Python 移植。后者是一份
**Node.js / TypeScript 洁净室实现**，同样以 Apache License 2.0 发布。

`open-sld-to-step` 在其 NOTICE 中声明：其实现**仅依据公开规范与公开资料**写成 ——

- **[MS-CFB]** Compound File Binary File Format（Microsoft 公开规范）；
- **ISO 10303**（STEP）系列标准；
- **公开的 Parasolid B-rep 拓扑文献**（body → region → shell → face → loop → edge → vertex）；
- **公开的、无分发限制的 CAD 样例文件的可观测字节结构**
  （NIST MBE PMI Validation and Conformance Testing 数据集；美国政府作品，
  依 17 U.S.C. §105 属公有领域）。

并明文声明：**未使用、未参考、未逆向 Dassault Systèmes、Siemens 或任何其他厂商的
专有源码、头文件、SDK 或 API 文档。**

本仓库的 Swift 移植延续同一洁净室边界：只读公开规范与上述公开资料。

### 商标

- **SolidWorks®** 是 Dassault Systèmes SolidWorks Corporation 的注册商标。
- **Parasolid®** 是 Siemens Industry Software Inc. 的注册商标。

此处仅作格式标识之用，不表示任何隶属、赞助或背书关系。
