import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

class SelectedPdfFile {
  const SelectedPdfFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

web.HTMLInputElement _pdfInput() => web.HTMLInputElement()
  ..type = 'file'
  ..accept = '.pdf,application/pdf'
  ..multiple = false;

Future<SelectedPdfFile> _read(web.File file) async {
  final buffer = await file.arrayBuffer().toDart;
  return SelectedPdfFile(name: file.name, bytes: buffer.toDart.asUint8List());
}

Future<SelectedPdfFile?> pickPdfFromBrowser() {
  final input = _pdfInput()..style.display = 'none';
  web.document.body?.append(input);

  final completer = Completer<SelectedPdfFile?>();
  input.onChange.first.then((_) async {
    final file = input.files?.item(0);
    input.remove();
    if (file == null) {
      completer.complete(null);
      return;
    }
    try {
      completer.complete(await _read(file));
    } catch (_) {
      completer.completeError(StateError('Nao foi possivel ler o PDF.'));
    }
  });

  input.click();
  return completer.future;
}

class WebPdfInput extends StatefulWidget {
  const WebPdfInput({super.key, required this.onSelected, required this.onError});

  final ValueChanged<SelectedPdfFile> onSelected;
  final ValueChanged<Object> onError;

  @override
  State<WebPdfInput> createState() => _WebPdfInputState();
}

class _WebPdfInputState extends State<WebPdfInput> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'ponto-pdf-input-${identityHashCode(this)}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) {
      final input = _pdfInput();
      input.style
        ..width = '100%'
        ..height = '42px'
        ..padding = '8px 12px'
        ..boxSizing = 'border-box'
        ..border = '1px solid #a80000'
        ..borderRadius = '22px'
        ..color = '#a80000'
        ..backgroundColor = 'transparent';

      input.onChange.listen((_) async {
        final file = input.files?.item(0);
        if (file == null) return;
        try {
          widget.onSelected(await _read(file));
        } catch (_) {
          widget.onError(StateError('Nao foi possivel ler o PDF.'));
        }
      });
      return input;
    });
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
