import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Largura de leitura das telas. No celular a tela inteira e usada como
/// sempre; no computador o conteudo fica no centro, sem esticar ate as
/// bordas da janela.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = narrow});

  /// Telas de uma coluna: ponto, dash, historico, perfil, chat.
  static const double narrow = 760;

  /// Telas de gestao, com listas e tabelas mais largas.
  static const double wide = 1200;

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth <= maxWidth) return child;
        // Fora da coluna, o fundo do app: a tela aberta por cima e opaca e nao
        // deixa ver a de baixo.
        return ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Center(
            child: SizedBox(
              width: math.min(box.maxWidth, maxWidth),
              height: box.maxHeight.isFinite ? box.maxHeight : null,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
