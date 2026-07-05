import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../services/omi_device_service.dart';
// Bluetooth scan/connect UI moved to a dedicated DevicePage.

/// The one and only screen: a chat surface wired to [ChatProvider].
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final ImagePicker _imagePicker = ImagePicker();

  int _lastRevision = -1;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {})); // toggle mic/send button
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _autoScroll(int revision) {
    if (revision == _lastRevision) return;
    _lastRevision = revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _send(ChatProvider provider) async {
    final text = _textController.text;
    if (text.trim().isEmpty && provider.staged.isEmpty) return;
    HapticFeedback.mediumImpact();
    _textController.clear();
    await provider.sendText(text);
  }

  // ---- Attachment pickers ---------------------------------------------------

  Future<void> _openAttachMenu(ChatProvider provider) async {
    FocusScope.of(context).unfocus();
    final choice = await showModalBottomSheet<_AttachChoice>(
      context: context,
      backgroundColor: const Color(0xFF1F1F25),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetTile(ctx, Icons.photo_camera_outlined, 'Take photo', _AttachChoice.camera),
            _sheetTile(ctx, Icons.photo_library_outlined, 'Photo library', _AttachChoice.gallery),
            _sheetTile(ctx, Icons.attach_file, 'Choose file', _AttachChoice.file),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    switch (choice) {
      case _AttachChoice.camera:
        await _pickImage(provider, ImageSource.camera);
      case _AttachChoice.gallery:
        await _pickImage(provider, ImageSource.gallery);
      case _AttachChoice.file:
        await _pickFile(provider);
    }
  }

  Widget _sheetTile(BuildContext ctx, IconData icon, String label, _AttachChoice value) {
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
      onTap: () => Navigator.of(ctx).pop(value),
    );
  }

  Future<void> _pickImage(ChatProvider provider, ImageSource source) async {
    try {
      final picked = await _imagePicker.pickImage(source: source, imageQuality: 85);
      if (picked == null) return;
      provider.addAttachment(Attachment(
        path: picked.path,
        name: picked.name,
        type: AttachmentType.image,
      ));
    } catch (_) {}
  }

  Future<void> _pickFile(ChatProvider provider) async {
    try {
      final XFile? file = await openFile();
      if (file == null) return;
      provider.addAttachment(Attachment(
        path: file.path,
        name: file.name,
        type: AttachmentType.file,
      ));
    } catch (_) {}
  }

  // ---- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        _autoScroll(provider.revision);
        return Scaffold(
          backgroundColor: const Color(0xFF0E0E12),
          appBar: _buildAppBar(context, provider),
          body: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            child: Column(
              children: [
                Expanded(child: _buildMessages(provider)),
                _buildComposer(context, provider),
              ],
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, ChatProvider provider) {
    final (color, label) = switch (provider.connection) {
      AgentConnection.connected => (const Color(0xFF29CC8F), 'Connected'),
      AgentConnection.connecting => (Colors.amber, 'Connecting…'),
      AgentConnection.disconnected => (Colors.redAccent, 'Offline'),
    };
    return AppBar(
      backgroundColor: const Color(0xFF15151B),
      elevation: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Chopper', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 12)),
            ],
          ),
        ],
      ),
      actions: [
        if (provider.connection == AgentConnection.disconnected)
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: provider.retryConnection,
          ),
      ],
    );
  }

  Widget _buildMessages(ChatProvider provider) {
    if (provider.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 80),
          child: Text(
            'Ask anything — text, voice, images or files.',
            style: TextStyle(color: Colors.grey[500]),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
      itemCount: provider.messages.length,
      itemBuilder: (context, i) => _MessageBubble(message: provider.messages[i]),
    );
  }

  Widget _buildComposer(BuildContext context, ChatProvider provider) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (provider.staged.isNotEmpty) _buildStagedStrip(provider),
            if (provider.deviceState != DeviceConnectionState.disconnected)
              _buildDeviceAudioChip(provider),
            provider.voiceActive
                ? _buildRecordingBar(provider)
                : _buildInputBar(context, provider),
          ],
        ),
      ),
    );
  }

  Widget _buildStagedStrip(ChatProvider provider) {
    return Container(
      height: 74,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: provider.staged.length,
        itemBuilder: (context, i) {
          final a = provider.staged[i];
          return Container(
            width: 64,
            height: 64,
            margin: const EdgeInsets.only(right: 8, top: 6),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: const Color(0xFF23232B),
                    borderRadius: BorderRadius.circular(14),
                    image: a.isImage
                        ? DecorationImage(image: FileImage(a.file), fit: BoxFit.cover)
                        : null,
                  ),
                  child: a.isImage
                      ? null
                      : Icon(
                          a.type == AttachmentType.audio ? Icons.graphic_eq : Icons.insert_drive_file_outlined,
                          color: Colors.white70,
                        ),
                ),
                Positioned(
                  top: -6,
                  right: -6,
                  child: GestureDetector(
                    onTap: () => provider.removeAttachment(i),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 13, color: Colors.black),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildInputBar(BuildContext context, ChatProvider provider) {
    final hasText = _textController.text.trim().isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _circleButton(
          icon: Icons.add,
          filled: false,
          onTap: () => _openAttachMenu(provider),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1F1F25),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: const Color(0xFF35343B)),
            ),
            child: TextField(
              controller: _textController,
              focusNode: _focusNode,
              minLines: 1,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                hintText: 'Message Chopper…',
                hintStyle: TextStyle(color: Colors.grey),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 10),
              ),
              onSubmitted: (_) => _send(provider),
            ),
          ),
        ),
        const SizedBox(width: 8),
        hasText
            ? _circleButton(
                icon: Icons.arrow_upward,
                filled: true,
                enabled: provider.canSend,
                onTap: () => _send(provider),
              )
            : _circleButton(
                icon: Icons.mic,
                filled: true,
                enabled: provider.isConnected,
                onTap: () {
                  HapticFeedback.lightImpact();
                  FocusScope.of(context).unfocus();
                  provider.startVoice();
                },
              ),
      ],
    );
  }

  Widget _buildDeviceAudioChip(ChatProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1F6E63),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(color: Color(0xFF29CC8F), shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            const Text('Device Audio', style: TextStyle(color: Colors.white, fontSize: 12)),
            if (provider.deviceBattery != null) ...[
              const SizedBox(width: 6),
              Text('${provider.deviceBattery}%', style: TextStyle(color: Colors.grey[300], fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingBar(ChatProvider provider) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F25),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF35343B)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            onPressed: provider.cancelVoice,
          ),
          const Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _PulsingDot(),
                SizedBox(width: 10),
                Text('Listening…', style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
          ),
          _circleButton(
            icon: Icons.stop,
            filled: true,
            onTap: () {
              HapticFeedback.mediumImpact();
              provider.stopVoice();
            },
          ),
        ],
      ),
    );
  }

  // Device connect UI moved to `DevicePage`; inline sheet removed.

  Widget _circleButton({
    required IconData icon,
    required bool filled,
    bool enabled = true,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: filled
              ? (enabled ? Colors.white : const Color(0xFF3A3A42))
              : const Color(0xFF1F1F25),
          shape: BoxShape.circle,
          border: filled ? null : Border.all(color: const Color(0xFF35343B)),
        ),
        child: Icon(
          icon,
          size: 22,
          color: filled ? (enabled ? const Color(0xFF15151B) : Colors.grey) : Colors.white,
        ),
      ),
    );
  }
}

enum _AttachChoice { camera, gallery, file }

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isFromUser;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isUser ? const Color(0xFF1F6E63) : const Color(0xFF1F1F25);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: align,
        children: [
          if (message.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                alignment: isUser ? WrapAlignment.end : WrapAlignment.start,
                spacing: 6,
                runSpacing: 6,
                children: message.attachments.map(_attachmentChip).toList(),
              ),
            ),
          if (message.text.isNotEmpty || !message.isComplete)
            Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(18),
              ),
              child: _bubbleContent(),
            ),
        ],
      ),
    );
  }

  Widget _bubbleContent() {
    if (message.text.isEmpty && !message.isComplete) {
      final placeholder = message.isFromUser
          ? '🎤 Listening…'
          : (message.isVoice ? '🔊 Speaking…' : 'Thinking…');
      return Text(
        placeholder,
        style: TextStyle(color: Colors.grey[400], fontStyle: FontStyle.italic),
      );
    }
    return Text(message.text, style: const TextStyle(color: Colors.white, fontSize: 15.5, height: 1.35));
  }

  Widget _attachmentChip(Attachment a) {
    if (a.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(a.file, width: 120, height: 120, fit: BoxFit.cover),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFF23232B), borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            a.type == AttachmentType.audio ? Icons.graphic_eq : Icons.insert_drive_file_outlined,
            color: Colors.white70,
            size: 18,
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(a.name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_c),
      child: Container(
        width: 12,
        height: 12,
        decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
      ),
    );
  }
}

