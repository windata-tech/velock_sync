// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/connection/state/protocol_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(protocolConnectChecker)
const protocolConnectCheckerProvider = ProtocolConnectCheckerFamily._();

final class ProtocolConnectCheckerProvider
    extends $FunctionalProvider<AsyncValue<bool>, bool, FutureOr<bool>>
    with $FutureModifier<bool>, $FutureProvider<bool> {
  const ProtocolConnectCheckerProvider._({
    required ProtocolConnectCheckerFamily super.from,
    required ProtocolModel super.argument,
  }) : super(
         retry: null,
         name: r'protocolConnectCheckerProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$protocolConnectCheckerHash();

  @override
  String toString() {
    return r'protocolConnectCheckerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<bool> create(Ref ref) {
    final argument = this.argument as ProtocolModel;
    return protocolConnectChecker(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is ProtocolConnectCheckerProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$protocolConnectCheckerHash() =>
    r'ca8ebed9921214dc727cd0d9dfab8c9a7ce32318';

final class ProtocolConnectCheckerFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<bool>, ProtocolModel> {
  const ProtocolConnectCheckerFamily._()
    : super(
        retry: null,
        name: r'protocolConnectCheckerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  ProtocolConnectCheckerProvider call(ProtocolModel protocol) =>
      ProtocolConnectCheckerProvider._(argument: protocol, from: this);

  @override
  String toString() => r'protocolConnectCheckerProvider';
}
