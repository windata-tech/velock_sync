// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of '../../domain/sync_task.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SyncTask {

 String get id; String get name; String get description; String get source; String get target;@TimestampParser() DateTime get createdAt;@TimestampParser() DateTime get updatedAt; SyncTaskStatus get status;
/// Create a copy of SyncTask
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncTaskCopyWith<SyncTask> get copyWith => _$SyncTaskCopyWithImpl<SyncTask>(this as SyncTask, _$identity);

  /// Serializes this SyncTask to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncTask&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.source, source) || other.source == source)&&(identical(other.target, target) || other.target == target)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.status, status) || other.status == status));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,description,source,target,createdAt,updatedAt,status);

@override
String toString() {
  return 'SyncTask(id: $id, name: $name, description: $description, source: $source, target: $target, createdAt: $createdAt, updatedAt: $updatedAt, status: $status)';
}


}

/// @nodoc
abstract mixin class $SyncTaskCopyWith<$Res>  {
  factory $SyncTaskCopyWith(SyncTask value, $Res Function(SyncTask) _then) = _$SyncTaskCopyWithImpl;
@useResult
$Res call({
 String id, String name, String description, String source, String target,@TimestampParser() DateTime createdAt,@TimestampParser() DateTime updatedAt, SyncTaskStatus status
});




}
/// @nodoc
class _$SyncTaskCopyWithImpl<$Res>
    implements $SyncTaskCopyWith<$Res> {
  _$SyncTaskCopyWithImpl(this._self, this._then);

  final SyncTask _self;
  final $Res Function(SyncTask) _then;

/// Create a copy of SyncTask
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? description = null,Object? source = null,Object? target = null,Object? createdAt = null,Object? updatedAt = null,Object? status = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,target: null == target ? _self.target : target // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as SyncTaskStatus,
  ));
}

}


/// Adds pattern-matching-related methods to [SyncTask].
extension SyncTaskPatterns on SyncTask {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SyncTask value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SyncTask() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SyncTask value)  $default,){
final _that = this;
switch (_that) {
case _SyncTask():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SyncTask value)?  $default,){
final _that = this;
switch (_that) {
case _SyncTask() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  String description,  String source,  String target, @TimestampParser()  DateTime createdAt, @TimestampParser()  DateTime updatedAt,  SyncTaskStatus status)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SyncTask() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.source,_that.target,_that.createdAt,_that.updatedAt,_that.status);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  String description,  String source,  String target, @TimestampParser()  DateTime createdAt, @TimestampParser()  DateTime updatedAt,  SyncTaskStatus status)  $default,) {final _that = this;
switch (_that) {
case _SyncTask():
return $default(_that.id,_that.name,_that.description,_that.source,_that.target,_that.createdAt,_that.updatedAt,_that.status);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  String description,  String source,  String target, @TimestampParser()  DateTime createdAt, @TimestampParser()  DateTime updatedAt,  SyncTaskStatus status)?  $default,) {final _that = this;
switch (_that) {
case _SyncTask() when $default != null:
return $default(_that.id,_that.name,_that.description,_that.source,_that.target,_that.createdAt,_that.updatedAt,_that.status);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SyncTask implements SyncTask {
   _SyncTask({required this.id, required this.name, required this.description, required this.source, required this.target, @TimestampParser() required this.createdAt, @TimestampParser() required this.updatedAt, required this.status});
  factory _SyncTask.fromJson(Map<String, dynamic> json) => _$SyncTaskFromJson(json);

@override final  String id;
@override final  String name;
@override final  String description;
@override final  String source;
@override final  String target;
@override@TimestampParser() final  DateTime createdAt;
@override@TimestampParser() final  DateTime updatedAt;
@override final  SyncTaskStatus status;

/// Create a copy of SyncTask
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SyncTaskCopyWith<_SyncTask> get copyWith => __$SyncTaskCopyWithImpl<_SyncTask>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SyncTaskToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SyncTask&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.description, description) || other.description == description)&&(identical(other.source, source) || other.source == source)&&(identical(other.target, target) || other.target == target)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.status, status) || other.status == status));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,description,source,target,createdAt,updatedAt,status);

@override
String toString() {
  return 'SyncTask(id: $id, name: $name, description: $description, source: $source, target: $target, createdAt: $createdAt, updatedAt: $updatedAt, status: $status)';
}


}

/// @nodoc
abstract mixin class _$SyncTaskCopyWith<$Res> implements $SyncTaskCopyWith<$Res> {
  factory _$SyncTaskCopyWith(_SyncTask value, $Res Function(_SyncTask) _then) = __$SyncTaskCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, String description, String source, String target,@TimestampParser() DateTime createdAt,@TimestampParser() DateTime updatedAt, SyncTaskStatus status
});




}
/// @nodoc
class __$SyncTaskCopyWithImpl<$Res>
    implements _$SyncTaskCopyWith<$Res> {
  __$SyncTaskCopyWithImpl(this._self, this._then);

  final _SyncTask _self;
  final $Res Function(_SyncTask) _then;

/// Create a copy of SyncTask
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? description = null,Object? source = null,Object? target = null,Object? createdAt = null,Object? updatedAt = null,Object? status = null,}) {
  return _then(_SyncTask(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,description: null == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String,source: null == source ? _self.source : source // ignore: cast_nullable_to_non_nullable
as String,target: null == target ? _self.target : target // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as SyncTaskStatus,
  ));
}


}

// dart format on
