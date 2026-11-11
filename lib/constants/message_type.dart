/// 消息类型常量（与后端一一对应）。
///
/// 聊天页渲染分发（_MsgRow）与发送逻辑统一引用此处，避免散落魔法数字。
/// 新增的链接卡片使用 [linkCard] = 11。
class MessageType {
  static const int text = 1; // 文本
  static const int image = 2; // 图片
  static const int file = 3; // 文件
  static const int voice = 4; // 语音
  static const int video = 5; // 视频
  static const int system = 6; // 群系统事件
  static const int call = 7; // 音视频通话信令
  static const int redPacket = 8; // 红包
  static const int transfer = 9; // 转账
  static const int card = 10; // 个人名片
  static const int linkCard = 11; // 链接卡片（网页小程序）
  static const int mergeForward = 12; // 合并转发（聊天记录，content 为 JSON）
  static const int e2Text = 13; // 端到端加密文本（§36 定稿，仅单聊；content 为密文 JSON）
  static const int location = 14; // 位置消息（content 为 JSON {lat,lng,name,address}）

  const MessageType._();
}
