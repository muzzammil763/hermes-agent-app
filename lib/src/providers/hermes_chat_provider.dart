import 'dart:async';
import 'dart:convert';
import 'package:hermes_agent_app/src/services/hermes_agent_service.dart';

/// Message in the conversation
class ChatMessage {
  final String role;
  final String content;
  final DateTime timestamp;
  final bool isStreaming;

  ChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.isStreaming = false,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage copyWith({
    String? role,
    String? content,
    DateTime? timestamp,
    bool? isStreaming,
  }) {
    return ChatMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isStreaming': isStreaming,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'] as String,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isStreaming: json['isStreaming'] as bool? ?? false,
    );
  }
}

/// Exception thrown when a Hermes Agent request fails
class HermesAgentException implements Exception {
  final String message;
  final String? diagnosticMessage;

  HermesAgentException({
    required this.message,
    this.diagnosticMessage,
  });

  @override
  String toString() => message;
}

/// Stream update from Hermes Agent
class ChatStreamUpdate {
  final String? delta;
  final bool isComplete;
  final String? finishReason;
  final Map<String, dynamic>? toolCalls;
  final String? reasoningContent;

  ChatStreamUpdate({
    this.delta,
    this.isComplete = false,
    this.finishReason,
    this.toolCalls,
    this.reasoningContent,
  });
}

/// Provider for Hermes Agent chat functionality
class HermesChatProvider {
  HermesAgentService? _service;
  final List<ChatMessage> _messages = [];
  bool _isStreaming = false;
  String? _currentStreamingContent;
  final _streamController = StreamController<ChatStreamUpdate>();
  final _errorController = StreamController<HermesAgentException>();
  final _statusController = StreamController<bool>();

  HermesChatProvider();

  /// Stream of chat updates
  Stream<ChatStreamUpdate> get stream => _streamController.stream;

  /// Stream of errors
  Stream<HermesAgentException> get errors => _errorController.stream;

  /// Stream of loading status
  Stream<bool> get loadingStatus => _statusController.stream;

  /// Current messages in the conversation
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Whether currently streaming
  bool get isStreaming => _isStreaming;

  /// Initialize with Hermes Agent configuration
  void initialize(HermesAgentConfig config) {
    _service?.dispose();
    _service = HermesAgentService(config);
  }

  /// Check if connected to Hermes Agent
  Future<bool> checkConnection() async {
    if (_service == null) {
      return false;
    }
    return await _service!.checkHealth();
  }

  /// Get available models
  Future<List<String>> getModels() async {
    if (_service == null) {
      throw HermesAgentException(
        message: 'Service not initialized',
      );
    }
    return await _service!.getModels();
  }

  /// Send a message and get streaming response
  Future<void> sendMessage({
    required String userMessage,
    String model = 'hermes-agent',
    double temperature = 0.7,
    int maxTokens = 4096,
    Map<String, dynamic>? additionalParams,
  }) async {
    if (_service == null) {
      throw HermesAgentException(
        message: 'Service not initialized. Call initialize() first.',
      );
    }

    if (_isStreaming) {
      throw HermesAgentException(
        message: 'Already streaming a response',
      );
    }

    // Add user message
    final userMsg = ChatMessage(role: 'user', content: userMessage);
    _messages.add(userMsg);

    // Create assistant message for streaming
    _currentStreamingContent = '';
    final assistantMsg = ChatMessage(
      role: 'assistant',
      content: '',
      isStreaming: true,
    );
    _messages.add(assistantMsg);

    _isStreaming = true;
    _statusController.add(true);

    try {
      // Convert messages to Hermes format
      final hermesMessages = _messages
          .where((m) => !m.isStreaming)
          .map((m) => HermesMessage(
                role: m.role,
                content: m.content,
              ))
          .toList();

      // Stream response
      await for (final chunk in _service!.chatCompletionsStream(
            messages: hermesMessages,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            additionalParams: additionalParams,
          )) {
        if (chunk.delta != null) {
          _currentStreamingContent = (_currentStreamingContent ?? '') + chunk.delta!;
          
          // Update the assistant message
          final index = _messages.indexWhere((m) => m.isStreaming);
          if (index != -1) {
            _messages[index] = _messages[index].copyWith(
              content: _currentStreamingContent!,
            );
          }

          // Emit update
          _streamController.add(ChatStreamUpdate(
            delta: chunk.delta,
            isComplete: chunk.done ?? false,
            finishReason: chunk.finishReason,
            toolCalls: chunk.toolCalls,
            reasoningContent: chunk.reasoningContent,
          ));
        }

        if (chunk.done == true) {
          _isStreaming = false;
          _statusController.add(false);
          
          // Finalize the assistant message
          final index = _messages.indexWhere((m) => m.isStreaming);
          if (index != -1) {
            _messages[index] = _messages[index].copyWith(
              content: _currentStreamingContent ?? '',
              isStreaming: false,
            );
          }
          
          _currentStreamingContent = null;
          _streamController.add(ChatStreamUpdate(
            isComplete: true,
            finishReason: chunk.finishReason,
          ));
        }
      }
    } catch (e) {
      _isStreaming = false;
      _statusController.add(false);
      
      // Remove the streaming assistant message on error
      _messages.removeWhere((m) => m.isStreaming);
      _currentStreamingContent = null;
      
      final error = HermesAgentException(
        message: e.toString(),
        diagnosticMessage: e.runtimeType.toString(),
      );
      _errorController.add(error);
      rethrow;
    }
  }

  /// Cancel the current streaming request
  void cancel() {
    if (_isStreaming) {
      _service?.cancel();
      _isStreaming = false;
      _statusController.add(false);
      
      // Remove the streaming assistant message
      _messages.removeWhere((m) => m.isStreaming);
      _currentStreamingContent = null;
      
      _streamController.add(ChatStreamUpdate(isComplete: true, finishReason: 'cancelled'));
    }
  }

  /// Clear all messages
  void clearMessages() {
    cancel();
    _messages.clear();
  }

  /// Remove the last message (useful for undo)
  void removeLastMessage() {
    if (_messages.isNotEmpty) {
      _messages.removeLast();
    }
  }

  /// Export messages to JSON
  String exportMessages() {
    return '[${_messages.map((m) => jsonEncode(m.toJson())).join(',')}]';
  }

  /// Import messages from JSON
  void importMessages(String jsonStr) {
    try {
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      _messages.clear();
      for (final item in jsonList) {
        _messages.add(ChatMessage.fromJson(item as Map<String, dynamic>));
      }
    } catch (e) {
      throw HermesAgentException(
        message: 'Failed to import messages: $e',
      );
    }
  }

  void dispose() {
    cancel();
    _service?.dispose();
    _streamController.close();
    _errorController.close();
    _statusController.close();
  }
}
