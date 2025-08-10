import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part '../generated/sync/http.g.dart';


@riverpod
Dio dio(Ref ref) {
  final dio = Dio();
  // dio.options.baseUrl = 'https://api.stackexchange.com/2.2';
  // dio.options.connectTimeout = const Duration(seconds: 10);
  // dio.options.receiveTimeout = const Duration(seconds: 10);
  // dio.interceptors.add(LogInterceptor(
  //   requestBody: true,
  //   responseBody: true,
  //   requestHeader: true,
  //   responseHeader: true,
  // ));
  return dio;
}

@riverpod
WebDavRepository webDavRepository(Ref ref) {
  return WebDavRepository(ref);
}

abstract class Repository<T> {
  Repository(this.ref);

  final Ref ref;
}

// webdav
class WebDavRepository extends Repository<String> {
  WebDavRepository(super.ref);

  Future<String> fetchData() async {
    // Simulate a network call
    await Future.delayed(const Duration(seconds: 1));
    return 'Fetched data';
  }
}