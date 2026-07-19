// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../../../features/connection/model/protocol_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
ProtocolModel _$ProtocolModelFromJson(
  Map<String, dynamic> json
) {
        switch (json['runtimeType']) {
                  case 'webDav':
          return WebDavProtocolModel.fromJson(
            json
          );
                case 'oauth':
          return OAuthProtocolModel.fromJson(
            json
          );

          default:
            throw CheckedFromJsonException(
  json,
  'runtimeType',
  'ProtocolModel',
  'Invalid union type "${json['runtimeType']}"!'
);
        }

}

/// @nodoc
mixin _$ProtocolModel {

@JsonKey(name: 'credentialRef') String? get credentialRef;
/// Create a copy of ProtocolModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProtocolModelCopyWith<ProtocolModel> get copyWith => _$ProtocolModelCopyWithImpl<ProtocolModel>(this as ProtocolModel, _$identity);

  /// Serializes this ProtocolModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProtocolModel&&(identical(other.credentialRef, credentialRef) || other.credentialRef == credentialRef));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,credentialRef);

@override
String toString() {
  return 'ProtocolModel(credentialRef: $credentialRef)';
}


}

/// @nodoc
abstract mixin class $ProtocolModelCopyWith<$Res>  {
  factory $ProtocolModelCopyWith(ProtocolModel value, $Res Function(ProtocolModel) _then) = _$ProtocolModelCopyWithImpl;
@useResult
$Res call({
@JsonKey(name: 'credentialRef') String credentialRef
});




}
/// @nodoc
class _$ProtocolModelCopyWithImpl<$Res>
    implements $ProtocolModelCopyWith<$Res> {
  _$ProtocolModelCopyWithImpl(this._self, this._then);

  final ProtocolModel _self;
  final $Res Function(ProtocolModel) _then;

/// Create a copy of ProtocolModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? credentialRef = null,}) {
  return _then(_self.copyWith(
credentialRef: null == credentialRef ? _self.credentialRef! : credentialRef // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [ProtocolModel].
extension ProtocolModelPatterns on ProtocolModel {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( WebDavProtocolModel value)?  webDav,TResult Function( OAuthProtocolModel value)?  oauth,required TResult orElse(),}){
final _that = this;
switch (_that) {
case WebDavProtocolModel() when webDav != null:
return webDav(_that);case OAuthProtocolModel() when oauth != null:
return oauth(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( WebDavProtocolModel value)  webDav,required TResult Function( OAuthProtocolModel value)  oauth,}){
final _that = this;
switch (_that) {
case WebDavProtocolModel():
return webDav(_that);case OAuthProtocolModel():
return oauth(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( WebDavProtocolModel value)?  webDav,TResult? Function( OAuthProtocolModel value)?  oauth,}){
final _that = this;
switch (_that) {
case WebDavProtocolModel() when webDav != null:
return webDav(_that);case OAuthProtocolModel() when oauth != null:
return oauth(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function(@JsonKey(name: 'protocolType')  WebDavProtocolType protocolType,  String address,  String port,  String? username, @JsonKey(name: 'credentialRef')  String? credentialRef,  String? path)?  webDav,TResult Function(@JsonKey(name: 'providerType')  RemoteProviderType providerType, @JsonKey(name: 'clientId')  String clientId, @JsonKey(name: 'credentialRef')  String credentialRef, @JsonKey(name: 'rootId')  String rootId, @JsonKey(name: 'accountLabel')  String? accountLabel)?  oauth,required TResult orElse(),}) {final _that = this;
switch (_that) {
case WebDavProtocolModel() when webDav != null:
return webDav(_that.protocolType,_that.address,_that.port,_that.username,_that.credentialRef,_that.path);case OAuthProtocolModel() when oauth != null:
return oauth(_that.providerType,_that.clientId,_that.credentialRef,_that.rootId,_that.accountLabel);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function(@JsonKey(name: 'protocolType')  WebDavProtocolType protocolType,  String address,  String port,  String? username, @JsonKey(name: 'credentialRef')  String? credentialRef,  String? path)  webDav,required TResult Function(@JsonKey(name: 'providerType')  RemoteProviderType providerType, @JsonKey(name: 'clientId')  String clientId, @JsonKey(name: 'credentialRef')  String credentialRef, @JsonKey(name: 'rootId')  String rootId, @JsonKey(name: 'accountLabel')  String? accountLabel)  oauth,}) {final _that = this;
switch (_that) {
case WebDavProtocolModel():
return webDav(_that.protocolType,_that.address,_that.port,_that.username,_that.credentialRef,_that.path);case OAuthProtocolModel():
return oauth(_that.providerType,_that.clientId,_that.credentialRef,_that.rootId,_that.accountLabel);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function(@JsonKey(name: 'protocolType')  WebDavProtocolType protocolType,  String address,  String port,  String? username, @JsonKey(name: 'credentialRef')  String? credentialRef,  String? path)?  webDav,TResult? Function(@JsonKey(name: 'providerType')  RemoteProviderType providerType, @JsonKey(name: 'clientId')  String clientId, @JsonKey(name: 'credentialRef')  String credentialRef, @JsonKey(name: 'rootId')  String rootId, @JsonKey(name: 'accountLabel')  String? accountLabel)?  oauth,}) {final _that = this;
switch (_that) {
case WebDavProtocolModel() when webDav != null:
return webDav(_that.protocolType,_that.address,_that.port,_that.username,_that.credentialRef,_that.path);case OAuthProtocolModel() when oauth != null:
return oauth(_that.providerType,_that.clientId,_that.credentialRef,_that.rootId,_that.accountLabel);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class WebDavProtocolModel implements ProtocolModel {
  const WebDavProtocolModel({@JsonKey(name: 'protocolType') required this.protocolType, required this.address, required this.port, this.username, @JsonKey(name: 'credentialRef') this.credentialRef, this.path, final  String? $type}): $type = $type ?? 'webDav';
  factory WebDavProtocolModel.fromJson(Map<String, dynamic> json) => _$WebDavProtocolModelFromJson(json);

@JsonKey(name: 'protocolType') final  WebDavProtocolType protocolType;
 final  String address;
 final  String port;
 final  String? username;
@override@JsonKey(name: 'credentialRef') final  String? credentialRef;
 final  String? path;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ProtocolModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$WebDavProtocolModelCopyWith<WebDavProtocolModel> get copyWith => _$WebDavProtocolModelCopyWithImpl<WebDavProtocolModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$WebDavProtocolModelToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WebDavProtocolModel&&(identical(other.protocolType, protocolType) || other.protocolType == protocolType)&&(identical(other.address, address) || other.address == address)&&(identical(other.port, port) || other.port == port)&&(identical(other.username, username) || other.username == username)&&(identical(other.credentialRef, credentialRef) || other.credentialRef == credentialRef)&&(identical(other.path, path) || other.path == path));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,protocolType,address,port,username,credentialRef,path);

@override
String toString() {
  return 'ProtocolModel.webDav(protocolType: $protocolType, address: $address, port: $port, username: $username, credentialRef: $credentialRef, path: $path)';
}


}

/// @nodoc
abstract mixin class $WebDavProtocolModelCopyWith<$Res> implements $ProtocolModelCopyWith<$Res> {
  factory $WebDavProtocolModelCopyWith(WebDavProtocolModel value, $Res Function(WebDavProtocolModel) _then) = _$WebDavProtocolModelCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'protocolType') WebDavProtocolType protocolType, String address, String port, String? username,@JsonKey(name: 'credentialRef') String? credentialRef, String? path
});




}
/// @nodoc
class _$WebDavProtocolModelCopyWithImpl<$Res>
    implements $WebDavProtocolModelCopyWith<$Res> {
  _$WebDavProtocolModelCopyWithImpl(this._self, this._then);

  final WebDavProtocolModel _self;
  final $Res Function(WebDavProtocolModel) _then;

/// Create a copy of ProtocolModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? protocolType = null,Object? address = null,Object? port = null,Object? username = freezed,Object? credentialRef = freezed,Object? path = freezed,}) {
  return _then(WebDavProtocolModel(
protocolType: null == protocolType ? _self.protocolType : protocolType // ignore: cast_nullable_to_non_nullable
as WebDavProtocolType,address: null == address ? _self.address : address // ignore: cast_nullable_to_non_nullable
as String,port: null == port ? _self.port : port // ignore: cast_nullable_to_non_nullable
as String,username: freezed == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String?,credentialRef: freezed == credentialRef ? _self.credentialRef : credentialRef // ignore: cast_nullable_to_non_nullable
as String?,path: freezed == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc
@JsonSerializable()

class OAuthProtocolModel implements ProtocolModel {
  const OAuthProtocolModel({@JsonKey(name: 'providerType') required this.providerType, @JsonKey(name: 'clientId') required this.clientId, @JsonKey(name: 'credentialRef') required this.credentialRef, @JsonKey(name: 'rootId') required this.rootId, @JsonKey(name: 'accountLabel') this.accountLabel, final  String? $type}): $type = $type ?? 'oauth';
  factory OAuthProtocolModel.fromJson(Map<String, dynamic> json) => _$OAuthProtocolModelFromJson(json);

@JsonKey(name: 'providerType') final  RemoteProviderType providerType;
@JsonKey(name: 'clientId') final  String clientId;
@override@JsonKey(name: 'credentialRef') final  String credentialRef;
@JsonKey(name: 'rootId') final  String rootId;
@JsonKey(name: 'accountLabel') final  String? accountLabel;

@JsonKey(name: 'runtimeType')
final String $type;


/// Create a copy of ProtocolModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$OAuthProtocolModelCopyWith<OAuthProtocolModel> get copyWith => _$OAuthProtocolModelCopyWithImpl<OAuthProtocolModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$OAuthProtocolModelToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is OAuthProtocolModel&&(identical(other.providerType, providerType) || other.providerType == providerType)&&(identical(other.clientId, clientId) || other.clientId == clientId)&&(identical(other.credentialRef, credentialRef) || other.credentialRef == credentialRef)&&(identical(other.rootId, rootId) || other.rootId == rootId)&&(identical(other.accountLabel, accountLabel) || other.accountLabel == accountLabel));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,providerType,clientId,credentialRef,rootId,accountLabel);

@override
String toString() {
  return 'ProtocolModel.oauth(providerType: $providerType, clientId: $clientId, credentialRef: $credentialRef, rootId: $rootId, accountLabel: $accountLabel)';
}


}

/// @nodoc
abstract mixin class $OAuthProtocolModelCopyWith<$Res> implements $ProtocolModelCopyWith<$Res> {
  factory $OAuthProtocolModelCopyWith(OAuthProtocolModel value, $Res Function(OAuthProtocolModel) _then) = _$OAuthProtocolModelCopyWithImpl;
@override @useResult
$Res call({
@JsonKey(name: 'providerType') RemoteProviderType providerType,@JsonKey(name: 'clientId') String clientId,@JsonKey(name: 'credentialRef') String credentialRef,@JsonKey(name: 'rootId') String rootId,@JsonKey(name: 'accountLabel') String? accountLabel
});




}
/// @nodoc
class _$OAuthProtocolModelCopyWithImpl<$Res>
    implements $OAuthProtocolModelCopyWith<$Res> {
  _$OAuthProtocolModelCopyWithImpl(this._self, this._then);

  final OAuthProtocolModel _self;
  final $Res Function(OAuthProtocolModel) _then;

/// Create a copy of ProtocolModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? providerType = null,Object? clientId = null,Object? credentialRef = null,Object? rootId = null,Object? accountLabel = freezed,}) {
  return _then(OAuthProtocolModel(
providerType: null == providerType ? _self.providerType : providerType // ignore: cast_nullable_to_non_nullable
as RemoteProviderType,clientId: null == clientId ? _self.clientId : clientId // ignore: cast_nullable_to_non_nullable
as String,credentialRef: null == credentialRef ? _self.credentialRef : credentialRef // ignore: cast_nullable_to_non_nullable
as String,rootId: null == rootId ? _self.rootId : rootId // ignore: cast_nullable_to_non_nullable
as String,accountLabel: freezed == accountLabel ? _self.accountLabel : accountLabel // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
