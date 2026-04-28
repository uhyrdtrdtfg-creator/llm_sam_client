# LLM SAM Client

一个纯本地 SwiftUI iOS 26 聊天客户端，支持：

- GPT / OpenAI Compatible Chat Completions API
- Claude / Anthropic Messages API
- 每个供应商独立保存 API Key、地址前缀、模型和最大输出 token
- API Key 存在 iOS Keychain，其他配置存在 UserDefaults
- 支持 HTTPS 与本地/内网 HTTP 地址前缀
- 支持从照片库选择图片作为输入
- 支持 Markdown 格式回复渲染
- 支持通过 Firecrawl 搜索网页并把结果注入给模型回答
- 支持可编辑系统提示和自动长期记忆

## 运行

```sh
xcodegen generate
open LLMSAMClient.xcodeproj
```

在 Xcode 里选择 `LLMSAMClient` scheme 后运行即可。当前工程最低系统版本是 iOS 26.0。

## 配置示例

OpenAI / GPT 兼容接口：

```text
地址前缀：https://api.openai.com/v1
模型：gpt-4.1-mini
```

Claude / Anthropic：

```text
地址前缀：https://api.anthropic.com/v1
模型：claude-3-5-sonnet-latest
```

客户端会自动拼接接口路径：

- OpenAI Compatible: `/chat/completions`
- Anthropic Claude: `/messages`

如果你使用转发服务或本地网关，地址前缀填到版本路径即可，例如 `http://127.0.0.1:8080/v1`。

## 图片与 Markdown

聊天输入框左侧的图片按钮可以添加图片。图片会在本地缩放到最长边 1600px 并转成 JPEG 后发出：

- OpenAI Compatible 使用 `image_url` 的 data URL 格式
- Anthropic Claude 使用 `source: { type: "base64" }` 格式

助手回复支持标题、段落、列表、引用和代码块 Markdown 渲染。

## Firecrawl 联网搜索

在配置页打开“使用 Firecrawl 联网”，填写 Firecrawl API Key（`fc-...`）。发送消息时，客户端会先调用：

```text
POST https://api.firecrawl.dev/v2/search
```

请求会使用 `scrapeOptions.formats = ["markdown"]` 抓取搜索结果正文，然后把结果作为上下文交给模型。Firecrawl API Key 存在 iOS Keychain。

## 记忆与系统提示

配置页的“记忆与系统提示”支持：

- 基础系统提示：手动编辑，随每轮请求发送给模型
- 自动记忆：记录用户偏好、项目上下文、行文风格和注意事项
- 自动总结长期记忆：开启后，每次助手回复完成会再调用一次当前模型更新记忆

记忆按供应商分别保存在本机 UserDefaults。自动总结提示要求模型不要保存 API Key、密码、令牌和一次性搜索结果。
