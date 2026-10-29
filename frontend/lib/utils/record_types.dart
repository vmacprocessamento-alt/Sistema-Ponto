/// Tipos de batida e os nomes que o app mostra para eles.
///
/// Mesma lista de _PUNCH_TYPES no backend (main.py) e dos rotulos da tela
/// de ponto e do historico.
const List<String> punchTypes = [
  'check_in',
  'break_start',
  'break_end',
  'entry_3',
  'exit_3',
  'check_out',
];

String recordTypeLabel(String? type) {
  switch (type) {
    case 'check_in':
      return 'Entrada';
    case 'check_out':
      return 'Saída';
    case 'break_start':
      return 'Pausa 1 (Início)';
    case 'break_end':
      return 'Pausa 1 (Retorno)';
    case 'entry_3':
      return 'Pausa 2 (Início)';
    case 'exit_3':
      return 'Pausa 2 (Retorno)';
    default:
      return (type ?? '').replaceAll('_', ' ');
  }
}
