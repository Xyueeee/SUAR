import 'package:flutter/material.dart';

/// Shows a rounded-box text-entry dialog that validates inline — on an
/// invalid value the field's box turns pastel red and a small error message
/// appears in a reserved slot below it, instead of popping the dialog and
/// showing a SnackBar after the fact.
///
/// Returns the confirmed, trimmed value, or null if cancelled.
Future<String?> showValidatedTextDialog({
  required BuildContext context,
  required String title,
  required String confirmLabel,
  required Future<String?> Function(String value) validate,
  String initialValue = '',
  String hintText = '',
  bool allowEmpty = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ValidatedTextDialog(
      title: title,
      confirmLabel: confirmLabel,
      validate: validate,
      initialValue: initialValue,
      hintText: hintText,
      allowEmpty: allowEmpty,
    ),
  );
}

class _ValidatedTextDialog extends StatefulWidget {
  const _ValidatedTextDialog({
    required this.title,
    required this.confirmLabel,
    required this.validate,
    required this.initialValue,
    required this.hintText,
    required this.allowEmpty,
  });

  final String title;
  final String confirmLabel;
  final Future<String?> Function(String value) validate;
  final String initialValue;
  final String hintText;
  final bool allowEmpty;

  @override
  State<_ValidatedTextDialog> createState() => _ValidatedTextDialogState();
}

class _ValidatedTextDialogState extends State<_ValidatedTextDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      if (!widget.allowEmpty) {
        setState(() => _error = 'This field cannot be empty.');
        return;
      }
      Navigator.of(context).pop(value);
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final error = await widget.validate(value);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _checking = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop(value);
  }

  static const _grey = Color(0xFFF0F0F0);
  static const _pastelRedBorder = Color(0xFFE39999);

  @override
  Widget build(BuildContext context) {
    final hasError = _error != null;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _confirm(),
            decoration: InputDecoration(
              hintText: widget.hintText,
              filled: true,
              fillColor: _grey,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: hasError ? _pastelRedBorder : Colors.transparent,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: hasError ? _pastelRedBorder : Colors.transparent,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: hasError ? _pastelRedBorder : const Color(0xFFA7C7E7),
                  width: 1.5,
                ),
              ),
            ),
          ),
          // Reserved slot — always present so the dialog doesn't resize/jump
          // when an error appears.
          SizedBox(
            height: 22,
            child: hasError
                ? Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFC65B5B),
                        fontSize: 12,
                      ),
                    ),
                  )
                : null,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _checking ? null : _confirm,
          child: _checking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
