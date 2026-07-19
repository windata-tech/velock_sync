import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  final companionRoot = Directory(
    arguments.isEmpty ? '../velock_codex' : arguments.single,
  );
  final syncContract = File(
    'test_vectors/velock_exchange_v1/interface_contract.json',
  );
  final companionContract = File(
    '${companionRoot.path}/test_vectors/velock_exchange_v1/interface_contract.json',
  );
  if (!syncContract.existsSync() || !companionContract.existsSync()) {
    stderr.writeln(
      'Both repositories must expose the Velock Exchange V1 contract.',
    );
    exitCode = 2;
    return;
  }
  final syncValue = jsonEncode(jsonDecode(syncContract.readAsStringSync()));
  final companionValue = jsonEncode(
    jsonDecode(companionContract.readAsStringSync()),
  );
  if (syncValue != companionValue) {
    stderr.writeln('Velock Exchange V1 contracts differ across repositories.');
    exitCode = 1;
    return;
  }
  stdout.writeln('Velock Exchange V1 cross-repository contract: PASS');
}
