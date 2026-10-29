import 'package:flutter/material.dart';

import '../services/update_service.dart';

/// Barra "Nova versao do app" no topo de qualquer tela. So aparece quando a
/// atualizacao ja foi baixada mas a pessoa esta usando a tela ha um tempo
/// (UpdateService); no caso comum o app recarrega sozinho antes disso.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.child});

  final Widget child;

  static const Color wineColor = Color(0xFF8B0000);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: UpdateService.instance.showBanner,
      child: child,
      builder: (context, show, app) => Stack(
        children: [
          app!,
          if (show)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Material(
                    color: wineColor,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: UpdateService.instance.applyNow,
                      child: const Padding(
                        padding: EdgeInsets.fromLTRB(16, 10, 8, 10),
                        child: Row(
                          children: [
                            Icon(Icons.system_update, color: Colors.white),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Nova versão do app disponível.',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: Text(
                                'ATUALIZAR',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
