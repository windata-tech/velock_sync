// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/connection/state/protocol_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(supportedProtocols)
const supportedProtocolsProvider = SupportedProtocolsProvider._();

final class SupportedProtocolsProvider
    extends
        $FunctionalProvider<
          List<ProtocolModel>,
          List<ProtocolModel>,
          List<ProtocolModel>
        >
    with $Provider<List<ProtocolModel>> {
  const SupportedProtocolsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'supportedProtocolsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$supportedProtocolsHash();

  @$internal
  @override
  $ProviderElement<List<ProtocolModel>> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  List<ProtocolModel> create(Ref ref) {
    return supportedProtocols(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<ProtocolModel> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<ProtocolModel>>(value),
    );
  }
}

String _$supportedProtocolsHash() =>
    r'4e48ca9b9955fb02cb9017b548f8e652017c05cc';

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
    r'199e3cf1e2698dd2e4543dde4a6139a959794840';

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
