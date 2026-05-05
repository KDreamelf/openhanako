# OCR Bundle

这里放 Windows 操作边车随安装包分发的 OCR 资源。

运行时不允许自动下载模型或运行库。正式发布包必须预置这些文件；缺文件属于打包错误，不是用户端恢复路径。

目录结构：

```text
ocr.manifest.json
text-detection.rten
text-recognition.rten
```

边车不会联网下载模型，只会读取本目录或 `HANAKO_WINDOWS_OPS_OCR_DIR` 指向的目录。
安装包脚本会显式要求核心文件存在，缺失时应当在打包阶段失败。
