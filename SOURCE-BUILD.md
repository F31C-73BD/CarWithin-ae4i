# 源码构建说明

使用 Xcode 打开 TDSCarKit.xcodeproj，选择 TDSCarKit scheme，配置自己的开发团队、Bundle ID 和签名，再构建 iOS 目标。最低部署目标为 iOS 16.0。

源码不包含配件认证身份、私钥、证书或 Apple 签名材料。没有可用身份时应用可编译，但本机 CarPlay 连接需要另行配置有效身份。Tools/generate_project.py 会将本地 App/BundledIdentity 内的文件加入生成的工程，请勿把该目录中的身份材料提交到公开仓库。

发布安装包与源码应对应同一代码版本。第三方许可与来源见 THIRD_PARTY_NOTICES.txt 和 LICENSES。

## 没有 Mac 时出未签名 IPA

`.github/workflows/build-unsigned-ipa.yml` 在 GitHub 的 `macos-14` 运行器上编译并打包未签名 IPA，不需要开发团队或证书：

1. 把源码推送到自己的 GitHub 仓库（公开仓库的 Actions 分钟数不额外计费）。
2. 在 Actions 里运行 **Build unsigned IPA**，等它跑完。
3. 下载 `CarWithin-unsigned-ipa` 构件，用 Sideloadly、AltStore、TrollStore 等按自己的方式签名安装。

命令等价于：

```sh
xcodebuild -project TDSCarKit.xcodeproj -scheme TDSCarKit -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM="" build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/TDSCarKit.app Payload/
zip -qry CarWithin-unsigned.ipa Payload
```

工程里 `CODE_SIGN_ENTITLEMENTS = "$(TDS_WIFI_ENTITLEMENTS)"` 的变量没有定义，因此关闭签名时不需要额外处理权限文件。iOS 私有接口与配件身份仍需按上面说明在真机侧准备。
