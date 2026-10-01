// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../../../features/connection/model/connection_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$CreateConnectionDto {

 String get name; String? get description; String? get source; String? get sourceDescription; String? get target; String? get targetDescription; ProtocolModel? get protocol;
/// Create a copy of CreateConnectionDto
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CreateConnectionDtoCopyWith<CreateConnectionDto> get copyWith => _$CreateConnectionDtoCopyWithImpl<CreateConnectionDto>(this as CreateConnectionDto, _$identity);

  /// Serializes this CreateConnectionDto to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CreateConnectionDto&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.source, source) || other.source == source)&&(identical(other.sourceDescription, sourceDescription) || other.sourceDescription == sourceDescription)&&(identical(other.target, target) || other.target == target)&&(identical(other.targetDescription, targetDescription) || other.targetDescription == targetDescription)&&(identical(other.protocol, protocol) || other.protocol == protocol));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,description,source,sourceDescription,target,targetDescription,protocol);

@override
String toString() {
  return 'CreateConnectionDto(name: $name, description: $description, source: $source, sourceDescription: $sourceDescription, target: $target, targetDescription: $targetDescription, protocol: $protocol)';
}


}

/// @nodoc
abstract mixin class $CreateConnectionDtoCopyWith<$Res>  {
  factory $CreateConnectionDtoCopyWith(CreateConnectionDto value, $Res Function(CreateConnectionDto) _then) = _$CreateConnectionDtoCopyWithImpl;
@useResult
$Res call({
 String name, String? description, String? source, String? sourceDescription, String? target, String? targetDescription, ProtocolModel? protocol
});


$ProtocolModelCopyWith<$Res>? get protocol;

}
/// @nodoc
class _$CreateConnectionDtoCopyWithImpl<$Res>
    implements $CreateConnectionDtoCopyWith<$Res> {
  _$CreateConnectionDtoCopyWithImpl(this._self, this._then);

  final CreateConnectionDto _self;
  final $Res Function(CreateConnectionDto) _then;

/// Create a copy of CreateConnectionDto
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? name = null,Object? description = freezed,Object? source = freezed,Object? sourceDescription = freezed,Object? target = freezed,Object? targetDescription = freezed,Object? protocol = freezed,}) {
  return _then(_self.copyWith(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,source: freezed == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String?,sourceDescription: freezed == sourceDescription ? _self.sourceDescription : sourceDescription // ignore: cast_nullable_to_non_nullable
as String?,target: freezed == target ? _self.target : target // ignore: cast_nullable_to_non_nullable
as String?,targetDescription: freezed == targetDescription ? _self.targetDescription : targetDescription // ignore: cast_nullable_to_non_nullable
as String?,protocol: freezed == protocol ? _self.protocol : protocol // ignore: cast_nullable_to_non_nullable
as ProtocolModel?,
  ));
}
/// Create a copy of CreateConnectionDto
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProtocolModelCopyWith<$Res>? get protocol {
    if (_self.protocol == null) {
    return null;
  }

  return $ProtocolModelCopyWith<$Res>(_self.protocol!, (value) {
    return _then(_self.copyWith(protocol: value));
  });
}
}


/// Adds pattern-matching-related methods to [CreateConnectionDto].
extension CreateConnectionDtoPatterns on CreateConnectionDto {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CreateConnectionDto value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CreateConnectionDto() when $default != null:
return $default(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CreateConnectionDto value)  $default,){
final _that = this;
switch (_that) {
case _CreateConnectionDto():
return $default(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CreateConnectionDto value)?  $default,){
final _that = this;
switch (_that) {
case _CreateConnectionDto() when $default != null:
return $default(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String name,  String? description,  String? source,  String? sourceDescription,  String? target,  String? targetDescription,  ProtocolModel? protocol)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CreateConnectionDto() when $default != null:
return $default(_that.name,_that.description,_that.source,_that.sourceDescription,_that.target,_that.targetDescription,_that.protocol);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String name,  String? description,  String? source,  String? sourceDescription,  String? target,  String? targetDescription,  ProtocolModel? protocol)  $default,) {final _that = this;
switch (_that) {
case _CreateConnectionDto():
return $default(_that.name,_that.description,_that.source,_that.sourceDescription,_that.target,_that.targetDescription,_that.protocol);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String name,  String? description,  String? source,  String? sourceDescription,  String? target,  String? targetDescription,  ProtocolModel? protocol)?  $default,) {final _that = this;
switch (_that) {
case _CreateConnectionDto() when $default != null:
return $default(_that.name,_that.description,_that.source,_that.sourceDescription,_that.target,_that.targetDescription,_that.protocol);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _CreateConnectionDto implements CreateConnectionDto {
   _CreateConnectionDto({required this.name, this.description, required this.source, this.sourceDescription, required this.target, this.targetDescription, required this.protocol});
  factory _CreateConnectionDto.fromJson(Map<String, dynamic> json) => _$CreateConnectionDtoFromJson(json);

@override final  String name;
@override final  String? description;
@override final  String? source;
@override final  String? sourceDescription;
@override final  String? target;
@override final  String? targetDescription;
@override final  ProtocolModel? protocol;

/// Create a copy of CreateConnectionDto
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CreateConnectionDtoCopyWith<_CreateConnectionDto> get copyWith => __$CreateConnectionDtoCopyWithImpl<_CreateConnectionDto>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CreateConnectionDtoToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CreateConnectionDto&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.source, source) || other.source == source)&&(identical(other.sourceDescription, sourceDescription) || other.sourceDescription == sourceDescription)&&(identical(other.target, target) || other.target == target)&&(identical(other.targetDescription, targetDescription) || other.targetDescription == targetDescription)&&(identical(other.protocol, protocol) || other.protocol == protocol));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,name,description,source,sourceDescription,target,targetDescription,protocol);

@override
String toString() {
  return 'CreateConnectionDto(name: $name, description: $description, source: $source, sourceDescription: $sourceDescription, target: $target, targetDescription: $targetDescription, protocol: $protocol)';
}


}

/// @nodoc
abstract mixin class _$CreateConnectionDtoCopyWith<$Res> implements $CreateConnectionDtoCopyWith<$Res> {
  factory _$CreateConnectionDtoCopyWith(_CreateConnectionDto value, $Res Function(_CreateConnectionDto) _then) = __$CreateConnectionDtoCopyWithImpl;
@override @useResult
$Res call({
 String name, String? description, String? source, String? sourceDescription, String? target, String? targetDescription, ProtocolModel? protocol
});


@override $ProtocolModelCopyWith<$Res>? get protocol;

}
/// @nodoc
class __$CreateConnectionDtoCopyWithImpl<$Res>
    implements _$CreateConnectionDtoCopyWith<$Res> {
  __$CreateConnectionDtoCopyWithImpl(this._self, this._then);

  final _CreateConnectionDto _self;
  final $Res Function(_CreateConnectionDto) _then;

/// Create a copy of CreateConnectionDto
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? name = null,Object? description = freezed,Object? source = freezed,Object? sourceDescription = freezed,Object? target = freezed,Object? targetDescription = freezed,Object? protocol = freezed,}) {
  return _then(_CreateConnectionDto(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,source: freezed == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String?,sourceDescription: freezed == sourceDescription ? _self.sourceDescription : sourceDescription // ignore: cast_nullable_to_non_nullable
as String?,target: freezed == target ? _self.target : target // ignore: cast_nullable_to_non_nullable
as String?,targetDescription: freezed == targetDescription ? _self.targetDescription : targetDescription // ignore: cast_nullable_to_non_nullable
as String?,protocol: freezed == protocol ? _self.protocol : protocol // ignore: cast_nullable_to_non_nullable
as ProtocolModel?,
  ));
}

/// Create a copy of CreateConnectionDto
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProtocolModelCopyWith<$Res>? get protocol {
    if (_self.protocol == null) {
    return null;
  }

  return $ProtocolModelCopyWith<$Res>(_self.protocol!, (value) {
    return _then(_self.copyWith(protocol: value));
  });
}
}


/// @nodoc
mixin _$ConnectionModel {

 String get id; String get name; String? get description; String get source; String? get sourceDescription; String get target; String? get targetDescription; ProtocolModel get protocol;@TimestampParser() DateTime get createdAt;@TimestampParser() DateTime get updatedAt; ConnectionStatus get status;
/// Create a copy of ConnectionModel
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ConnectionModelCopyWith<ConnectionModel> get copyWith => _$ConnectionModelCopyWithImpl<ConnectionModel>(this as ConnectionModel, _$identity);

  /// Serializes this ConnectionModel to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.source, source) || other.source == source)&&(identical(other.sourceDescription, sourceDescription) || other.sourceDescription == sourceDescription)&&(identical(other.target, target) || other.target == target)&&(identical(other.targetDescription, targetDescription) || other.targetDescription == targetDescription)&&(identical(other.protocol, protocol) || other.protocol == protocol)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.status, status) || other.status == status));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,description,source,sourceDescription,target,targetDescription,protocol,createdAt,updatedAt,status);

@override
String toString() {
  return 'ConnectionModel(id: $id, name: $name, description: $description, source: $source, sourceDescription: $sourceDescription, target: $target, targetDescription: $targetDescription, protocol: $protocol, createdAt: $createdAt, updatedAt: $updatedAt, status: $status)';
}


}

/// @nodoc
abstract mixin class $ConnectionModelCopyWith<$Res>  {
  factory $ConnectionModelCopyWith(ConnectionModel value, $Res Function(ConnectionModel) _then) = _$ConnectionModelCopyWithImpl;
@useResult
$Res call({
 String id, String name, String? description, String source, String? sourceDescription, String target, String? targetDescription, ProtocolModel protocol,@TimestampParser() DateTime createdAt,@TimestampParser() DateTime updatedAt, ConnectionStatus status
});


$ProtocolModelCopyWith<$Res> get protocol;

}
/// @nodoc
class _$ConnectionModelCopyWithImpl<$Res>
    implements $ConnectionModelCopyWith<$Res> {
  _$ConnectionModelCopyWithImpl(this._self, this._then);

  final ConnectionModel _self;
  final $Res Function(ConnectionModel) _then;

/// Create a copy of ConnectionModel
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? description = freezed,Object? source = null,Object? sourceDescription = freezed,Object? target = null,Object? targetDescription = freezed,Object? protocol = null,Object? createdAt = null,Object? updatedAt = null,Object? status = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,sourceDescription: freezed == sourceDescription ? _self.sourceDescription : sourceDescription // ignore: cast_nullable_to_non_nullable
as String?,target: null == target ? _self.target : target // ignore: cast_nullable_to_non_nullable
as String,targetDescription: freezed == targetDescription ? _self.targetDescription : targetDescription // ignore: cast_nullable_to_non_nullable
as String?,protocol: null == protocol ? _self.protocol : protocol // ignore: cast_nullable_to_non_nullable
as ProtocolModel,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ConnectionStatus,
  ));
}
/// Create a copy of ConnectionModel
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProtocolModelCopyWith<$Res> get protocol {
  
  return $ProtocolModelCopyWith<$Res>(_self.protocol, (value) {
    return _then(_self.copyWith(protocol: value));
  });
}
}


/// Adds pattern-matching-related methods to [ConnectionModel].
extension ConnectionModelPatterns on ConnectionModel {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ConnectionModel value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ConnectionModel() when $default != null:
return $default(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ConnectionModel value)  $default,){
final _that = this;
switch (_that) {
case _ConnectionModel():
return $default(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ConnectionModel value)?  $default,){
final _that = this;
switch (_that) {
case _ConnectionModel() when $default != null:
return $default(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String? description,  String source,  String? sourceDescription,  String target,  String? targetDescription,  ProtocolModel protocol, @TimestampParser()  DateTime createdAt, @TimestampParser()  DateTime updatedAt,  ConnectionStatus status)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ConnectionModel() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.source,_that.sourceDescription,_that.target,_that.targetDescription,_that.protocol,_that.createdAt,_that.updatedAt,_that.status);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String? description,  String source,  String? sourceDescription,  String target,  String? targetDescription,  ProtocolModel protocol, @TimestampParser()  DateTime createdAt, @TimestampParser()  DateTime updatedAt,  ConnectionStatus status)  $default,) {final _that = this;
switch (_that) {
case _ConnectionModel():
return $default(_that.id,_that.name,_that.description,_that.source,_that.sourceDescription,_that.target,_that.targetDescription,_that.protocol,_that.createdAt,_that.updatedAt,_that.status);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String? description,  String source,  String? sourceDescription,  String target,  String? targetDescription,  ProtocolModel protocol, @TimestampParser()  DateTime createdAt, @TimestampParser()  DateTime updatedAt,  ConnectionStatus status)?  $default,) {final _that = this;
switch (_that) {
case _ConnectionModel() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.source,_that.sourceDescription,_that.target,_that.targetDescription,_that.protocol,_that.createdAt,_that.updatedAt,_that.status);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _ConnectionModel implements ConnectionModel {
   _ConnectionModel({required this.id, required this.name, this.description, required this.source, this.sourceDescription, required this.target, this.targetDescription, required this.protocol, @TimestampParser() required this.createdAt, @TimestampParser() required this.updatedAt, required this.status});
  factory _ConnectionModel.fromJson(Map<String, dynamic> json) => _$ConnectionModelFromJson(json);

@override final  String id;
@override final  String name;
@override final  String? description;
@override final  String source;
@override final  String? sourceDescription;
@override final  String target;
@override final  String? targetDescription;
@override final  ProtocolModel protocol;
@override@TimestampParser() final  DateTime createdAt;
@override@TimestampParser() final  DateTime updatedAt;
@override final  ConnectionStatus status;

/// Create a copy of ConnectionModel
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ConnectionModelCopyWith<_ConnectionModel> get copyWith => __$ConnectionModelCopyWithImpl<_ConnectionModel>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$ConnectionModelToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ConnectionModel&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.source, source) || other.source == source)&&(identical(other.sourceDescription, sourceDescription) || other.sourceDescription == sourceDescription)&&(identical(other.target, target) || other.target == target)&&(identical(other.targetDescription, targetDescription) || other.targetDescription == targetDescription)&&(identical(other.protocol, protocol) || other.protocol == protocol)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.status, status) || other.status == status));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,description,source,sourceDescription,target,targetDescription,protocol,createdAt,updatedAt,status);

@override
String toString() {
  return 'ConnectionModel(id: $id, name: $name, description: $description, source: $source, sourceDescription: $sourceDescription, target: $target, targetDescription: $targetDescription, protocol: $protocol, createdAt: $createdAt, updatedAt: $updatedAt, status: $status)';
}


}

/// @nodoc
abstract mixin class _$ConnectionModelCopyWith<$Res> implements $ConnectionModelCopyWith<$Res> {
  factory _$ConnectionModelCopyWith(_ConnectionModel value, $Res Function(_ConnectionModel) _then) = __$ConnectionModelCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String? description, String source, String? sourceDescription, String target, String? targetDescription, ProtocolModel protocol,@TimestampParser() DateTime createdAt,@TimestampParser() DateTime updatedAt, ConnectionStatus status
});


@override $ProtocolModelCopyWith<$Res> get protocol;

}
/// @nodoc
class __$ConnectionModelCopyWithImpl<$Res>
    implements _$ConnectionModelCopyWith<$Res> {
  __$ConnectionModelCopyWithImpl(this._self, this._then);

  final _ConnectionModel _self;
  final $Res Function(_ConnectionModel) _then;

/// Create a copy of ConnectionModel
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? description = freezed,Object? source = null,Object? sourceDescription = freezed,Object? target = null,Object? targetDescription = freezed,Object? protocol = null,Object? createdAt = null,Object? updatedAt = null,Object? status = null,}) {
  return _then(_ConnectionModel(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,sourceDescription: freezed == sourceDescription ? _self.sourceDescription : sourceDescription // ignore: cast_nullable_to_non_nullable
as String?,target: null == target ? _self.target : target // ignore: cast_nullable_to_non_nullable
as String,targetDescription: freezed == targetDescription ? _self.targetDescription : targetDescription // ignore: cast_nullable_to_non_nullable
as String?,protocol: null == protocol ? _self.protocol : protocol // ignore: cast_nullable_to_non_nullable
as ProtocolModel,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as ConnectionStatus,
  ));
}

/// Create a copy of ConnectionModel
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ProtocolModelCopyWith<$Res> get protocol {
  
  return $ProtocolModelCopyWith<$Res>(_self.protocol, (value) {
    return _then(_self.copyWith(protocol: value));
  });
}
}

/// @nodoc
mixin _$ConnectionUiState {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConnectionUiState);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConnectionUiState()';
}


}

/// @nodoc
class $ConnectionUiStateCopyWith<$Res>  {
$ConnectionUiStateCopyWith(ConnectionUiState _, $Res Function(ConnectionUiState) __);
}


/// Adds pattern-matching-related methods to [ConnectionUiState].
extension ConnectionUiStatePatterns on ConnectionUiState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( _Initial value)?  initial,TResult Function( _InProgress value)?  inProgress,TResult Function( _Success value)?  success,TResult Function( _Failure value)?  failure,required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Initial() when initial != null:
return initial(_that);case _InProgress() when inProgress != null:
return inProgress(_that);case _Success() when success != null:
return success(_that);case _Failure() when failure != null:
return failure(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( _Initial value)  initial,required TResult Function( _InProgress value)  inProgress,required TResult Function( _Success value)  success,required TResult Function( _Failure value)  failure,}){
final _that = this;
switch (_that) {
case _Initial():
return initial(_that);case _InProgress():
return inProgress(_that);case _Success():
return success(_that);case _Failure():
return failure(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( _Initial value)?  initial,TResult? Function( _InProgress value)?  inProgress,TResult? Function( _Success value)?  success,TResult? Function( _Failure value)?  failure,}){
final _that = this;
switch (_that) {
case _Initial() when initial != null:
return initial(_that);case _InProgress() when inProgress != null:
return inProgress(_that);case _Success() when success != null:
return success(_that);case _Failure() when failure != null:
return failure(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  initial,TResult Function()?  inProgress,TResult Function( ConnectionModel connection)?  success,TResult Function( FailedReason reason,  String? message,  Object? error)?  failure,required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Initial() when initial != null:
return initial();case _InProgress() when inProgress != null:
return inProgress();case _Success() when success != null:
return success(_that.connection);case _Failure() when failure != null:
return failure(_that.reason,_that.message,_that.error);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  initial,required TResult Function()  inProgress,required TResult Function( ConnectionModel connection)  success,required TResult Function( FailedReason reason,  String? message,  Object? error)  failure,}) {final _that = this;
switch (_that) {
case _Initial():
return initial();case _InProgress():
return inProgress();case _Success():
return success(_that.connection);case _Failure():
return failure(_that.reason,_that.message,_that.error);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  initial,TResult? Function()?  inProgress,TResult? Function( ConnectionModel connection)?  success,TResult? Function( FailedReason reason,  String? message,  Object? error)?  failure,}) {final _that = this;
switch (_that) {
case _Initial() when initial != null:
return initial();case _InProgress() when inProgress != null:
return inProgress();case _Success() when success != null:
return success(_that.connection);case _Failure() when failure != null:
return failure(_that.reason,_that.message,_that.error);case _:
  return null;

}
}

}

/// @nodoc


class _Initial implements ConnectionUiState {
  const _Initial();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Initial);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConnectionUiState.initial()';
}


}




/// @nodoc


class _InProgress implements ConnectionUiState {
  const _InProgress();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _InProgress);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConnectionUiState.inProgress()';
}


}




/// @nodoc


class _Success implements ConnectionUiState {
  const _Success({required this.connection});
  

 final  ConnectionModel connection;

/// Create a copy of ConnectionUiState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SuccessCopyWith<_Success> get copyWith => __$SuccessCopyWithImpl<_Success>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Success&&(identical(other.connection, connection) || other.connection == connection));
}


@override
int get hashCode => Object.hash(runtimeType,connection);

@override
String toString() {
  return 'ConnectionUiState.success(connection: $connection)';
}


}

/// @nodoc
abstract mixin class _$SuccessCopyWith<$Res> implements $ConnectionUiStateCopyWith<$Res> {
  factory _$SuccessCopyWith(_Success value, $Res Function(_Success) _then) = __$SuccessCopyWithImpl;
@useResult
$Res call({
 ConnectionModel connection
});


$ConnectionModelCopyWith<$Res> get connection;

}
/// @nodoc
class __$SuccessCopyWithImpl<$Res>
    implements _$SuccessCopyWith<$Res> {
  __$SuccessCopyWithImpl(this._self, this._then);

  final _Success _self;
  final $Res Function(_Success) _then;

/// Create a copy of ConnectionUiState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? connection = null,}) {
  return _then(_Success(
connection: null == connection ? _self.connection : connection // ignore: cast_nullable_to_non_nullable
as ConnectionModel,
  ));
}

/// Create a copy of ConnectionUiState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$ConnectionModelCopyWith<$Res> get connection {
  
  return $ConnectionModelCopyWith<$Res>(_self.connection, (value) {
    return _then(_self.copyWith(connection: value));
  });
}
}

/// @nodoc


class _Failure implements ConnectionUiState {
  const _Failure({required this.reason, this.message, this.error});
  

 final  FailedReason reason;
 final  String? message;
 final  Object? error;

/// Create a copy of ConnectionUiState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$FailureCopyWith<_Failure> get copyWith => __$FailureCopyWithImpl<_Failure>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Failure&&(identical(other.reason, reason) || other.reason == reason)&&(identical(other.message, message) || other.message == message)&&const DeepCollectionEquality().equals(other.error, error));
}


@override
int get hashCode => Object.hash(runtimeType,reason,message,const DeepCollectionEquality().hash(error));

@override
String toString() {
  return 'ConnectionUiState.failure(reason: $reason, message: $message, error: $error)';
}


}

/// @nodoc
abstract mixin class _$FailureCopyWith<$Res> implements $ConnectionUiStateCopyWith<$Res> {
  factory _$FailureCopyWith(_Failure value, $Res Function(_Failure) _then) = __$FailureCopyWithImpl;
@useResult
$Res call({
 FailedReason reason, String? message, Object? error
});




}
/// @nodoc
class __$FailureCopyWithImpl<$Res>
    implements _$FailureCopyWith<$Res> {
  __$FailureCopyWithImpl(this._self, this._then);

  final _Failure _self;
  final $Res Function(_Failure) _then;

/// Create a copy of ConnectionUiState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? reason = null,Object? message = freezed,Object? error = freezed,}) {
  return _then(_Failure(
reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as FailedReason,message: freezed == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String?,error: freezed == error ? _self.error : error ,
  ));
}


}

// dart format on
