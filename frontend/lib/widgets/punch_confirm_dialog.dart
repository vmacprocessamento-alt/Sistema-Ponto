import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// CONFIRMACAO DA BATIDA (04/11/2026). Um toque sem querer no botao (celular
/// no bolso, dedo que escorrega ao abrir o app) abria turno ou pausa, e so o
/// gestor conseguia desfazer. Agora toda batida pede um segundo toque, com o
/// tipo e a hora bem visiveis. True = confirmou.
///
/// [warning]: aviso extra em destaque (ex.: ja encerrou um turno hoje).
Future<bool> confirmPunch(
  BuildContext context, {
  required String label,
  required DateTime at,
  String? warning,
}) async {
  const wine = Color(0xFF8B0000);
  String day;
  try {
    day = DateFormat("EEEE, d 'de' MMMM", 'pt_BR').format(at);
  } catch (_) {
    // Sem os dados de data em portugues carregados (testes).
    day = DateFormat('dd/MM/yyyy').format(at);
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Registrar $label?', textAlign: TextAlign.center),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            DateFormat('HH:mm').format(at),
            style: const TextStyle(
                fontSize: 44, fontWeight: FontWeight.bold, color: wine),
          ),
          Text(day, style: const TextStyle(color: Colors.grey)),
          if (warning != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(child: Text(warning)),
                ],
              ),
            ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(backgroundColor: wine),
          child: Text('Confirmar $label',
              style: const TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  return ok == true;
}
