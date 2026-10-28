import 'package:flutter/material.dart';
import '../models/channel_model.dart';
import '../services/user_customization_service.dart';

class RenameChannelDialog extends StatefulWidget {
  final String? channelId;
  final String? currentName;
  final ChannelModel? channel;
  final Function(String newName)? onSave;

  const RenameChannelDialog({
    Key? key,
    this.channelId,
    this.currentName,
    this.channel,
    this.onSave,
  }) : super(key: key);

  @override
  State<RenameChannelDialog> createState() => _RenameChannelDialogState();
}

class _RenameChannelDialogState extends State<RenameChannelDialog> {
  late final TextEditingController _nameController;

  String get _initialName {
    if (widget.currentName != null && widget.currentName!.isNotEmpty) {
      return widget.currentName!;
    }
    if (widget.channel != null) {
      return widget.channel!.displayName.isNotEmpty 
          ? widget.channel!.displayName 
          : widget.channel!.name;
    }
    return '';
  }

  String get _originalName {
    if (widget.channel != null) {
      return widget.channel!.name;
    }
    return widget.currentName ?? '';
  }

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: _initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final newName = _nameController.text.trim();
    if (newName.isNotEmpty) {
      if (widget.channelId != null && widget.channelId!.isNotEmpty) {
        await UserCustomizationService.setChannelAlias(widget.channelId!, newName);
      }
      if (widget.onSave != null) {
        widget.onSave!(newName);
      }
      if (mounted) {
        Navigator.pop(context, newName);
      }
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0D1324),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF7C2CBF).withOpacity(0.2),
                border: Border.all(color: const Color(0xFF7C2CBF)),
              ),
              child: const Icon(Icons.edit_rounded, color: Color(0xFF00E5FF), size: 36),
            ),
            const SizedBox(height: 16),
            const Text(
              'Renombrar Canal',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (_originalName.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Original: $_originalName',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
            const SizedBox(height: 20),
            TextField(
              controller: _nameController,
              autofocus: true,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              decoration: InputDecoration(
                hintText: 'Nuevo nombre del canal',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF070A10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Color(0xFF7C2CBF)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: const Color(0xFF7C2CBF).withOpacity(0.5)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Color(0xFF00E5FF), width: 2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar', style: TextStyle(color: Colors.white60)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _handleSave,
                    child: const Text('Guardar', style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}