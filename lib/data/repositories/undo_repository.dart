import 'package:dio/dio.dart';

class UndoRepository {
  UndoRepository({required this.dio});

  final Dio dio;

  Future<Map<String, dynamic>> undo() async {
    final response = await dio.post<Map<String, dynamic>>('/undo/undo');
    return response.data ?? {};
  }

  Future<Map<String, dynamic>> redo() async {
    final response = await dio.post<Map<String, dynamic>>('/undo/redo');
    return response.data ?? {};
  }

  Future<Map<String, dynamic>> fetchStack() async {
    final response = await dio.get<Map<String, dynamic>>('/undo/stack');
    return response.data ?? {};
  }

  Future<void> clearHistory() async {
    await dio.delete<Map<String, dynamic>>('/undo/history');
  }
}
