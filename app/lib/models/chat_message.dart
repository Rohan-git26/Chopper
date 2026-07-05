import 'dart:io';

enum MessageSender { user, ai }

enum AttachmentType { image, file, audio }

/// A single attachment (image / file / recorded audio) carried by a message
/// or staged in the composer before sending.
class Attachment {
  final String path;
  final String name;
  final AttachmentType type;

  const Attachment({
    required this.path,
    required this.name,
    required this.type,
  });

  File get file => File(path);

  bool get isImage => type == AttachmentType.image;
}

/// A chat message. `text` is mutable because AI replies stream in token by
/// token over the ADK WebSocket and are appended to the in-flight message.
class ChatMessage {
  final String id;
  String text;
  final MessageSender sender;
  final List<Attachment> attachments;
  final DateTime createdAt;

  /// False while an AI reply is still streaming.
  bool isComplete;

  /// True when the AI reply is being delivered as audio (live voice turn).
  bool isVoice;

  ChatMessage({
    required this.id,
    this.text = '',
    required this.sender,
    this.attachments = const [],
    DateTime? createdAt,
    this.isComplete = true,
    this.isVoice = false,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isFromUser => sender == MessageSender.user;
}
