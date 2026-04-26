import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Configuration for Hermes Agent connection
class HermesAgentConfig {
  final String host;
  final int port;
  final bool useHttps;
  final String? apiKey;
  final String? sessionId;

  const HermesAgentConfig({
    required this.host,
    this.port = 8643,
    this.useHttps = false,
    this.apiKey,
    this.sessionId,
  });

  /// Create config for Cloudflare tunnel (HTTPS on port 443)
  factory HermesAgentConfig.forCloudflare(String host) {
    return HermesAgentConfig(
      host: host,
      port: 443,
      useHttps: true,
    );
  }

  String get baseUrl {
    final scheme = useHttps ? 'https' : 'http';
    return '$scheme://$host:$port';
  }

  String get apiUrl => '$baseUrl/v1';

  HermesAgentConfig copyWith({
    String? host,
    int? port,
    bool? useHttps,
    String? apiKey,
    String? sessionId,
  }) {
    return HermesAgentConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      useHttps: useHttps ?? this.useHttps,
      apiKey: apiKey ?? this.apiKey,
      sessionId: sessionId ?? this.sessionId,
    );
  }
}

/// Message in the conversation
class HermesMessage {
  final String role;
  final String content;
  final Map<String, dynamic>? additionalData;

  HermesMessage({
    required this.role,
    required this.content,
    this.additionalData,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'role': role,
      'content': content,
    };
    if (additionalData != null) {
      json.addAll(additionalData!);
    }
    return json;
  }

  factory HermesMessage.fromJson(Map<String, dynamic> json) {
    final additionalData = <String, dynamic>{};
    for (final key in json.keys) {
      if (key != 'role' && key != 'content') {
        additionalData[key] = json[key];
      }
    }
    return HermesMessage(
      role: json['role'] as String,
      content: json['content'] as String,
      additionalData: additionalData,
    );
  }
}

/// Streamed chunk from Hermes Agent
class HermesStreamChunk {
  final String? delta;
  final bool? done;
  final String? finishReason;
  final Map<String, dynamic>? toolCalls;
  final String? reasoningContent;

  HermesStreamChunk({
    this.delta,
    this.done,
    this.finishReason,
    this.toolCalls,
    this.reasoningContent,
  });

  factory HermesStreamChunk.fromJson(Map<String, dynamic> json) {
    final choice = json['choices']?.isNotEmpty == true
        ? json['choices'][0]
        : null;
    final delta = choice?['delta'];
    
    return HermesStreamChunk(
      delta: delta?['content'] as String?,
      done: json['done'] as bool?,
      finishReason: choice?['finish_reason'] as String?,
      toolCalls: delta?['tool_calls'] as Map<String, dynamic>?,
      reasoningContent: delta?['reasoning_content'] as String?,
    );
  }

  @override
  String toString() => 'HermesStreamChunk(delta: $delta, done: $done)';
}

/// Error response from Hermes Agent
class HermesError {
  final String message;
  final String? type;
  final int? statusCode;

  HermesError({
    required this.message,
    this.type,
    this.statusCode,
  });

  factory HermesError.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is Map) {
      return HermesError(
        message: error['message']?.toString() ?? 'Unknown error',
        type: error['type']?.toString(),
        statusCode: json['status'] as int?,
      );
    }
    return HermesError(
      message: json.toString(),
      statusCode: json['status'] as int?,
    );
  }

  @override
  String toString() => 'HermesError: $message (type: $type, status: $statusCode)';
}

/// Main service for communicating with Hermes Agent
class HermesAgentService {
  final HermesAgentConfig config;
  final Dio _dio;
  CancelToken? _cancelToken;

  HermesAgentService(this.config) : _dio = Dio(BaseOptions(
        baseUrl: config.apiUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 300),
        headers: {
          'Content-Type': 'application/json',
          if (config.apiKey != null) 'Authorization': 'Bearer ${config.apiKey}',
          if (config.sessionId != null) 'X-Hermes-Session-Id': config.sessionId,
        },
      )) {
    _dio.interceptors.add(LogInterceptor(
      logPrint: (obj) {
        if (kDebugMode) {
          print('[HermesAgent] $obj');
        }
      },
    ));
  }

  /// Send a chat completion request with streaming
  Stream<HermesStreamChunk> chatCompletionsStream({
    required List<HermesMessage> messages,
    String model = 'hermes-agent',
    double temperature = 0.7,
    int maxTokens = 4096,
    bool stream = true,
    Map<String, dynamic>? additionalParams,
  }) async* {
    _cancelToken = CancelToken();

    try {
      final response = await _dio.post(
        '/chat/completions',
        data: {
          'model': model,
          'messages': messages.map((m) => m.toJson()).toList(),
          'temperature': temperature,
          'max_tokens': maxTokens,
          'stream': stream,
          ...?additionalParams,
        },
        cancelToken: _cancelToken,
        options: Options(
          responseType: ResponseType.stream,
        ),
      );

      // Parse SSE stream
      final responseStream = response.data.stream;
      await for (final chunk in responseStream) {
        final lines = utf8.decode(chunk).split('\n');
        for (final line in lines) {
          if (line.startsWith('data: ')) {
            final data = line.substring(6).trim();
            if (data == '[DONE]') {
              yield HermesStreamChunk(done: true);
              return;
            }

            try {
              final json = jsonDecode(data);
              yield HermesStreamChunk.fromJson(json);
            } catch (e) {
              if (kDebugMode) {
                print('[HermesAgent] Failed to parse chunk: $data, error: $e');
              }
            }
          }
        }
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw Exception('Request cancelled');
      }
      throw _parseError(e);
    }
  }

  /// Send a non-streaming chat completion request
  Future<Map<String, dynamic>> chatCompletions({
    required List<HermesMessage> messages,
    String model = 'hermes-agent',
    double temperature = 0.7,
    int maxTokens = 4096,
    Map<String, dynamic>? additionalParams,
  }) async {
    _cancelToken = CancelToken();

    try {
      final response = await _dio.post(
        '/chat/completions',
        data: {
          'model': model,
          'messages': messages.map((m) => m.toJson()).toList(),
          'temperature': temperature,
          'max_tokens': maxTokens,
          'stream': false,
          ...?additionalParams,
        },
        cancelToken: _cancelToken,
      );

      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _parseError(e);
    }
  }

  /// Cancel the current request
  void cancel() {
    _cancelToken?.cancel();
  }

  /// Check if Hermes Agent is reachable
  Future<bool> checkHealth() async {
    try {
      final response = await _dio.get(
        '/health',
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      return response.statusCode == 200;
    } catch (e) {
      if (kDebugMode) {
        print('[HermesAgent] Health check failed: $e');
      }
      return false;
    }
  }

  /// Get list of available models
  Future<List<String>> getModels() async {
    try {
      final response = await _dio.get('/models');
      final data = response.data as Map<String, dynamic>;
      final models = data['data'] as List?;
      return models
              ?.map((m) => m['id'] as String)
              .toList() ??
          ['hermes-agent'];
    } catch (e) {
      if (kDebugMode) {
        print('[HermesAgent] Failed to get models: $e');
      }
      return ['hermes-agent'];
    }
  }

  Exception _parseError(DioException e) {
    if (e.response != null) {
      try {
        final error = HermesError.fromJson(e.response!.data);
        return Exception(error.toString());
      } catch (_) {
        // Fall through to default error
      }
    }
    return Exception('Request failed: ${e.message}');
  }

  void dispose() {
    _dio.close();
    _cancelToken?.cancel();
  }
}
