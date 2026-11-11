# APP 图标 + 启动图 配置说明（im-app）

## 一、APP 图标（Logo）

1. 把图标源图放本目录，命名为 **app_icon.png**
   - 尺寸：1024×1024，PNG，背景不透明
2. 执行（会自动生成 Android mipmap-hdpi~xxxhdpi 和 iOS 各尺寸）：

```bash
dart run flutter_launcher_icons
```

## 二、启动图（Splash）

1. 把启动页 logo 源图放本目录，命名为 **splash_logo.png**
   - 尺寸：1024×1024，PNG，**透明背景**
   - logo 主体居中，四周留白约 30%（Android 12+ 会按圆形裁剪）
2. 背景色：改 pubspec.yaml 里 `flutter_native_splash` 段的 `color`（默认 #ffffff）
3. 执行（自动生成 Android launch_background / Android 12+ 样式 + iOS LaunchImage）：

```bash
dart run flutter_native_splash:create
```

## 三、打包

```bash
flutter pub get   # 首次加依赖后必须执行
flutter build apk --release
```

> 配置总入口：项目根目录 `config/app_build.json`（应用名 / 包名 / 版本号 / 接口地址 / 图标路径都在这改）
> 改完执行：`dart run tool/apply_config.dart`
