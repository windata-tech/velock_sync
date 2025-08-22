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
    return WebDavProtocolModel.fromJson(
      json
    );
}

/// @nodoc
mixin _$ProtocolModel {

 WebDavProtocolType get protocolType; String get address; String get port; String? get username; String? get password; String? get path;
/// Create a copy of ProtocolModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProtocolModelCopyWith<ProtocolModel> get copyWith => _$ProtocolModelCopyWithImpl<ProtocolModel>(this as ProtocolModel, _$identity);

  /// Serializes this ProtocolModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProtocolModel&&(identical(other.protocolType, protocolType) || other.protocolType == protocolType)&&(identical(other.address, address) || other.address == address)&&(identical(other.port, port) || other.port == port)&&(identical(other.username, username) || other.username == username)&&(identical(other.password, password) || other.password == password)&&(identical(other.path, path) || other.path == path));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,protocolType,address,port,username,password,path);

@override
String toString() {
  return 'ProtocolModel(protocolType: $protocolType, address: $address, port: $port, username: $username, password: $password, path: $path)';
}


}

/// @nodoc
abstract mixin class $ProtocolModelCopyWith<$Res>  {
  factory $ProtocolModelCopyWith(ProtocolModel value, $Res Function(ProtocolModel) _then) = _$ProtocolModelCopyWithImpl;
@useResult
$Res call({
 WebDavProtocolType protocolType, String address, String port, String? username, String? password, String? path
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
@pragma('vm:prefer-inline') @override $Res call({Object? protocolType = null,Object? address = null,Object? port = null,Object? username = freezed,Object? password = freezed,Object? path = freezed,}) {
  return _then(_self.copyWith(
protocolType: null == protocolType ? _self.protocolType : protocolType // ignore: cast_nullable_to_non_nullable
as WebDavProtocolType,address: null == address ? _self.address : address // ignore: cast_nullable_to_non_nullable
as String,port: null == port ? _self.port : port // ignore: cast_nullable_to_non_nullable
as String,username: freezed == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String?,password: freezed == password ? _self.password : password // ignore: cast_nullable_to_non_nullable
as String?,path: freezed == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String?,
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( WebDavProtocolModel value)?  webDav,required TResult orElse(),}){
final _that = this;
switch (_that) {
case WebDavProtocolModel() when webDav != null:
return webDav(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( WebDavProtocolModel value)  webDav,}){
final _that = this;
switch (_that) {
case WebDavProtocolModel():
return webDav(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( WebDavProtocolModel value)?  webDav,}){
final _that = this;
switch (_that) {
case WebDavProtocolModel() when webDav != null:
return webDav(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( WebDavProtocolType protocolType,  String address,  String port,  String? username,  String? password,  String? path)?  webDav,required TResult orElse(),}) {final _that = this;
switch (_that) {
case WebDavProtocolModel() when webDav != null:
return webDav(_that.protocolType,_that.address,_that.port,_that.username,_that.password,_that.path);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( WebDavProtocolType protocolType,  String address,  String port,  String? username,  String? password,  String? path)  webDav,}) {final _that = this;
switch (_that) {
case WebDavProtocolModel():
return webDav(_that.protocolType,_that.address,_that.port,_that.username,_that.password,_that.path);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( WebDavProtocolType protocolType,  String address,  String port,  String? username,  String? password,  String? path)?  webDav,}) {final _that = this;
switch (_that) {
case WebDavProtocolModel() when webDav != null:
return webDav(_that.protocolType,_that.address,_that.port,_that.username,_that.password,_that.path);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class WebDavProtocolModel implements ProtocolModel {
  const WebDavProtocolModel({required this.protocolType, required this.address, required this.port, this.username, this.password, this.path});
  factory WebDavProtocolModel.fromJson(Map<String, dynamic> json) => _$WebDavProtocolModelFromJson(json);

@override final  WebDavProtocolType protocolType;
@override final  String address;
@override final  String port;
@override final  String? username;
@override final  String? password;
@override final  String? path;

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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is WebDavProtocolModel&&(identical(other.protocolType, protocolType) || other.protocolType == protocolType)&&(identical(other.address, address) || other.address == address)&&(identical(other.port, port) || other.port == port)&&(identical(other.username, username) || other.username == username)&&(identical(other.password, password) || other.password == password)&&(identical(other.path, path) || other.path == path));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,protocolType,address,port,username,password,path);

@override
String toString() {
  return 'ProtocolModel.webDav(protocolType: $protocolType, address: $address, port: $port, username: $username, password: $password, path: $path)';
}


}

/// @nodoc
abstract mixin class $WebDavProtocolModelCopyWith<$Res> implements $ProtocolModelCopyWith<$Res> {
  factory $WebDavProtocolModelCopyWith(WebDavProtocolModel value, $Res Function(WebDavProtocolModel) _then) = _$WebDavProtocolModelCopyWithImpl;
@override @useResult
$Res call({
 WebDavProtocolType protocolType, String address, String port, String? username, String? password, String? path
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
@override @pragma('vm:prefer-inline') $Res call({Object? protocolType = null,Object? address = null,Object? port = null,Object? username = freezed,Object? password = freezed,Object? path = freezed,}) {
  return _then(WebDavProtocolModel(
protocolType: null == protocolType ? _self.protocolType : protocolType // ignore: cast_nullable_to_non_nullable
as WebDavProtocolType,address: null == address ? _self.address : address // ignore: cast_nullable_to_non_nullable
as String,port: null == port ? _self.port : port // ignore: cast_nullable_to_non_nullable
as String,username: freezed == username ? _self.username : username // ignore: cast_nullable_to_non_nullable
as String?,password: freezed == password ? _self.password : password // ignore: cast_nullable_to_non_nullable
as String?,path: freezed == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
